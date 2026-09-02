#!/usr/bin/env python3
"""Announce deliberately invalid blocks to Bitcoin peers over persistent P2P sessions."""

from __future__ import annotations

import argparse
import hashlib
import ipaddress
import socket
import struct
import sys
import time
from dataclasses import dataclass


PROTOCOL_VERSION = 70016
MSG_BLOCK = 2


def sha256d(payload: bytes) -> bytes:
    return hashlib.sha256(hashlib.sha256(payload).digest()).digest()


def compact_size(value: int) -> bytes:
    if value < 0:
        raise ValueError("compact-size value cannot be negative")
    if value < 253:
        return bytes((value,))
    if value <= 0xFFFF:
        return b"\xfd" + struct.pack("<H", value)
    if value <= 0xFFFFFFFF:
        return b"\xfe" + struct.pack("<I", value)
    return b"\xff" + struct.pack("<Q", value)


def read_compact_size(payload: bytes, offset: int) -> tuple[int, int]:
    marker = payload[offset]
    if marker < 253:
        return marker, offset + 1
    sizes = {253: ("<H", 2), 254: ("<I", 4), 255: ("<Q", 8)}
    fmt, size = sizes[marker]
    start = offset + 1
    end = start + size
    if end > len(payload):
        raise ValueError("truncated compact-size value")
    return struct.unpack(fmt, payload[start:end])[0], end


def signet_magic(challenge_hex: str) -> bytes:
    challenge = bytes.fromhex(challenge_hex)
    return sha256d(compact_size(len(challenge)) + challenge)[:4]


def message(magic: bytes, command: str, payload: bytes = b"") -> bytes:
    command_bytes = command.encode("ascii")
    if not command_bytes or len(command_bytes) > 12:
        raise ValueError(f"invalid P2P command: {command!r}")
    return (
        magic
        + command_bytes.ljust(12, b"\x00")
        + struct.pack("<I", len(payload))
        + sha256d(payload)[:4]
        + payload
    )


def network_address(host: str, port: int) -> bytes:
    address = ipaddress.ip_address(socket.gethostbyname(host))
    if address.version != 4:
        raise ValueError(f"peer did not resolve to IPv4: {host}")
    mapped = b"\x00" * 10 + b"\xff\xff" + address.packed
    return struct.pack("<Q", 0) + mapped + struct.pack(">H", port)


def version_payload(peer: str, port: int) -> bytes:
    user_agent = b"/bitcoin-env-invalid-block:1.0/"
    return (
        struct.pack("<iQq", PROTOCOL_VERSION, 0, int(time.time()))
        + network_address(peer, port)
        + struct.pack("<Q", 0)
        + b"\x00" * 10
        + b"\xff\xff"
        + socket.inet_aton("0.0.0.0")
        + struct.pack(">H", 0)
        + struct.pack("<Q", int.from_bytes(hashlib.sha256(peer.encode()).digest()[:8], "little"))
        + compact_size(len(user_agent))
        + user_agent
        + struct.pack("<i?", 0, True)
    )


def recv_exact(connection: socket.socket, size: int) -> bytes:
    chunks: list[bytes] = []
    remaining = size
    while remaining:
        chunk = connection.recv(remaining)
        if not chunk:
            raise ConnectionError("peer closed the connection")
        chunks.append(chunk)
        remaining -= len(chunk)
    return b"".join(chunks)


@dataclass(frozen=True)
class IncomingMessage:
    command: str
    payload: bytes


def receive_message(connection: socket.socket, expected_magic: bytes) -> IncomingMessage:
    header = recv_exact(connection, 24)
    if header[:4] != expected_magic:
        raise ValueError(f"unexpected network magic {header[:4].hex()}")
    command = header[4:16].rstrip(b"\x00").decode("ascii", errors="replace")
    payload_size = struct.unpack("<I", header[16:20])[0]
    if payload_size > 4_000_000:
        raise ValueError(f"unreasonable P2P payload size {payload_size}")
    payload = recv_exact(connection, payload_size)
    if sha256d(payload)[:4] != header[20:24]:
        raise ValueError(f"invalid checksum for {command}")
    return IncomingMessage(command, payload)


def handshake(connection: socket.socket, magic: bytes, peer: str, port: int) -> None:
    connection.sendall(message(magic, "version", version_payload(peer, port)))
    saw_version = False
    saw_verack = False
    deadline = time.monotonic() + 8
    while time.monotonic() < deadline and not (saw_version and saw_verack):
        incoming = receive_message(connection, magic)
        if incoming.command == "version":
            saw_version = True
            connection.sendall(message(magic, "verack"))
        elif incoming.command == "verack":
            saw_verack = True
        elif incoming.command == "ping":
            connection.sendall(message(magic, "pong", incoming.payload))
    if not (saw_version and saw_verack):
        raise TimeoutError("peer did not complete its version/verack handshake")


def inventory_requests_hash(payload: bytes, wanted_hash: bytes) -> bool:
    try:
        count, offset = read_compact_size(payload, 0)
    except (IndexError, ValueError):
        return False
    for _ in range(count):
        if offset + 36 > len(payload):
            return False
        item_type = struct.unpack("<I", payload[offset : offset + 4])[0]
        item_hash = payload[offset + 4 : offset + 36]
        if item_type & 0x3FFFFFFF == MSG_BLOCK and item_hash == wanted_hash:
            return True
        offset += 36
    return False


