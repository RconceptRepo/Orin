import Foundation
import Observation
import OSLog

// MARK: - RecurringPattern
//
// Value type representing a detected recurring meeting group.
// Contains the confidence score and all metadata needed for the suggestion UI.

struct RecurringPattern: Identifiable {
    let id = UUID()
    let suggestedFolderName: String
    let meetingIDs: [UUID]
    let confidence: Double         // 0.0 – 1.0
    let dayPattern: String         // "Every Monday", "Mixed", etc.
    let timePattern: String        // "~9:00 AM", "Mixed", etc.
    let dismissedKey: String

    var confidencePercent: Int { Int((confidence * 100).rounded()) }

    var summaryLine: String {
        "\(meetingIDs.count) meetings · \(confidencePercent)% recurring confidence · \(dayPattern)"
    }

    /// Has the user previously dismissed this exact pattern?
    var isDismissed: Bool {
        UserDefaults.standard.bool(forKey: dismissedKey)
    }

    mutating func dismiss() {
        UserDefaults.standard.set(true, forKey: dismissedKey)
    }
}

// MARK: - RecurringMeetingService
//
// Detects recurring meeting groups from a list of meetings using five weighted signals:
//
//   Signal                    Weight   Description
//   ─────────────────────────────────────────────────────────────────────────
//   Title similarity           35%    Token-Jaccard between meeting titles
//   Participant match          25%    Jaccard similarity of participant sets
//   Day-of-week pattern        20%    Fraction on same weekday
//   Time-of-day pattern        15%    Spread of start times within a day
//   Topic similarity            5%    Keyword overlap in summaries/decisions
//
// Confidence threshold: 60% — any group above this is surfaced as a folder suggestion.
// Groups below threshold or already in a folder are silently dropped.

@Observable
final class RecurringMeetingService: Service {

    private let log = Logger(subsystem: "com.clavrit.orin", category: "RecurringMeetings")

    // Minimum title-token Jaccard to place meetings in the same candidate group.
    private let titleGroupThreshold: Double = 0.55
    // Minimum group size to be considered recurring.
    private let minGroupSize = 2
    // Confidence threshold for surfacing a suggestion.
    let suggestionThreshold: Double = 0.60

    // MARK: - Public API

    /// Returns recurring patterns detected in `meetings`, excluding any that are
    /// already in a folder (`existingFolderNames`) or previously dismissed.
    func detectPatterns(
        in meetings: [MeetingItem],
        existingFolderNames: [String]
    ) -> [RecurringPattern] {
        let groups = groupByTitleSimilarity(meetings)

        return groups.compactMap { group -> RecurringPattern? in
            guard group.count >= minGroupSize else { return nil }

            let folderName   = bestFolderName(for: group)
            let dismissedKey = "orin.recurringPattern.dismissed.\(patternKey(for: group))"

            // Skip already-dismissed or already-foldered
            guard !UserDefaults.standard.bool(forKey: dismissedKey) else { return nil }
            guard !existingFolderNames.contains(where: {
                $0.localizedCaseInsensitiveCompare(folderName) == .orderedSame
            }) else { return nil }

            let (conf, dayPat, timePat) = computeConfidence(for: group)
            guard conf >= suggestionThreshold else { return nil }

            return RecurringPattern(
                suggestedFolderName: folderName,
                meetingIDs:          group.map(\.id),
                confidence:          conf,
                dayPattern:          dayPat,
                timePattern:         timePat,
                dismissedKey:        dismissedKey
            )
        }
        .sorted { $0.confidence > $1.confidence }
    }

    // MARK: - Grouping by Title Similarity

    private func groupByTitleSimilarity(_ meetings: [MeetingItem]) -> [[MeetingItem]] {
        var groups: [[MeetingItem]] = []

        for meeting in meetings {
            let tokens = tokenize(meeting.title)
            guard !tokens.isEmpty else { continue }

            var placed = false
            for i in 0 ..< groups.count {
                let repTokens = tokenize(groups[i][0].title)
                if jaccardSimilarity(tokens, repTokens) >= titleGroupThreshold {
                    groups[i].append(meeting)
                    placed = true
                    break
                }
            }
            if !placed { groups.append([meeting]) }
        }

        return groups.filter { $0.count >= minGroupSize }
    }

