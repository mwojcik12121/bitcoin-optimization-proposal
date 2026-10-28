Wallet RPCs
-----------

The experimental `send` RPC accepts an optional `active_chain_precondition`
object in `options` (also available as a named argument). It requires a
`blockhash` encoded as 64 hexadecimal characters and an optional integer
`min_confirmations` from 1 to 2147483647, defaulting to 1.

When supplied, the named block must be in the node's local active chain at
the requested depth immediately before signing and again after signing,
before any signed transaction or PSBT is returned or the transaction is
committed to the wallet and submitted through the normal broadcast path.
Unknown, inactive, or insufficiently confirmed blocks fail with a wallet
error. Malformed conditions fail with an invalid-parameter error.

ACP requires internal, complete signing. External-signer wallets,
private-key-disabled wallets, and incomplete signing are rejected. A failed
condition releases no signed result and does not commit the transaction;
requested input locks are deferred until authorization succeeds. The
condition is per call, with no persistent policy or wallet database change.
Omitting it preserves existing behavior. Other sending and funding RPCs do
not support this option.

The final atomic chain observation is the authorization point. No global
chain lock is held across signing or commit. This is not finality: a later
reorganization remains possible, and an isolated node may have a stale
local view. This option is distinct from `minconf`, which constrains wallet
input selection. Applications should reconcile failures rather than retrying
without the precondition.

The `FoundBlock` query gains an optional confirmation-count output, filled
with membership and height under the same chain lock. It does not read block
data and works on pruned nodes. `FoundBlock` is currently an in-process
wallet/node interface, not a serialized Cap'n Proto interface; no IPC schema
or generated bindings change is required.