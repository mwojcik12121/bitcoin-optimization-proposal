#!/usr/bin/env python3
# Copyright (c) 2026-present The Bitcoin Core developers
# Distributed under the MIT software license, see the accompanying
# file COPYING or http://www.opensource.org/licenses/mit-license.php.
"""Test the send-only, per-call active-chain authorization condition."""

from test_framework.test_framework import BitcoinTestFramework
from test_framework.util import assert_equal, assert_raises_rpc_error


class ActiveChainPreconditionTest(BitcoinTestFramework):
    def set_test_params(self):
        self.num_nodes = 1

    def skip_test_if_missing_module(self):
        self.skip_if_no_wallet()

    def run_test(self):
        node = self.nodes[0]
        wallet = node.get_wallet_rpc(self.default_wallet_name)
        outputs = {wallet.getnewaddress(): 1}
        self.generate(node, 1)
        block = node.getbestblockhash()

        def send(condition, **options):
            return wallet.send(outputs, fee_rate=2, options={
                "active_chain_precondition": condition, **options,
            })

        def fail(condition, message, code=-4):
            before = (wallet.getwalletinfo()["txcount"], wallet.getbalance(),
                      wallet.listlockunspent(), node.getrawmempool())
            assert_raises_rpc_error(code, message, send, condition)
            after = (wallet.getwalletinfo()["txcount"], wallet.getbalance(),
                     wallet.listlockunspent(), node.getrawmempool())
            assert_equal(before, after)

        self.log.info("Strict object, hash, key, and integer validation")
        for value in [None, False, 1, "condition", []]:
            fail(value, "active_chain_precondition must be an object", -8)
        fail({}, "blockhash is required", -8)
        for value in [None, False, 123, [], "", "00", "g" * 64]:
            fail({"blockhash": value}, "blockhash", -8)
        fail({"blockhash": block, "typo": 1}, "Unexpected key typo", -8)
        for value in [None, False, 0, -1, 1.5, "6", 2147483648, 10**100]:
            fail({"blockhash": block, "min_confirmations": value}, "min_confirmations", -8)

        fail({"blockhash": "00" * 32}, "is unknown")
        fail({"blockhash": block, "min_confirmations": 2}, "has 1 confirmations; at least 2 required")

        self.log.info("Default depth and all signed result modes")
        for options in [{"add_to_wallet": False}, {"psbt": True}]:
            result = send({"blockhash": block}, **options)
            assert result["complete"]
            assert result["hex"]
            assert result["psbt"]
            assert wallet.finalizepsbt(result["psbt"])["complete"]
            assert_raises_rpc_error(-5, "Invalid or non-wallet transaction id", wallet.gettransaction, result["txid"])
            assert result["txid"] not in node.getrawmempool()

        self.generate(node, 1)
        result = send({"blockhash": block, "min_confirmations": 2})
        assert result["complete"]
        assert wallet.gettransaction(result["txid"])
        assert result["txid"] in node.getrawmempool()
        self.generate(node, 1)

        self.log.info("Stale blocks fail, reconsideration permits a stateless retry")
        stale = node.getbestblockhash()
        node.invalidateblock(stale)
        fail({"blockhash": stale}, "is not in the active chain")
        node.reconsiderblock(stale)
        assert send({"blockhash": stale}, add_to_wallet=False)["complete"]

        self.log.info("Private-key-disabled wallets reject ACP before funding")
        node.createwallet("watch_only", disable_private_keys=True)
        watch = node.get_wallet_rpc("watch_only")
        assert_raises_rpc_error(-4, "requires an internally signing wallet", watch.send,
                               outputs, fee_rate=2, options={"active_chain_precondition": {"blockhash": block}})

        self.log.info("Shared funding RPCs must not silently accept the condition")
        raw = node.createrawtransaction([], outputs)
        assert_raises_rpc_error(-3, "Unexpected key active_chain_precondition", wallet.fundrawtransaction,
                               raw, {"active_chain_precondition": {"blockhash": block}})
        assert_raises_rpc_error(-3, "Unexpected key active_chain_precondition", wallet.walletcreatefundedpsbt,
                               [], outputs, 0, {"active_chain_precondition": {"blockhash": block}})

        # Without ACP the original send behavior and result schema are unchanged.
        assert wallet.send(outputs, fee_rate=2, options={"add_to_wallet": False})["complete"]


if __name__ == '__main__':
    ActiveChainPreconditionTest(__file__).main()