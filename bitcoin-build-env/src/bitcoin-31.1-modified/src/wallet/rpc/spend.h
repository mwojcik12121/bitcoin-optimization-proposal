// Copyright (c) 2026-present The Bitcoin Core developers
// Distributed under the MIT software license, see the accompanying
// file COPYING or http://www.opensource.org/licenses/mit-license.php.

#ifndef BITCOIN_WALLET_RPC_SPEND_H
#define BITCOIN_WALLET_RPC_SPEND_H

#include <uint256.h>

#include <functional>
#include <memory>
#include <optional>

class CMutableTransaction;
class UniValue;
struct PartiallySignedTransaction;

namespace wallet {
class CWallet;

struct ActiveChainPrecondition {
    uint256 block_hash;
    int min_confirmations{1};
};

std::optional<ActiveChainPrecondition> ParseActiveChainPrecondition(const UniValue& options);

enum class SendTransactionStage { BEFORE_SIGNING, BEFORE_RELEASE };
// Per-invocation synchronization for deterministic tests. Never exposed by RPC,
// and never installed in production calls; no global hooks or runtime switches.
using SendTransactionHook = std::function<void(SendTransactionStage, const PartiallySignedTransaction&)>;

UniValue FinishTransaction(const std::shared_ptr<CWallet>& wallet, const UniValue& options, CMutableTransaction& tx,
                          const std::optional<ActiveChainPrecondition>& condition = std::nullopt,
                          const SendTransactionHook& hook = {});
} // namespace wallet

#endif // BITCOIN_WALLET_RPC_SPEND_H