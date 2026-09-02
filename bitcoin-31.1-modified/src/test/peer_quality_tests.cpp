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

BOOST_AUTO_TEST_CASE(score_breakdown_reports_every_parameter)
{
    node::RelayQuality quality;
    const int64_t now{1'000'000};

    for (int i = 0; i < 8; ++i) {
        quality.ObserveValidatedAnnouncement(now);
    }
    quality.ObserveRequestedBlockResult(true, now);
    quality.ObserveRequestedBlockResult(false, now);
    quality.ObserveCompactBlockResult(node::CompactBlockOutcome::AFTER_BLOCKTXN, now);
    quality.ObserveValidFullBlockSource(now);
    quality.ObserveInvalidFullBlockSource(now);

    const node::RelayScoreContext context{
        .chain_freshness = 0.8,
        .availability = 0.6,
        .latency = 0.4,
    };
    const auto score{quality.ScoreBreakdown(context, now)};

    BOOST_CHECK_EQUAL(score.validated_announcements, 1.0);
    BOOST_CHECK_EQUAL(score.requested_block_success, 0.5);
    BOOST_CHECK_EQUAL(score.compact_block_quality, 0.5);
    BOOST_CHECK_EQUAL(score.chain_freshness, 0.8);
    BOOST_CHECK_EQUAL(score.availability, 0.6);
    BOOST_CHECK_EQUAL(score.latency, 0.4);
    BOOST_CHECK_EQUAL(score.stall_rate, 0.5);
    BOOST_CHECK_EQUAL(score.invalid_block_rate, 0.5);
    BOOST_CHECK_SMALL(score.total + 0.05, 1e-12);
    BOOST_CHECK_EQUAL(quality.Score(context, now), score.total);
    BOOST_CHECK_EQUAL(quality.EffectiveObservations(now), 13.0);
}

BOOST_AUTO_TEST_SUITE_END()
