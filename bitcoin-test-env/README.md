# Bitcoin test environment

This isolated eight-node environment exercises the peer-scoring optimization built
by `bitcoin-build-env`.

## Required resources

The defaults reflect the machine used to evaluate the optimization proposal.

| CPU | RAM | Free disk |
|:---:|:---:|:---:|
| 8 threads | 24 GB | 750 GB |

## Run a scenario

Copy `bitcoin-binaries.tar.gz` from `bitcoin-build-env/bin/` into `bin/`, then run
one of the two scenarios:

```bash
./run.sh 1
./run.sh 2
```

`./run.sh --list` lists the scenario files and selected nodes. Both scenarios use
all eight nodes and start from a freshly generated 200-block private Signet chain.

## Scenarios

### Scenario 1: recurring odd-node faults

Every node repeatedly creates transactions and mines blocks. Nodes 02, 04, 06,
and 08 remain healthy and continue normal activity. Odd-numbered nodes 01, 03,
05, and 07 concurrently repeat this fault cycle:

1. delayed, jittered, lossy, rate-limited network traffic;
2. a complete but temporary network interruption;
3. a temporary `bitcoind` process freeze followed by recovery;
4. a short healthy interval before the next cycle.

### Scenario 2: recurring faults plus an invalid-block peer

Scenario 2 has exactly the same activity and fault pattern. In addition, node05
announces an invalid block directly over the Bitcoin P2P protocol approximately
once per minute. A persistent node05 sidecar connection starts with the known
height-200 block and changes only its header nonce to produce a distinct invalid
proof of work on every iteration. It sends `inv` and complete `block` messages
to every peer. The unchanged body and merkle root let normal full-block peer
attribution happen before the `high-hash` rejection. This makes the invalid block
attributable to a real node05 peer connection; it is not an unattributed RPC
`submitblock` call.

All internal-subnet connections receive only the `noban` permission so repeated
invalid test traffic remains observable. The invalid blocks are still validated
and rejected normally.

## Timing controls

The runner first waits for all eight nodes to fund their wallets and prepare
transaction targets, then releases activity and faults at one shared epoch. It
allows 180 seconds for preparation. The completion timeout starts at the shared
activity release and is the configured duration plus a 300-second delivery,
convergence, and validation margin:

| Variable | Default | Purpose |
|---|---:|---|
| `SCENARIO_DURATION_SECONDS` | `180` | Synchronized activity and fault-loop duration |
| `SCENARIO_WARMUP_SECONDS` | `20` | Delay between all-node preparation and activity release |
| `INVALID_BLOCK_INTERVAL_SECONDS` | `60` | Scenario 2 invalid announcement interval |
| `INVALID_BLOCK_INITIAL_DELAY_SECONDS` | `15` | Delay from activity start to node05's first announcement |

For example:

```bash
SCENARIO_DURATION_SECONDS=240 INVALID_BLOCK_INTERVAL_SECONDS=55 ./run.sh 2
```

Durations shorter than 60 seconds are rejected. Scenario 2 settings must leave
time for at least two invalid-block announcements so recurrence can be verified.

## Scoring logs

Every scoring record uses the stable marker `peer scoring update:`. In each
record, `scorer=local` means the current machine calculated the score from its
own observations; `scored_peer=<id>` and the adjacent peer address identify the
connection being evaluated. `status=provisional` means the connection has not
yet met the scoring age/observation requirements, while `status=eligible` means
its total and individual parameter scores are ready for optimization decisions.
The records describe local scoring, not scores exchanged between nodes.

The default 180-second scenarios intentionally produce `status=provisional`
records because the optimization's eligibility age is 7,200 seconds. Increase
`SCENARIO_DURATION_SECONDS` beyond that threshold when an eligible-score run is
needed. The environment uses an explicit `connect=` mesh for deterministic fault
coverage, so these short scenarios demonstrate scoring and logging; they do not
exercise eviction from Bitcoin Core's automatically managed extra-outbound slot.

Inspect scoring records from the latest exported logs with:

```bash
grep -hF 'peer scoring update:' logs/node??_scenario*.log
```

Scenario 2's invalid-block sender is a persistent P2P connection from the
node05 container, so receivers attribute it to the same node05 machine and IP.
It is intentionally separate from node05 `bitcoind`'s regular connection; this
keeps its connection-local invalid score meaningful without disrupting the
regular node's accumulated score. A passing run requires repeated invalid blocks
on one stable peer ID at every receiver and rejects sender reconnects, since a
reconnection would reset that connection-local score.

## Notes

- Nodes have no Internet access after setup.
- Each node uses one CPU and approximately 3 GB of memory.
- Runtime chain data lives on bounded temporary filesystems and is deleted during
  cleanup.
- Logs are exported to `logs/nodeXX_scenarioN_YYYYMMDD_HHMMSS.log` before the
  containers are removed.
- Timestamps use the Docker host's local timezone.
