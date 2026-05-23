import Foundation

final class DailyBriefService: Service {
    func generate(tasks: [TaskItem], meetings: [MeetingItem], commitments: [CommitmentItem], date: Date = Date()) -> DailyBriefItem {
        let calendar = Calendar.current
        let startOfToday = calendar.startOfDay(for: date)
        let todayTasks = tasks.filter { task in
            task.status == .active &&
            !task.isBacklog &&
            task.dueDate.map { calendar.isDate($0, inSameDayAs: date) || $0 < startOfToday } == true
        }

        let critical = todayTasks.filter { $0.priority == .p0Critical || $0.priority == .p1High }
        let overdue = todayTasks.filter { ($0.dueDate ?? date) < startOfToday }
        let todayMeetings = meetings.filter { calendar.isDate($0.date, inSameDayAs: date) }
        let openCommitments = commitments.filter { $0.statusValue != "fulfilled" }

        let focus = critical.first?.title ?? todayTasks.first?.title ?? "Keep the day light and protect focus."
        let focusBlock = critical.isEmpty ? "No critical focus block needed." : "Protect 45 minutes for \(critical[0].title)."

        return DailyBriefItem(
            date: startOfToday,
            focus: focus,
            criticalTasks: critical.map(\.title),
            meetings: todayMeetings.map(\.title),
            commitments: openCommitments.prefix(5).map(\.title),
            overdueWork: overdue.map(\.title),
            suggestedFocusBlock: focusBlock
        )
    }
}
