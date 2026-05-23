import AppKit
import SwiftData
import SwiftUI

@MainActor
final class QuickCaptureWindowManager {
    static let shared = QuickCaptureWindowManager()

    private var window: NSPanel?
    private var modelContainer: ModelContainer?

    private init() {}

    func configure(modelContainer: ModelContainer) {
        self.modelContainer = modelContainer
    }

    func toggle() {
        if window?.isVisible == true {
            window?.orderOut(nil)
        } else {
            show()
        }
    }

    private func show() {
        if window == nil {
            let panel = NSPanel(
                contentRect: NSRect(x: 0, y: 0, width: 480, height: 126),
                styleMask: [.nonactivatingPanel, .titled, .fullSizeContentView],
                backing: .buffered,
                defer: false
            )
            panel.center()
            panel.isFloatingPanel = true
            panel.level = .floating
            panel.titleVisibility = .hidden
            panel.titlebarAppearsTransparent = true
            panel.contentView = NSHostingView(rootView: QuickCaptureInputView { [weak self] input in
                self?.save(input)
                self?.window?.orderOut(nil)
            })
            window = panel
        }

        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func save(_ input: String) {
        guard let modelContainer, let parsed = QuickCaptureParser.parse(input) else { return }
        let context = modelContainer.mainContext
        let task = TaskItem(title: parsed.title, priority: parsed.priority, dueDate: parsed.dueDate)
        context.insert(task)
        try? context.save()
    }
}

struct QuickCaptureInputView: View {
    @State private var inputText = ""
    var onSubmit: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("Finish proposal tomorrow P1", text: $inputText)
                .textFieldStyle(.plain)
                .font(.title2)
                .onSubmit {
                    onSubmit(inputText)
                    inputText = ""
                }

            HStack {
                Text("Press Return to save")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
            }
        }
        .padding(18)
        .background(.background)
    }
}
