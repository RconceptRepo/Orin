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
    @Environment(\.colorScheme) private var colorScheme

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
                    Task { await syncNow() }
                } label: {
                    Label(isSyncing ? "Syncing…" : "Sync", systemImage: "arrow.clockwise")
                }
                .disabled(isSyncing || calendarService.status == .red)
            }

            // Permission gate
            if calendarService.status == .red {
                calendarPermissionBanner
            } else {
                // Date picker + content
                DatePicker("Selected Date", selection: $selectedDate, displayedComponents: .date)
                    .datePickerStyle(.compact)
                    .labelsHidden()

                if let lastSync = calendarService.lastSyncTimestamp {
                    Text("Last synced \(lastSync.formatted(date: .abbreviated, time: .shortened))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if isSyncing {
                    VStack(spacing: 8) {
                        ForEach(0..<4, id: \.self) { i in
                            OrinSkeletonRow(height: 44)
                                .opacity(1 - Double(i) * 0.15)
                        }
                    }
                    .padding(.vertical, 8)

                    OrinProgressStep(message: "Syncing calendar events…")
                        .frame(maxWidth: .infinity)
                        .padding(.top, 4)
                } else {
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
            }
        }
        .padding()
        .task {
            await initialSetup()
        }
    }

    // MARK: - Permission banner (shown when access is denied)

    private var calendarPermissionBanner: some View {
        VStack(spacing: 20) {
            Spacer()
            Image(systemName: "calendar.badge.exclamationmark")
                .font(.system(size: 52))
                .foregroundStyle(OrinColor.error)

            Text("Calendar Access Required")
                .font(.title2.weight(.semibold))

            Text("Grant access so Orin can show your EventKit meetings alongside tasks.")
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 380)

            let authStatus = EKEventStore.authorizationStatus(for: .event)
            if authStatus == .notDetermined {
                Button {
                    Task { await requestAndSync() }
                } label: {
                    Label("Grant Calendar Access", systemImage: "calendar")
                }
                .buttonStyle(OrinPrimaryButtonStyle())
            } else {
                VStack(spacing: 8) {
                    Text("Access was denied. Open System Settings to enable it.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button("Open System Settings") {
                        NSWorkspace.shared.open(
                            URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars")!
                        )
                    }
                    .buttonStyle(OrinPrimaryButtonStyle())
                    Button("Check Again") {
                        Task { await recheckAndSync() }
                    }
                    .buttonStyle(OrinSecondaryButtonStyle())
                }
            }
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Actions

    private func initialSetup() async {
        calendarService.refreshAuthorizationStatus()
        switch EKEventStore.authorizationStatus(for: .event) {
        case .notDetermined:
            await requestAndSync()
        case .fullAccess, .authorized:
            if calendarService.lastSyncTimestamp == nil {
                await syncNow()
            }
        default:
            break
        }
    }

    private func requestAndSync() async {
        isSyncing = true
        await calendarService.requestPermission()
        calendarService.refreshAuthorizationStatus()
        if calendarService.status != .red {
            await calendarService.syncEvents()
        }
        isSyncing = false
    }

    private func recheckAndSync() async {
        calendarService.refreshAuthorizationStatus()
        if calendarService.status != .red {
            await syncNow()
        }
    }

    private func syncNow() async {
        isSyncing = true
        calendarService.refreshAuthorizationStatus()
        await calendarService.syncEvents()
        isSyncing = false
    }
}

// MARK: - Sub-views

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
        case .green:  .green
        case .yellow: .yellow
        case .red:    .red
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
                Text(event.title ?? "Untitled Event").font(.body)
                Text(timeRange).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.vertical, 4)
    }
    private var timeRange: String {
        "\(event.startDate.formatted(date: .omitted, time: .shortened)) – \(event.endDate.formatted(date: .omitted, time: .shortened))"
    }
}