    // MARK: - Confidence Computation

    private func computeConfidence(
        for meetings: [MeetingItem]
    ) -> (confidence: Double, dayPattern: String, timePattern: String) {
        let titleSim        = averageTitleSimilarity(meetings)
        let participantSim  = averageParticipantMatch(meetings)
        let (daySc, dayPat) = dayPatternScore(meetings)
        let (timeSc, timePat) = timePatternScore(meetings)
        let topicSim        = topicSimilarity(meetings)

        let confidence = 0.35 * titleSim
                       + 0.25 * participantSim
                       + 0.20 * daySc
                       + 0.15 * timeSc
                       + 0.05 * topicSim

        log.debug("pattern '\(self.bestFolderName(for: meetings))' confidence=\(String(format: "%.2f", confidence)) title=\(String(format: "%.2f", titleSim)) part=\(String(format: "%.2f", participantSim)) day=\(String(format: "%.2f", daySc)) time=\(String(format: "%.2f", timeSc)) topic=\(String(format: "%.2f", topicSim))")

        return (confidence, dayPat, timePat)
    }

    // MARK: - Signal: Title Similarity

    private func averageTitleSimilarity(_ meetings: [MeetingItem]) -> Double {
        guard meetings.count >= 2 else { return 1.0 }
        var sum = 0.0; var count = 0
        let tokens = meetings.map { tokenize($0.title) }
        for i in 0 ..< tokens.count {
            for j in (i + 1) ..< tokens.count {
                sum += jaccardSimilarity(tokens[i], tokens[j])
                count += 1
            }
        }
        return count > 0 ? sum / Double(count) : 1.0
    }

    // MARK: - Signal: Participant Match

    private func averageParticipantMatch(_ meetings: [MeetingItem]) -> Double {
        let participantSets = meetings.map { normalized(participants: $0.participants) }
        // If all meetings have no participants, score neutral 0.5
        guard participantSets.contains(where: { !$0.isEmpty }) else { return 0.5 }

        var sum = 0.0; var count = 0
        for i in 0 ..< participantSets.count {
            for j in (i + 1) ..< participantSets.count {
                sum += jaccardSimilarity(participantSets[i], participantSets[j])
                count += 1
            }
        }
        return count > 0 ? sum / Double(count) : 0.5
    }

    // MARK: - Signal: Day-of-Week Pattern

    private func dayPatternScore(_ meetings: [MeetingItem]) -> (score: Double, pattern: String) {
        let cal      = Calendar.current
        let weekdays = meetings.map { cal.component(.weekday, from: $0.date) }
        let freq     = Dictionary(grouping: weekdays) { $0 }.mapValues(\.count)

        guard let (dominantDay, dominantCount) = freq.max(by: { $0.value < $1.value }) else {
            return (0.3, "Mixed")
        }

        let fraction = Double(dominantCount) / Double(weekdays.count)
        let score: Double
        switch fraction {
        case 0.75...: score = 1.0
        case 0.50...: score = 0.7
        default:      score = 0.3
        }

        // Format day name
        let dayName: String
        if fraction >= 0.50 {
            let sym = cal.weekdaySymbols[(dominantDay - 1) % 7]
            dayName = fraction >= 0.75 ? "Every \(sym)" : "Usually \(sym)"
        } else {
            dayName = "Mixed"
        }
        return (score, dayName)
    }

    // MARK: - Signal: Time-of-Day Pattern

