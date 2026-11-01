# Bitcoin security measure optimization proposal

## Contents
1. Implementation of optimization suggestion (found [here](https://github.com/mwojcik12121/bitcoin-optimization-proposal/tree/main/bitcoin-build-env/src/bitcoin-31.1-modified))
2. Building environment used to create modified Bitcoin binaries
3. Testing environment used to check optimization's logic and performance
4. Results generated from running tests on both original and modified version of binaries

## Optimization description

Active-Chain Precondition (ACP), that checks whether transaction that is supposed to be sent for payment still matches the active chain state and has required amount of confirmations.

## Components' version

`Bitcoin Core 31.1`

## Note

* Instructions and specification for each environment are added directly to the environment's directory