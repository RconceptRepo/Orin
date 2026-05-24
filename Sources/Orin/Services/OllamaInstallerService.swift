import AppKit
import Foundation
import Observation

enum OllamaStatus: String {
    case unknown = "Unknown"
    case connected = "Connected"
    case missing = "Missing"
    case failed = "Failed"
}

enum SetupPhase: Equatable {
    case idle
    case detectingInstall
    case notInstalled
    case checkingService
    case serviceDown
    case noModels
    case testingInference
    case testFailed
    case complete
    case skipped
}

@Observable
final class OllamaInstallerService: Service, @unchecked Sendable {

    // MARK: - Legacy verify state
    var status: OllamaStatus = .unknown
    var message = "Ollama status has not been checked."

    // MARK: - Setup wizard state
    private(set) var setupPhase: SetupPhase = .idle
    private(set) var setupErrorMessage: String = ""
    private(set) var availableModels: [String] = []
    private(set) var preferredModel: String = ""
    private(set) var testResponse: String = ""

    // MARK: - Install detection

    var isInstalled: Bool {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.ollama.Ollama") != nil
            || FileManager.default.fileExists(atPath: "/usr/local/bin/ollama")
            || FileManager.default.fileExists(atPath: "/opt/homebrew/bin/ollama")
            || FileManager.default.fileExists(atPath: "/Applications/Ollama.app")
    }

    // MARK: - Legacy verify (unchanged)

    func verify(endpoint: String = "http://localhost:11434") async {
        guard let url = URL(string: "\(endpoint)/api/tags") else {
            await MainActor.run {
                status = .failed
                message = "Invalid Ollama endpoint."
            }
            return
        }

        do {
            let (_, response) = try await URLSession.shared.data(from: url)
            let ok = (response as? HTTPURLResponse)?.statusCode == 200
            await MainActor.run {
                status = ok ? .connected : .failed
                message = ok ? "Ollama is running locally." : "Ollama responded with an error."
            }
        } catch {
            await MainActor.run {
                status = .missing
                message = "Ollama is not reachable. Install and start Ollama, then verify again."
            }
        }
    }

    // MARK: - Setup wizard entry point

    @MainActor
    func runSetup(endpoint: String) async {
        setupPhase = .detectingInstall
        setupErrorMessage = ""

        guard isInstalled else {
            setupPhase = .notInstalled
            return
        }

        await checkServiceInternal(endpoint: endpoint)
    }

    // MARK: - Public retry helpers

    @MainActor
    func retryFromServiceDown(endpoint: String) async {
        setupErrorMessage = ""
        await checkServiceInternal(endpoint: endpoint)
    }

    @MainActor
    func retryInference(endpoint: String) async {
        setupErrorMessage = ""
        await testInferenceInternal(endpoint: endpoint)
    }

    @MainActor
    func skipSetup() {
        setupPhase = .skipped
    }

    @MainActor
    func resetSetup() {
        setupPhase = .idle
        setupErrorMessage = ""
        availableModels = []
        preferredModel = ""
        testResponse = ""
    }

    // MARK: - App launcher

    @MainActor
    func openOllamaWebsite() {
        NSWorkspace.shared.open(URL(string: "https://ollama.com")!)
    }

    @MainActor
    func openOllamaApp() {
        if let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.ollama.Ollama") {
            NSWorkspace.shared.open(appURL)
        } else {
            let appPath = URL(fileURLWithPath: "/Applications/Ollama.app")
            if FileManager.default.fileExists(atPath: appPath.path) {
                NSWorkspace.shared.open(appPath)
            } else {
                NSWorkspace.shared.open(URL(string: "https://ollama.com")!)
            }
        }
    }

    // MARK: - Private pipeline

    @MainActor
    private func checkServiceInternal(endpoint: String) async {
        setupPhase = .checkingService

        guard let url = URL(string: "\(endpoint)/api/tags") else {
            setupPhase = .serviceDown
            setupErrorMessage = "Invalid endpoint URL."
            return
        }

        var req = URLRequest(url: url)
        req.timeoutInterval = 5

        let tagData: Data
        do {
            let (data, response) = try await URLSession.shared.data(for: req)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                setupPhase = .serviceDown
                setupErrorMessage = "Ollama responded with an error. Is it running at \(endpoint)?"
                return
            }
            tagData = data
        } catch let err as URLError where err.code == .timedOut {
            setupPhase = .serviceDown
            setupErrorMessage = "Connection timed out. Is Ollama running at \(endpoint)?"
            return
        } catch {
            setupPhase = .serviceDown
            setupErrorMessage = "Cannot reach Ollama at \(endpoint). Open the Ollama app and try again."
            return
        }

        let json = (try? JSONSerialization.jsonObject(with: tagData)) as? [String: Any]
        let models = (json?["models"] as? [[String: Any]])?.compactMap { $0["name"] as? String } ?? []
        availableModels = models

        guard !models.isEmpty else {
            setupPhase = .noModels
            return
        }

        preferredModel = models.first(where: { $0.hasPrefix("llama3") })
            ?? models.first(where: { $0.hasPrefix("mistral") })
            ?? models[0]

        await testInferenceInternal(endpoint: endpoint)
    }

    @MainActor
    private func testInferenceInternal(endpoint: String) async {
        setupPhase = .testingInference

        guard let url = URL(string: "\(endpoint)/api/generate") else {
            setupPhase = .testFailed
            setupErrorMessage = "Invalid endpoint URL."
            return
        }

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = 30
        req.httpBody = try? JSONSerialization.data(withJSONObject: [
            "model": preferredModel,
            "prompt": "Reply with exactly: Hello from Ollama.",
            "stream": false
        ])

        do {
            let (data, response) = try await URLSession.shared.data(for: req)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                setupPhase = .testFailed
                setupErrorMessage = "Inference failed. The model may still be loading — try again."
                return
            }
            let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            testResponse = (json?["response"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "Response received."
            setupPhase = .complete
        } catch let err as URLError where err.code == .timedOut {
            setupPhase = .testFailed
            setupErrorMessage = "Inference timed out. Model is likely loading — try again in a moment."
        } catch {
            setupPhase = .testFailed
            setupErrorMessage = "Inference error: \(error.localizedDescription)"
        }
    }
}
