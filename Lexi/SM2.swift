import Foundation

// ---------------------------------------------------------------------------
// SM-2 spaced repetition — exact port of the Rust/TS pipeline
// (native_toolbar.rs apply_review_grade, lib/sm2.ts parity). Pure functions;
// persistence lives in LexiStore.
// ---------------------------------------------------------------------------

enum SM2 {
    /// again=2, hard=3, good=4, easy=5 — the quality mapping the card's
    /// four grade buttons have always used.
    static func quality(for rating: String) -> Double {
        switch rating {
        case "again": return 2.0
        case "hard": return 3.0
        case "easy": return 5.0
        default: return 4.0
        }
    }

    struct Schedule {
        var easeFactor: Double
        var interval: Int
        var reviewCount: Int
        var status: String
        var nextReview: String // ISO date (yyyy-MM-dd)
    }

    /// One review step. `date` anchors "today" (testable).
    static func schedule(
        rating: String,
        ease: Double,
        interval: Int,
        count: Int,
        from date: Date = Date()
    ) -> Schedule {
        let quality = SM2.quality(for: rating)
        let gap = 5.0 - quality
        let delta = 0.1 - gap * (0.08 + gap * 0.02)
        let clampedEase = max(ease + delta, 1.3)
        let nextEase = (clampedEase * 100.0).rounded() / 100.0
        let nextInterval: Int
        if quality < 3.0 || rating == "again" {
            nextInterval = 1
        } else if rating == "hard" {
            nextInterval = Int(max((Double(interval) * 1.2).rounded(.up), 1.0))
        } else if count == 0 {
            nextInterval = rating == "easy" ? 4 : 1
        } else if count == 1 {
            nextInterval = rating == "easy" ? 8 : 6
        } else {
            nextInterval = Int((Double(interval) * nextEase).rounded(.up))
        }
        let nextCount = count + 1
        let status = (rating == "again" || !(nextCount >= 4 && nextInterval >= 21)) ? "learning" : "mastered"

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .current
        let next = calendar.date(byAdding: .day, value: nextInterval, to: date) ?? date
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone = calendar.timeZone
        return Schedule(
            easeFactor: nextEase,
            interval: nextInterval,
            reviewCount: nextCount,
            status: status,
            nextReview: formatter.string(from: next)
        )
    }
}
