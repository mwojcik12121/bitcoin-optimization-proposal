// Copyright (c) 2026 The Bitcoin Core developers
// Distributed under the MIT software license, see the accompanying
// file COPYING or http://www.opensource.org/licenses/mit-license.php.

#include <node/peer_quality.h>

#include <boost/test/unit_test.hpp>

BOOST_AUTO_TEST_SUITE(peer_quality_tests)

BOOST_AUTO_TEST_CASE(stalls_reduce_score)
{
    node::RelayQuality quality;
    const int64_t now{1'000'000};

    for (int i = 0; i < 12; ++i) {
        quality.ObserveRequestedBlockResult(true, now + i);
    }

    const node::RelayScoreContext context{
        .chain_freshness = 1.0,
        .availability = 1.0,
        .latency = 0.5,
    };
    const double before{quality.Score(context, now + 20)};

    quality.ObserveRequestedBlockResult(false, now + 21);
    quality.ObserveRequestedBlockResult(false, now + 22);

    BOOST_CHECK(quality.Score(context, now + 23) < before);
}

BOOST_AUTO_TEST_CASE(new_peer_is_not_immediately_scoreable)
{
    node::RelayQuality quality;
    BOOST_CHECK(!quality.HasEnoughEvidence(/*now=*/10'000, /*connected_seconds=*/60));
}

BOOST_AUTO_TEST_CASE(connection_age_and_decayed_evidence_are_both_required)
{
    node::RelayQuality quality;
    const int64_t now{1'000'000};
    for (int i = 0; i < 13; ++i) {
        quality.ObserveValidatedAnnouncement(now + i);
    }

    BOOST_CHECK(!quality.HasEnoughEvidence(now + 20, node::MIN_SCOREABLE_CONNECTION_SECONDS - 1));
    BOOST_CHECK(quality.HasEnoughEvidence(now + 20, node::MIN_SCOREABLE_CONNECTION_SECONDS));
    BOOST_CHECK(!quality.HasEnoughEvidence(now + 20 + 7 * node::QUALITY_HALF_LIFE_SECONDS,
                                           node::MIN_SCOREABLE_CONNECTION_SECONDS));
}

BOOST_AUTO_TEST_CASE(invalid_full_blocks_reduce_score)
{
    node::RelayQuality quality;
    const int64_t now{1'000'000};
    for (int i = 0; i < 12; ++i) {
        quality.ObserveValidFullBlockSource(now + i);
    }
    const node::RelayScoreContext context{
        .chain_freshness = 1.0,
        .availability = 1.0,
        .latency = 0.5,
    };
    const double before{quality.Score(context, now + 20)};
    quality.ObserveInvalidFullBlockSource(now + 21);
    BOOST_CHECK(quality.Score(context, now + 22) < before);
}

BOOST_AUTO_TEST_SUITE_END()
