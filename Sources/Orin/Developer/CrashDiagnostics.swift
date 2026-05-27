// CrashDiagnostics.swift — Temporary instrumentation for EXC_BAD_ACCESS 0x1e crash.
//
// Crash: swift_getObjectType → swift_task_isMainExecutorImpl → _SwiftData_SwiftUI
//        → EmbeddedDynamicPropertyBox.update → DynamicBody.updateValue
//
// Hypothesis: TodayView's @Query(MeetingItem) receives a SwiftData save-notification
// while its EmbeddedDynamicPropertyBox is being freed (TodayView torn down by
// selectedModule = .meetings in the same task frame). @Query.update() fires on freed
// storage → 0x1e reads from the freed executor reference field.
//
// Usage:
//   Filter in Console.app: subsystem "com.clavrit.orin", category "CrashDiag"
//   Or watch Xcode debug console for "🔍" prefixed lines.
//
// Remove this file and all CrashDiag.trace() call sites before release.

import Foundation
import OSLog
import SwiftUI

// MARK: - Crash diagnostic logger

enum CrashDiag {
    private static let log = Logger(subsystem: "com.clavrit.orin", category: "CrashDiag")

    /// Log a diagnostic trace message to both OSLog and the Xcode debug console.
    ///
    /// - Parameters:
    ///   - message: Descriptive event string.
    ///   - file: Auto-captured source file (fileID format: Module/File.swift).
    ///   - line: Auto-captured source line.
    ///   - function: Auto-captured function name.
    static func trace(
        _ message: String,
        file: String = #fileID,
        line: Int = #line,
        function: String = #function
    ) {
        let ts   = Date().formatted(.dateTime.hour(.twoDigits(amPM: .omitted)).minute().second().secondFraction(.fractional(3)))
        let loc  = "\(file):\(line)"
        let full = "\(ts)  \(loc)  \(message)"
        log.debug("\(full, privacy: .public)")
        print("🔍 DIAG \(full)")
    }

    // MARK: - Object identity helpers

    /// Returns the heap address of a Swift class instance as a 0x-prefixed hex string.
    ///
    /// Use this to track whether two variables reference the SAME object or different
    /// objects representing the same persistent record.
    static func addr(_ object: AnyObject) -> String {
        "0x\(String(UInt(bitPattern: ObjectIdentifier(object)), radix: 16, uppercase: false))"
    }

    /// Returns the heap address of an optional class instance (or "nil").
    static func addr(_ object: AnyObject?) -> String {
        guard let o = object else { return "nil" }
        return addr(o)
    }

    // MARK: - Swift Concurrency task context probe

    /// Returns `true` if the call is executing inside a Swift Concurrency Task,
    /// `false` if it's on a bare GCD callback, run-loop timer, NSOperation, etc.
    ///
    /// Use this to diagnose whether @Observable mutations / @Query updates are
    /// arriving inside a proper task context (required by macOS 26 / Swift 6
    /// executor isolation enforcement in _SwiftData_SwiftUI).
    static var isInSwiftTask: Bool {
        var found = false
        withUnsafeCurrentTask { task in found = (task != nil) }
        return found
    }
}
