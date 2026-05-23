import EventKit
import SwiftData
import SwiftUI

struct CalendarView: View {
    @Query(
        filter: #Predicate<TaskItem> { !$0.isBacklog && $0.statusValue == "active" },
        sort: \TaskItem.dueDate
    )
    private var tasks: [TaskItem]

    @State private var calendarService = ServiceContainer.shared.resolve(CalendarService.self)
    @State private var selectedDate = Date()
    @State private var isSyncing = false

    private var selectedEvents: [EKEvent] {
        calendarService.events.filter { event in
            Calendar.current.isDate(event.startDate, inSameDayAs: selectedDate)
        }
    }

    private var selectedTasks: [TaskItem] {
        tasks.filter { task in
            task.dueDate.map { Calendar.current.isDate($0, inSameDayAs: selectedDate) } == true
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Calendar")
                        .font(.title2.weight(.semibold))
                    Text("Native EventKit events, tasks, and execution context.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                CalendarStatusBadge(status: calendarService.status)

                Button {
                    Task { await requestAndSync() }
                } label: {
                    Label("Sync", systemImage: "arrow.clockwise")
                }
                .disabled(isSyncing)
            }

            DatePicker("Selected Date", selection: $selectedDate, displayedComponents: .date)
                .datePickerStyle(.compact)
                .labelsHidden()

            if let lastSync = calendarService.lastSyncTimestamp {
                Text("Last synced \(lastSync.formatted(date: .abbreviated, time: .shortened))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            List {
                Section("Meetings") {
                    if selectedEvents.isEmpty {
                        Text("No EventKit meetings for this date.")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(selectedEvents, id: \.eventIdentifier) { event in
                            CalendarEventRow(event: event)
                        }
                    }
                }

                Section("Tasks") {
                    if selectedTasks.isEmpty {
                        Text("No tasks scheduled for this date.")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(selectedTasks) { task in
                            TaskRowView(task: task, showsDescription: true)
                        }
                    }
                }
            }
        }
        .padding()
        .task {
            calendarService.refreshAuthorizationStatus()
            if calendarService.lastSyncTimestamp == nil {
                await requestAndSync()
            }
        }
    }

    private func requestAndSync() async {
        isSyncing = true
        calendarService.refreshAuthorizationStatus()
        if calendarService.status == .yellow {
            await calendarService.requestPermission()
        }
        await calendarService.syncEvents()
        isSyncing = false
    }
}

private struct CalendarStatusBadge: View {
    let status: CalendarSyncStatus

    var body: some View {
        Label(status.title, systemImage: "circle.fill")
            .font(.caption.weight(.medium))
            .foregroundStyle(color)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(color.opacity(0.12))
            .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    private var color: Color {
        switch status {
        case .green: .green
        case .yellow: .yellow
        case .red: .red
        }
    }
}

private struct CalendarEventRow: View {
    let event: EKEvent

    var body: some View {
        HStack(spacing: 10) {
            RoundedRectangle(cornerRadius: 3)
                .fill(Color(cgColor: event.calendar.cgColor))
                .frame(width: 4)

            VStack(alignment: .leading, spacing: 3) {
                Text(event.title ?? "Untitled Event")
                    .font(.body)
                Text(timeRange)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()
        }
        .padding(.vertical, 4)
    }

    private var timeRange: String {
        "\(event.startDate.formatted(date: .omitted, time: .shortened)) - \(event.endDate.formatted(date: .omitted, time: .shortened))"
    }
}
