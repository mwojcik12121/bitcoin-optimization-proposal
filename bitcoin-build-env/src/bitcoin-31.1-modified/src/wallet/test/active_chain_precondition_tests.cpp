// Copyright (c) 2026-present The Bitcoin Core developers
// Distributed under the MIT software license, see the accompanying
// file COPYING or http://www.opensource.org/licenses/mit-license.php.

#include <consensus/validation.h>
#include <psbt.h>
#include <rpc/protocol.h>
#include <script/solver.h>
#include <test/util/setup_common.h>
#include <txmempool.h>
#include <univalue.h>
#include <validation.h>
#include <wallet/rpc/spend.h>
#include <wallet/test/util.h>
#include <wallet/wallet.h>

#include <boost/test/unit_test.hpp>

namespace wallet {
BOOST_FIXTURE_TEST_SUITE(active_chain_precondition_tests, TestChain100Setup)

BOOST_AUTO_TEST_CASE(parse_condition)
{
    UniValue options{UniValue::VOBJ};
    BOOST_CHECK(!ParseActiveChainPrecondition(options));
    const std::string hash(64, 'a');
    UniValue condition{UniValue::VOBJ};
    condition.pushKV("blockhash", hash);
    options.pushKV("active_chain_precondition", condition);
    auto parsed{ParseActiveChainPrecondition(options)};
    BOOST_REQUIRE(parsed);
    BOOST_CHECK_EQUAL(parsed->block_hash.GetHex(), hash);
    BOOST_CHECK_EQUAL(parsed->min_confirmations, 1);
    condition.pushKV("min_confirmations", 2147483647);
    options.pushKV("active_chain_precondition", condition);
    BOOST_CHECK_EQUAL(ParseActiveChainPrecondition(options)->min_confirmations, 2147483647);

    for (const auto* json : {"null", "false", "[]", "1", "{}", "{\"blockhash\":false}",
                            "{\"blockhash\":\"00\"}", "{\"blockhash\":\"g000000000000000000000000000000000000000000000000000000000000000\"}"}) {
        UniValue value;
        BOOST_REQUIRE(value.read(json));
        options.pushKV("active_chain_precondition", value);
        BOOST_CHECK_EXCEPTION(ParseActiveChainPrecondition(options), UniValue, [](const UniValue& error) {
            return error["code"].getInt<int>() == RPC_INVALID_PARAMETER;
        });
    }
    for (const auto* json : {"null", "false", "0", "-1", "1.5", "\"6\"", "2147483648", "1e100"}) {
        UniValue value;
        BOOST_REQUIRE(value.read(json));
        condition.pushKV("min_confirmations", value);
        options.pushKV("active_chain_precondition", condition);
        BOOST_CHECK_EXCEPTION(ParseActiveChainPrecondition(options), UniValue, [](const UniValue& error) {
            return error["code"].getInt<int>() == RPC_INVALID_PARAMETER;
        });
    }
    condition.pushKV("min_confirmations", 1);
    condition.pushKV("typo", true);
    options.pushKV("active_chain_precondition", condition);
    BOOST_CHECK_EXCEPTION(ParseActiveChainPrecondition(options), UniValue, [](const UniValue& error) {
        return error["code"].getInt<int>() == RPC_INVALID_PARAMETER;
    });
}

BOOST_AUTO_TEST_CASE(reorganization_at_authorization_boundaries)
{
    // These blocks are only the authorization prerequisite, not funding inputs.
    // Removing the tip therefore leaves the selected mature coinbase spendable.
    mineBlocks(2);
    auto& chainman = *Assert(m_node.chainman);
    std::shared_ptr<CWallet> wallet{CreateSyncedWallet(*m_node.chain,
        WITH_LOCK(cs_main, return chainman.ActiveChain()), coinbaseKey)};
    CBlockIndex* tip{WITH_LOCK(cs_main, return chainman.ActiveChain().Tip())};
    const size_t wallet_size{WITH_LOCK(wallet->cs_wallet, return wallet->mapWallet.size())};
    const auto mempool_size{m_node.mempool->size()};

    for (const auto stage : {SendTransactionStage::BEFORE_SIGNING, SendTransactionStage::BEFORE_RELEASE}) {
        for (const bool depth_loss : {false, true}) {
            for (int mode{0}; mode < 3; ++mode) {
                UniValue options{UniValue::VOBJ};
                options.pushKV("locktime", 0);
                options.pushKV("lock_unspents", true);
                if (mode == 1) options.pushKV("add_to_wallet", false);
                if (mode == 2) options.pushKV("psbt", true);
                CMutableTransaction tx;
                tx.vin.emplace_back(m_coinbase_txns[0]->GetHash(), 0);
                tx.vout.emplace_back(49 * COIN, GetScriptForRawPubKey(coinbaseKey.GetPubKey()));
                const ActiveChainPrecondition condition{depth_loss ? tip->pprev->GetBlockHash() : tip->GetBlockHash(), depth_loss ? 2 : 1};
                bool invalidated{false};
                const SendTransactionHook hook{[&](SendTransactionStage current, const PartiallySignedTransaction& psbt) {
                    const auto txdata{PrecomputePSBTData(psbt)};
                    BOOST_CHECK_EQUAL(PSBTInputSignedAndVerified(psbt, 0, &txdata), current == SendTransactionStage::BEFORE_RELEASE);
                    if (current != stage) return;
                    BlockValidationState state;
                    BOOST_REQUIRE(chainman.ActiveChainstate().InvalidateBlock(state, tip));
                    invalidated = true;
                }};
                BOOST_CHECK_EXCEPTION(FinishTransaction(wallet, options, tx, condition, hook), UniValue, [&](const UniValue& error) {
                    return error["code"].getInt<int>() == RPC_WALLET_ERROR &&
                        error["message"].get_str().find(stage == SendTransactionStage::BEFORE_SIGNING ? "before signing" : "before release") != std::string::npos;
                });
                BOOST_CHECK(invalidated);
                BOOST_CHECK_EQUAL(WITH_LOCK(wallet->cs_wallet, return wallet->mapWallet.size()), wallet_size);
                BOOST_CHECK_EQUAL(m_node.mempool->size(), mempool_size);
                BOOST_CHECK(!WITH_LOCK(wallet->cs_wallet, return wallet->IsLockedCoin(tx.vin[0].prevout)));

                // Restore the exact chain so each branch has an independent race.
                {
                    LOCK(cs_main);
                    chainman.ActiveChainstate().ResetBlockFailureFlags(tip);
                    chainman.RecalculateBestHeader();
                }
                BlockValidationState state;
                BOOST_REQUIRE(chainman.ActiveChainstate().ActivateBestChain(state));
                BOOST_CHECK_EQUAL(WITH_LOCK(cs_main, return chainman.ActiveChain().Tip()), tip);
            }
        }
    }
}

BOOST_AUTO_TEST_CASE(incomplete_signing_never_releases_psbt)
{
    // An internal-key-enabled but blank wallet cannot sign this input. Without
    // ACP the finish path returns its incomplete PSBT; with ACP it must abort.
    auto wallet{std::make_shared<CWallet>(m_node.chain.get(), "", CreateMockableWalletDatabase())};
    CMutableTransaction tx;
    tx.vin.emplace_back(m_coinbase_txns[0]->GetHash(), 0);
    tx.vout.emplace_back(COIN, GetScriptForRawPubKey(coinbaseKey.GetPubKey()));
    UniValue options{UniValue::VOBJ};
    options.pushKV("locktime", 0);
    options.pushKV("psbt", true);
    const ActiveChainPrecondition condition{WITH_LOCK(cs_main, return m_node.chainman->ActiveChain().Tip()->GetBlockHash()), 1};
    BOOST_CHECK(!FinishTransaction(wallet, options, tx)["complete"].get_bool());
    BOOST_CHECK_EXCEPTION(FinishTransaction(wallet, options, tx, condition), UniValue, [](const UniValue& error) {
        return error["code"].getInt<int>() == RPC_WALLET_ERROR &&
            error["message"].get_str() == "Active-chain precondition requires complete internal signing";
    });
}

BOOST_AUTO_TEST_SUITE_END()
} // namespace wallet