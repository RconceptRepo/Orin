import AppKit
import SwiftUI

struct OllamaSetupView: View {
    var onComplete: (() -> Void)?
    var onBack: (() -> Void)?

    @State private var ollamaService = ServiceContainer.shared.resolve(OllamaInstallerService.self)
    @AppStorage("orin.ai.ollamaEndpoint") private var endpoint = "http://localhost:11434"
    @State private var endpointDraft = ""
    @Environment(\.colorScheme) private var colorScheme

    private let progressLabels = ["Install", "Service", "Models", "Test", "Done"]

    private var progressIndex: Int {
        switch ollamaService.setupPhase {
        case .idle, .detectingInstall, .notInstalled:      return 0
        case .checkingService, .serviceDown:               return 1
        case .noModels:                                    return 2
        case .testingInference, .testFailed:               return 3
        case .complete, .skipped:                          return 4
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding(.top, 28)

            progressBar
                .padding(.top, 18)
                .padding(.horizontal, 40)

            Spacer()

            phaseContent
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 48)
                .transition(.opacity)
                .id(ollamaService.setupPhase)
                .animation(.easeInOut(duration: 0.2), value: ollamaService.setupPhase)

            Spacer()

            bottomNavigation
                .padding(.horizontal, 40)
                .padding(.bottom, 28)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(OrinColor.backgroundPrimary(colorScheme))
        .onAppear {
            endpointDraft = endpoint
            if ollamaService.setupPhase == .idle {
                Task { await ollamaService.runSetup(endpoint: endpoint) }
            }
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(spacing: 8) {
            Image(systemName: "cpu")
                .font(.system(size: 48))
                .foregroundStyle(OrinColor.accent)
            Text("Ollama Setup")
                .font(.system(size: 24, weight: .bold))
            Text("On-device AI for meeting summaries and task suggestions.")
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(.horizontal, 48)
    }

    // MARK: - Progress bar

    private var progressBar: some View {
        HStack(spacing: 0) {
            ForEach(progressLabels.indices, id: \.self) { i in
                VStack(spacing: 4) {
                    Circle()
                        .fill(i <= progressIndex ? OrinColor.accent : Color.secondary.opacity(0.25))
                        .frame(width: 10, height: 10)
                    Text(progressLabels[i])
                        .font(.system(size: 10))
                        .foregroundStyle(i <= progressIndex ? OrinColor.accent : .secondary)
                }
                if i < progressLabels.count - 1 {
                    Rectangle()
                        .fill(i < progressIndex ? OrinColor.accent : Color.secondary.opacity(0.25))
                        .frame(height: 2)
                        .padding(.bottom, 14)
                }
            }
        }
        .animation(.easeInOut(duration: 0.3), value: progressIndex)
    }

    // MARK: - Phase content

    @ViewBuilder
    private var phaseContent: some View {
        switch ollamaService.setupPhase {
        case .idle, .detectingInstall:
            ProgressView("Checking for Ollama…")

        case .notInstalled:
            notInstalledView

        case .checkingService:
            ProgressView("Connecting to Ollama…")

        case .serviceDown:
            serviceDownView

        case .noModels:
            noModelsView

        case .testingInference:
            ProgressView("Running inference test with \(ollamaService.preferredModel)…")

        case .testFailed:
            testFailedView

        case .complete:
            completeView

        case .skipped:
            skippedView
        }
    }

    // MARK: - Phase views

    private var notInstalledView: some View {
        VStack(spacing: 16) {
            Label("Ollama is not installed", systemImage: "xmark.circle.fill")
                .foregroundStyle(OrinColor.error)
                .font(.headline)

            Text("Download and install Ollama to enable on-device AI. After installing, open the app, then click Retry.")
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            HStack(spacing: 12) {
                Button("Download Ollama") {
                    ollamaService.openOllamaWebsite()
                }
                .buttonStyle(OrinPrimaryButtonStyle())

                Button("Open Ollama") {
                    ollamaService.openOllamaApp()
                }
                .buttonStyle(OrinSecondaryButtonStyle())
            }
        }
    }

    private var serviceDownView: some View {
        VStack(spacing: 16) {
            Label("Ollama is not running", systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(OrinColor.warning)
                .font(.headline)

            if !ollamaService.setupErrorMessage.isEmpty {
                Text(ollamaService.setupErrorMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Endpoint")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                TextField("http://localhost:11434", text: $endpointDraft)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 300)
            }

            HStack(spacing: 12) {
                Button("Open Ollama") {
                    ollamaService.openOllamaApp()
                }
                .buttonStyle(OrinSecondaryButtonStyle())
            }

            Text("Start Ollama by opening the app, then click Retry below.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
    }

    private var noModelsView: some View {
        VStack(spacing: 16) {
            Label("No models installed", systemImage: "exclamationmark.circle.fill")
                .foregroundStyle(OrinColor.warning)
                .font(.headline)

            Text("Ollama is running but has no models. Pull one of the recommended models, then click Retry.")
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            VStack(alignment: .leading, spacing: 8) {
                Text("Run one of these in Terminal:")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                CopyableCodeView(command: "ollama pull llama3")
                CopyableCodeView(command: "ollama pull llama3:8b")
                CopyableCodeView(command: "ollama pull mistral")
            }
            .frame(maxWidth: 360)
        }
    }

    private var testFailedView: some View {
        VStack(spacing: 16) {
            Label("Inference test failed", systemImage: "xmark.circle.fill")
                .foregroundStyle(OrinColor.error)
                .font(.headline)

            if !ollamaService.setupErrorMessage.isEmpty {
                Text(ollamaService.setupErrorMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            Text("The model may still be loading. Wait a moment, then click Retry.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
    }

    private var completeView: some View {
        VStack(spacing: 16) {
            Label("Ollama is ready", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .font(.headline)

            if !ollamaService.availableModels.isEmpty {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Available models:")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                    ForEach(ollamaService.availableModels.prefix(5), id: \.self) { model in
                        Label(model, systemImage: model == ollamaService.preferredModel ? "star.fill" : "checkmark.circle")
                            .font(.caption)
                            .foregroundStyle(model == ollamaService.preferredModel ? OrinColor.accent : .secondary)
                    }
                }
            }

            if !ollamaService.testResponse.isEmpty {
                Text("\"\(ollamaService.testResponse)\"")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .italic()
                    .multilineTextAlignment(.center)
                    .padding(.top, 4)
            }
        }
    }

    private var skippedView: some View {
        VStack(spacing: 12) {
            Label("Setup skipped", systemImage: "minus.circle")
                .foregroundStyle(.secondary)
                .font(.headline)
            Text("You can run Ollama setup anytime from Settings → Troubleshooting.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
    }

    // MARK: - Bottom navigation

    @ViewBuilder
    private var bottomNavigation: some View {
        HStack {
            if let onBack {
                Button("Back") { onBack() }
                    .buttonStyle(OrinSecondaryButtonStyle())
            }

            Spacer()

            switch ollamaService.setupPhase {
            case .idle, .detectingInstall, .checkingService, .testingInference:
                Button("Skip") { ollamaService.skipSetup() }
                    .buttonStyle(OrinSecondaryButtonStyle())

            case .notInstalled:
                HStack(spacing: 8) {
                    Button("Skip") { ollamaService.skipSetup() }
                        .buttonStyle(OrinSecondaryButtonStyle())
                    Button("Retry") {
                        Task { await ollamaService.runSetup(endpoint: endpoint) }
                    }
                    .buttonStyle(OrinPrimaryButtonStyle())
                }

            case .serviceDown:
                HStack(spacing: 8) {
                    Button("Skip") { ollamaService.skipSetup() }
                        .buttonStyle(OrinSecondaryButtonStyle())
                    Button("Retry") {
                        endpoint = endpointDraft
                        Task { await ollamaService.retryFromServiceDown(endpoint: endpointDraft) }
                    }
                    .buttonStyle(OrinPrimaryButtonStyle())
                }

            case .noModels:
                HStack(spacing: 8) {
                    Button("Skip") { ollamaService.skipSetup() }
                        .buttonStyle(OrinSecondaryButtonStyle())
                    Button("Retry") {
                        Task { await ollamaService.retryFromServiceDown(endpoint: endpoint) }
                    }
                    .buttonStyle(OrinPrimaryButtonStyle())
                }

            case .testFailed:
                HStack(spacing: 8) {
                    Button("Skip") { ollamaService.skipSetup() }
                        .buttonStyle(OrinSecondaryButtonStyle())
                    Button("Retry") {
                        Task { await ollamaService.retryInference(endpoint: endpoint) }
                    }
                    .buttonStyle(OrinPrimaryButtonStyle())
                }

            case .complete, .skipped:
                Button("Continue") { onComplete?() }
                    .buttonStyle(OrinPrimaryButtonStyle())
            }
        }
    }
}

// MARK: - CopyableCodeView

private struct CopyableCodeView: View {
    let command: String
    @State private var copied = false

    var body: some View {
        HStack {
            Text(command)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.primary)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Color.secondary.opacity(0.1))
                .clipShape(RoundedRectangle(cornerRadius: 6))

            Spacer()

            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(command, forType: .string)
                copied = true
                Task {
                    try? await Task.sleep(nanoseconds: 1_500_000_000)
                    copied = false
                }
            } label: {
                Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
                    .font(.caption)
            }
            .buttonStyle(.plain)
            .foregroundStyle(copied ? .green : .secondary)
        }
    }
}
