# Bitcoin test environment

Test environment for the Active-Chain Precondition (ACP) optimization.

## Required resources

The defaults reflect the machine used to evaluate the optimization proposal.

| CPU | RAM | Free disk |
|:---:|:---:|:---:|
| 8 threads | 24 GB | 750 GB |

## Run a scenario

Copy `bitcoin-binaries.tar.gz` from `bitcoin-build-env/bin/` into `bin/`, then run
one of the three scenarios:

```bash
./run.sh 1
./run.sh 2
./run.sh 3
```

`./run.sh --list` lists the scenario files and selected nodes. All three scenarios
use node01, node02, node03, and node04 and start from a freshly generated 200-block
private Signet chain.

## Notes

- Nodes have no Internet access after setup.
- Each node uses one CPU and approximately 3 GB of memory.
- Runtime chain data lives on bounded temporary filesystems and is deleted during
  cleanup.
- Logs are exported to `logs/nodeXX_scenarioN_YYYYMMDD_HHMMSS.log` before the
  containers are removed.
- Timestamps use the Docker host's local timezone.
