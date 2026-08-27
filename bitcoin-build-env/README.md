# Bitcoin binary build environment

This environment compiles Bitcoin executables and exports them as a portable archive for the test environment.

## Recommended resources

| CPU | RAM | Swap | Free disk | Build jobs |
|:---:|:---:|:---:|:---:|:---:|
| 4 cores | 8 GB | optional | 15–20 GB | 2 |

Practical verification:
Build was done on a machine with 32 GB RAM, 12 CPU cores and around 500 GB of free disk space - it was done with 4 parallel jobs and took around 3 minutes.

## Build

1. Place the Bitcoin repository under `sources/`:

2. Run:

```bash
./run.sh --source-repository bitcoin --build-jobs 1
```

3. After a successful build, the `bin/` directory shall contain:

```text
bitcoin-binaries.tar.gz
bitcoin-binaries.tar.gz.sha256
```
