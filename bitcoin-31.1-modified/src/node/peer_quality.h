// Copyright (c) 2026 The Bitcoin Core developers
// Distributed under the MIT software license, see the accompanying
// file COPYING or http://www.opensource.org/licenses/mit-license.php.

#ifndef BITCOIN_NODE_PEER_QUALITY_H
#define BITCOIN_NODE_PEER_QUALITY_H

#include <algorithm>
#include <cmath>
#include <cstdint>

namespace node {

// Local networking-policy constants. These values are not consensus critical.
static constexpr int64_t QUALITY_HALF_LIFE_SECONDS{24 * 60 * 60};
static constexpr int64_t MIN_SCOREABLE_CONNECTION_SECONDS{2 * 60 * 60};
static constexpr double MIN_EFFECTIVE_OBSERVATIONS{12.0};

/** A constant-size exponentially decaying aggregate of values in [0, 1]. */
class DecayingSignal
{
private:
    double m_sum{0.0};
    double m_weight{0.0};
    int64_t m_last_update{0};

    double DecayFactor(const int64_t now) const
    {
        // Never amplify old evidence if the local clock moves backwards.
        if (m_last_update == 0 || now <= m_last_update) return 1.0;
        return std::exp2(-static_cast<double>(now - m_last_update) /
                         static_cast<double>(QUALITY_HALF_LIFE_SECONDS));
    }

    void DecayTo(const int64_t now)
    {
        const double factor{DecayFactor(now)};
        m_sum *= factor;
        m_weight *= factor;
        m_last_update = now;
    }

public:
    void Observe(double value, const int64_t now)
    {
        value = std::clamp(value, 0.0, 1.0);
        DecayTo(now);
        m_sum += value;
        m_weight += 1.0;
    }

    double Mean(const int64_t now, const double fallback) const
    {
        const double factor{DecayFactor(now)};
        const double decayed_weight{m_weight * factor};
        if (decayed_weight <= 0.0) return fallback;
        return (m_sum * factor) / decayed_weight;
    }

    double EffectiveWeight(const int64_t now) const
    {
        return m_weight * DecayFactor(now);
    }
};

enum class CompactBlockOutcome {
    DIRECT_RECONSTRUCTION,
    AFTER_BLOCKTXN,
    FULL_BLOCK_FALLBACK,
};

/** Values that describe the peer at score-decision time, not historical events. */
struct RelayScoreContext {
    double chain_freshness{0.0};
    double availability{0.0};
    double latency{0.0};
};

/** The total relay-quality score and every normalized input used to derive it. */
struct RelayScoreBreakdown {
    double total{0.0};
    double validated_announcements{0.0};
    double requested_block_success{0.0};
    double compact_block_quality{0.0};
    double chain_freshness{0.0};
    double availability{0.0};
    double latency{0.0};
    double stall_rate{0.0};
    double invalid_block_rate{0.0};
};

/** Local, non-persistent observations of a peer's recent block-relay quality. */
class RelayQuality
{
private:
    DecayingSignal m_valid_announcements;
    DecayingSignal m_requested_block_success;
    DecayingSignal m_compact_quality;
    DecayingSignal m_stall_rate;
    DecayingSignal m_invalid_block_rate;
    DecayingSignal m_evidence;

    void AddEvidence(const int64_t now) { m_evidence.Observe(1.0, now); }

public:
    void ObserveValidatedAnnouncement(const int64_t now)
    {
        m_valid_announcements.Observe(1.0, now);
        AddEvidence(now);
    }

    void ObserveRequestedBlockResult(const bool successful, const int64_t now)
    {
        m_requested_block_success.Observe(successful ? 1.0 : 0.0, now);
        m_stall_rate.Observe(successful ? 0.0 : 1.0, now);
        AddEvidence(now);
    }

    void ObserveCompactBlockResult(const CompactBlockOutcome outcome, const int64_t now)
    {
        double score{0.0};
        switch (outcome) {
        case CompactBlockOutcome::DIRECT_RECONSTRUCTION:
            score = 1.0;
            break;
        case CompactBlockOutcome::AFTER_BLOCKTXN:
            score = 0.5;
            break;
        case CompactBlockOutcome::FULL_BLOCK_FALLBACK:
            score = 0.0;
            break;
        }
        m_compact_quality.Observe(score, now);
        AddEvidence(now);
    }

    void ObserveValidFullBlockSource(const int64_t now)
    {
        m_invalid_block_rate.Observe(0.0, now);
        AddEvidence(now);
    }

    void ObserveInvalidFullBlockSource(const int64_t now)
    {
        m_invalid_block_rate.Observe(1.0, now);
        AddEvidence(now);
    }

    bool HasEnoughEvidence(const int64_t now, const int64_t connected_seconds) const
    {
        return connected_seconds >= MIN_SCOREABLE_CONNECTION_SECONDS &&
               m_evidence.EffectiveWeight(now) >= MIN_EFFECTIVE_OBSERVATIONS;
    }

    double EffectiveObservations(const int64_t now) const
    {
        return m_evidence.EffectiveWeight(now);
    }

    RelayScoreBreakdown ScoreBreakdown(const RelayScoreContext& context, const int64_t now) const
    {
        RelayScoreBreakdown score{
            .validated_announcements =
                std::min(1.0, m_valid_announcements.EffectiveWeight(now) / 8.0),
            .requested_block_success = m_requested_block_success.Mean(now, 0.5),
            .compact_block_quality = m_compact_quality.Mean(now, 0.5),
            .chain_freshness = context.chain_freshness,
            .availability = context.availability,
            .latency = context.latency,
            .stall_rate = m_stall_rate.Mean(now, 0.0),
            .invalid_block_rate = m_invalid_block_rate.Mean(now, 0.0),
        };
        score.total = std::clamp(0.30 * score.validated_announcements +
                                     0.25 * score.requested_block_success +
                                     0.15 * score.compact_block_quality +
                                     0.15 * score.chain_freshness +
                                     0.10 * score.availability +
                                     0.05 * score.latency -
                                     0.50 * score.stall_rate -
                                     1.00 * score.invalid_block_rate,
                                 -1.0, 1.0);
        return score;
    }

    double Score(const RelayScoreContext& context, const int64_t now) const
    {
        return ScoreBreakdown(context, now).total;
    }
};

} // namespace node

#endif // BITCOIN_NODE_PEER_QUALITY_H