def announce_over_connection(
    connection: socket.socket, magic: bytes, block: bytes, block_hash: bytes
) -> bool:
    inventory = compact_size(1) + struct.pack("<I", MSG_BLOCK) + block_hash
    requested = False
    connection.sendall(message(magic, "inv", inventory))

    deadline = time.monotonic() + 3
    while time.monotonic() < deadline:
        connection.settimeout(max(0.1, deadline - time.monotonic()))
        try:
            incoming = receive_message(connection, magic)
        except TimeoutError:
            break
        if incoming.command == "getdata" and inventory_requests_hash(incoming.payload, block_hash):
            requested = True
            break
        if incoming.command == "ping":
            connection.sendall(message(magic, "pong", incoming.payload))

    # Send even when a peer did not explicitly request the inventory. The
    # preceding inv remains the announcement and this guarantees delivery to
    # implementations that defer getdata while headers are in flight.
    connection.settimeout(8)
    connection.sendall(message(magic, "block", block))
    time.sleep(0.5)
    return requested


class PeerSession:
    def __init__(self, peer: str, port: int, magic: bytes) -> None:
        self.peer = peer
        self.port = port
        self.magic = magic
        self.connection: socket.socket | None = None
        self.connect_count = 0

    def close(self) -> None:
        if self.connection is not None:
            try:
                self.connection.close()
            finally:
                self.connection = None

    def connect(self) -> None:
        self.close()
        connection = socket.create_connection((self.peer, self.port), timeout=8)
        connection.settimeout(8)
        try:
            handshake(connection, self.magic, self.peer, self.port)
        except Exception:
            connection.close()
            raise
        self.connection = connection
        self.connect_count += 1

    def announce(self, block: bytes, block_hash: bytes) -> bool:
        last_error: Exception | None = None
        for _ in range(2):
            try:
                if self.connection is None:
                    self.connect()
                assert self.connection is not None
                return announce_over_connection(self.connection, self.magic, block, block_hash)
            except (ConnectionError, OSError, TimeoutError, ValueError) as error:
                last_error = error
                self.close()
        assert last_error is not None
        raise last_error


def mutate_candidate(valid_block: bytes, sequence: int) -> bytes:
    if len(valid_block) <= 80:
        raise ValueError("candidate block is too short")
    compact_target = struct.unpack("<I", valid_block[72:76])[0]
    exponent = compact_target >> 24
    mantissa = compact_target & 0x007FFFFF
    if mantissa == 0 or compact_target & 0x00800000:
        raise ValueError(f"invalid compact proof-of-work target {compact_target:08x}")
    target = (
        mantissa >> (8 * (3 - exponent))
        if exponent <= 3
        else mantissa << (8 * (exponent - 3))
    )

    invalid_block = bytearray(valid_block)
    original_nonce = struct.unpack("<I", valid_block[76:80])[0]
    first_increment = sequence * 1_000_000 + 1
    for increment in range(first_increment, first_increment + 1_000_000):
        nonce = (original_nonce + increment) & 0xFFFFFFFF
        invalid_block[76:80] = struct.pack("<I", nonce)
        proof = int.from_bytes(sha256d(invalid_block[:80]), "little")
        if proof > target:
            # Only the nonce changed: transactions and their merkle root remain
            # consistent, but header proof of work deterministically fails.
            return bytes(invalid_block)
    raise ValueError("could not find a high-hash nonce")


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--challenge", required=True, help="custom Signet challenge hex")
    parser.add_argument("--port", type=int, required=True)
    parser.add_argument("--minimum-candidates", type=int, default=2)
    parser.add_argument("peers", nargs="+")
    args = parser.parse_args()
    if args.minimum_candidates < 1:
        parser.error("--minimum-candidates must be positive")
    return args


def main() -> int:
    args = parse_args()
    try:
        magic = signet_magic(args.challenge)
    except ValueError as error:
        print(f"invalid Signet challenge: {error}", file=sys.stderr)
        return 2

    sessions = {peer: PeerSession(peer, args.port, magic) for peer in args.peers}
    total_successful = 0
    candidate_count = 0
    all_candidates_delivered = True
    for serialized_hex in sys.stdin:
        serialized_hex = serialized_hex.strip()
        if not serialized_hex:
            continue
        try:
            valid_block = bytes.fromhex(serialized_hex)
            invalid_block = mutate_candidate(valid_block, candidate_count)
        except ValueError as error:
            print(f"invalid candidate input: {error}", file=sys.stderr, flush=True)
            all_candidates_delivered = False
            continue

        candidate_count += 1
        wire_hash = sha256d(invalid_block[:80])
        display_hash = wire_hash[::-1].hex()
        candidate_successful = 0
        for peer, session in sessions.items():
            try:
                requested = session.announce(invalid_block, wire_hash)
            except (ConnectionError, OSError, TimeoutError, ValueError) as error:
                print(
                    f"peer={peer} block={display_hash} result=failed error={error}",
                    file=sys.stderr,
                    flush=True,
                )
                continue
            candidate_successful += 1
            total_successful += 1
            print(
                f"peer={peer} block={display_hash} result=sent "
                f"requested={str(requested).lower()}",
                flush=True,
            )
        print(
            f"invalid_block={display_hash} peers_sent={candidate_successful} "
            f"peers_total={len(args.peers)} magic={magic.hex()}",
            flush=True,
        )
        if candidate_successful != len(args.peers):
            all_candidates_delivered = False

    for session in sessions.values():
        session.close()
    reconnecting_peers = [
        peer for peer, session in sessions.items() if session.connect_count != 1
    ]
    print(
        f"sender_complete candidates={candidate_count} successful_deliveries={total_successful} "
        f"reconnecting_peers={','.join(reconnecting_peers) or 'none'}",
        flush=True,
    )
    expected_deliveries = candidate_count * len(args.peers)
    return (
        0
        if candidate_count >= args.minimum_candidates
        and all_candidates_delivered
        and total_successful == expected_deliveries
        and not reconnecting_peers
        else 1
    )


if __name__ == "__main__":
    raise SystemExit(main())
