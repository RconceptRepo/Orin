import Foundation
import SwiftData

final class RolloverEngine: Service {
    private let modelContainer: ModelContainer
    private let userDefaultsKey = "com.orin.lastRolloverTimestamp"

    init(container: ModelContainer) {
        modelContainer = container
    }

    @MainActor
    func verifyAndExecuteRollover() {
        let now = Date()
        let calendar = Calendar.current

        guard let lastRollover = UserDefaults.standard.object(forKey: userDefaultsKey) as? Date else {
            UserDefaults.standard.set(now, forKey: userDefaultsKey)
            return
        }

        guard !calendar.isDate(lastRollover, inSameDayAs: now), lastRollover < now else {
            return
        }

        executeRollover(for: now)
    }

    @MainActor
    private func executeRollover(for currentDate: Date) {
        let context = modelContainer.mainContext
        let calendar = Calendar.current
        let startOfToday = calendar.startOfDay(for: currentDate)

        do {
            let activeDescriptor = FetchDescriptor<TaskItem>(
                predicate: #Predicate<TaskItem> { !$0.isBacklog && $0.statusValue == "active" }
            )
            let activeTasks = try context.fetch(activeDescriptor)
            for task in activeTasks where task.dueDate.map({ $0 < startOfToday }) == true {
                task.dueDate = startOfToday
            }

            let backlogDescriptor = FetchDescriptor<TaskItem>(
                predicate: #Predicate<TaskItem> { $0.isBacklog && $0.statusValue == "active" }
            )
            let backlogTasks = try context.fetch(backlogDescriptor)
            for task in backlogTasks where task.triggerDate.map({ $0 <= startOfToday }) == true {
                task.isBacklog = false
                task.dueDate = startOfToday
                task.triggerDate = nil
            }

            try context.save()
            UserDefaults.standard.set(currentDate, forKey: userDefaultsKey)
        } catch {
            print("Rollover failed: \(error.localizedDescription)")
        }
    }
}
