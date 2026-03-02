import Foundation
import SwiftUI

struct PRReview: Identifiable, Codable {
    let prKey: String
    let prUrl: String
    let prNumber: Int
    let repo: String
    let org: String
    let title: String
    let author: String
    let createdAt: String
    var reviewStartedAt: String?
    var reviewCompletedAt: String?
    var status: ReviewStatus
    var sessionId: String?
    var pid: Int?
    var trigger: String?
    var priority: String?
    var reviewClone: String?
    var backend: String?
    var sourceChannel: String?
    var sourceMessage: String?
    var mergedAt: String?
    var mergeCheckedAt: String?
    var autoMode: Bool?
    var autoPostedAt: String?
    var autoLastChecked: String?
    var autoResponseCount: Int?

    var id: String { prKey }

    /// The review backend used, defaulting to "claude"
    var effectiveBackend: String {
        backend ?? "claude"
    }

    /// Whether this review's session can be resumed interactively
    var isResumable: Bool {
        effectiveBackend == "claude"
    }

    var isAutoMode: Bool {
        autoMode ?? false
    }

    var isSlackTriggered: Bool {
        trigger == "slack"
    }

    var displayName: String {
        if isSlackTriggered && prNumber == 0 {
            return repo
        }
        return "\(repo)#\(prNumber)"
    }

    var shortTitle: String {
        if title.count > 40 {
            return String(title.prefix(37)) + "..."
        }
        return title
    }

    var relativeAge: String {
        guard let date = parseISO8601(createdAt) else { return "" }
        let interval = Date().timeIntervalSince(date)
        let minutes = Int(interval / 60)
        let hours = minutes / 60
        let days = hours / 24

        if days > 0 { return "\(days)d" }
        if hours > 0 { return "\(hours)h" }
        return "\(minutes)m"
    }

    var isHighPriority: Bool {
        priority == "high"
    }

    /// Weighted multi-field search scoring. Returns 0 for no match.
    func searchScore(for query: String) -> Double {
        let query = query.lowercased().trimmingCharacters(in: .whitespaces)
        if query.isEmpty { return 1 }

        let tokens = query.split(separator: " ").map(String.init)

        let fields: [(String, Double)] = [
            (prUrl, 10),
            (String(prNumber), 10),
            (author, 8),
            (repo, 6),
            (title, 4),
            (status.label, 2),
            (displayName, 6),
        ]

        var totalScore = 0.0
        for token in tokens {
            var bestFieldScore = 0.0
            for (value, weight) in fields {
                let lower = value.lowercased()
                if lower == token {
                    // Exact match — full weight
                    bestFieldScore = max(bestFieldScore, weight)
                } else if lower.hasPrefix(token) {
                    // Prefix match — 80% weight
                    bestFieldScore = max(bestFieldScore, weight * 0.8)
                } else if lower.contains(token) {
                    // Substring match — 50% weight
                    bestFieldScore = max(bestFieldScore, weight * 0.5)
                }
            }
            if bestFieldScore == 0 { return 0 } // All tokens must match
            totalScore += bestFieldScore
        }

        return totalScore
    }

    private func parseISO8601(_ string: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: string) ?? ISO8601DateFormatter().date(from: string)
    }

    enum CodingKeys: String, CodingKey {
        case prKey = "pr_key"
        case prUrl = "pr_url"
        case prNumber = "pr_number"
        case repo, org, title, author
        case createdAt = "created_at"
        case reviewStartedAt = "review_started_at"
        case reviewCompletedAt = "review_completed_at"
        case status
        case sessionId = "session_id"
        case pid, trigger, priority
        case reviewClone = "review_clone"
        case backend
        case sourceChannel = "source_channel"
        case sourceMessage = "source_message"
        case mergedAt = "merged_at"
        case mergeCheckedAt = "merge_checked_at"
        case autoMode = "auto_mode"
        case autoPostedAt = "auto_posted_at"
        case autoLastChecked = "auto_last_checked"
        case autoResponseCount = "auto_response_count"
    }
}

enum ReviewStatus: String, Codable {
    case waitingCoderabbit = "waiting-coderabbit"
    case reviewing
    case ready
    case inProgress = "in-progress"
    case posted
    case dismissed
    case failed
    case merged
    case autoMonitoring = "auto-monitoring"
    case autoResponding = "auto-responding"

    var icon: String {
        switch self {
        case .waitingCoderabbit: return "clock.badge.questionmark"
        case .reviewing: return "circle.fill"
        case .ready: return "circle.fill"
        case .inProgress: return "circle.fill"
        case .posted: return "checkmark.circle.fill"
        case .dismissed: return "minus.circle"
        case .failed: return "exclamationmark.circle.fill"
        case .merged: return "arrow.triangle.merge"
        case .autoMonitoring: return "eyes"
        case .autoResponding: return "bubble.left.and.bubble.right"
        }
    }

    var color: Color {
        switch self {
        case .waitingCoderabbit: return .orange
        case .reviewing: return .gray
        case .ready: return .blue
        case .inProgress: return .yellow
        case .posted: return .green
        case .dismissed: return .secondary
        case .failed: return .red
        case .merged: return .purple
        case .autoMonitoring: return .cyan
        case .autoResponding: return .cyan
        }
    }

    var label: String {
        switch self {
        case .waitingCoderabbit: return "Waiting for CodeRabbit"
        case .reviewing: return "Reviewing..."
        case .ready: return "Ready"
        case .inProgress: return "In Progress"
        case .posted: return "Posted"
        case .dismissed: return "Dismissed"
        case .failed: return "Failed"
        case .merged: return "Merged"
        case .autoMonitoring: return "Auto-Monitoring"
        case .autoResponding: return "Auto-Responding"
        }
    }
}
