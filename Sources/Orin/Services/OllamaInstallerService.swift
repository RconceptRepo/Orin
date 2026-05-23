import Foundation
import Observation

enum OllamaStatus: String {
    case unknown = "Unknown"
    case connected = "Connected"
    case missing = "Missing"
    case failed = "Failed"
}

@Observable
final class OllamaInstallerService: Service {
    var status: OllamaStatus = .unknown
    var message = "Ollama status has not been checked."

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
}