    private func timePatternScore(_ meetings: [MeetingItem]) -> (score: Double, pattern: String) {
        let cal     = Calendar.current
        let minutes = meetings.map { m -> Int in
            let c = cal.dateComponents([.hour, .minute], from: m.date)
            return (c.hour ?? 0) * 60 + (c.minute ?? 0)
        }
        guard minutes.count >= 2 else { return (1.0, formattedTime(minutes[0])) }

        let minVal = minutes.min()!
        let maxVal = minutes.max()!
        let range  = maxVal - minVal

        let score: Double
        switch range {
        case ...30:  score = 1.0
        case ...60:  score = 0.7
        case ...120: score = 0.4
        default:     score = 0.2
        }

        let medianMinutes = minutes.sorted()[minutes.count / 2]
        let timePat = score >= 0.7 ? "~\(formattedTime(medianMinutes))" : "Mixed"
        return (score, timePat)
    }

    private func formattedTime(_ totalMinutes: Int) -> String {
        let h = totalMinutes / 60
        let m = totalMinutes % 60
        let hour12 = h == 0 ? 12 : (h > 12 ? h - 12 : h)
        let ampm   = h < 12 ? "AM" : "PM"
        return m == 0 ? "\(hour12) \(ampm)" : String(format: "%d:%02d %@", hour12, m, ampm)
    }

    // MARK: - Signal: Topic Similarity

    private func topicSimilarity(_ meetings: [MeetingItem]) -> Double {
        let keywordSets = meetings.map { topicKeywords(from: $0) }
        let nonEmpty    = keywordSets.filter { !$0.isEmpty }
        guard nonEmpty.count >= 2 else { return 0.5 }

        var sum = 0.0; var count = 0
        for i in 0 ..< nonEmpty.count {
            for j in (i + 1) ..< nonEmpty.count {
                sum += jaccardSimilarity(nonEmpty[i], nonEmpty[j])
                count += 1
            }
        }
        return count > 0 ? sum / Double(count) : 0.5
    }

    private func topicKeywords(from meeting: MeetingItem) -> Set<String> {
        let text = ([meeting.summary] + meeting.decisions + meeting.actionItems)
            .joined(separator: " ")
        return tokenize(text)
    }

    // MARK: - Folder Name

    func bestFolderName(for meetings: [MeetingItem]) -> String {
        // Use the most common title in the group (normalized)
        let titles = meetings.map { $0.title.trimmingCharacters(in: .whitespacesAndNewlines) }
        let freq   = Dictionary(grouping: titles) { $0 }.mapValues(\.count)
        return freq.max(by: { $0.value < $1.value })?.key ?? meetings[0].title
    }

    // MARK: - Pattern Key (for UserDefaults deduplication)

    func patternKey(for meetings: [MeetingItem]) -> String {
        let name = bestFolderName(for: meetings).lowercased()
        let participants = meetings
            .flatMap(\.participants)
            .map { $0.lowercased() }
            .sorted()
            .prefix(3)
            .joined(separator: "+")
        let raw = "\(name)_\(participants)"
        return raw.filter { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "+" }
    }

    // MARK: - Helpers

    private func tokenize(_ text: String) -> Set<String> {
        text
            .lowercased()
            .components(separatedBy: .init(charactersIn: " -_/\\,.:;!?()[]{}"))
            .map { $0.trimmingCharacters(in: CharacterSet.alphanumerics.inverted) }
            .filter { $0.count >= 2 && !RecurringMeetingService.stopWords.contains($0) }
            .reduce(into: Set<String>()) { $0.insert($1) }
    }

    private func jaccardSimilarity<T: Hashable>(_ a: Set<T>, _ b: Set<T>) -> Double {
        guard !a.isEmpty || !b.isEmpty else { return 1.0 }
        guard !a.isEmpty, !b.isEmpty  else { return 0.0 }
        let intersect = a.intersection(b).count
        let union     = a.union(b).count
        return Double(intersect) / Double(union)
    }

    private func normalized(participants: [String]) -> Set<String> {
        Set(participants.map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
                        .filter { !$0.isEmpty })
    }

    private static let stopWords: Set<String> = [
        "the", "and", "for", "with", "our", "this", "that",
        "have", "from", "they", "will", "one", "all", "not",
        "but", "are", "was", "has", "had", "its", "on", "in",
        "of", "to", "a", "an", "is", "be", "as", "at", "by",
        "we", "my", "up"
    ]
}
