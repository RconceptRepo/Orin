import SwiftUI

enum PriorityStyle {
    static func color(for priority: TaskPriority) -> Color {
        switch priority {
        case .p0Critical: OrinColor.p0
        case .p1High: OrinColor.p1
        case .p2Medium: OrinColor.p2
        case .p3Low: OrinColor.p3
        }
    }
}
