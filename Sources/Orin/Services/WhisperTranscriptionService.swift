import Foundation

/// Extension point for Whisper-based transcription via whisper.cpp server.
///
/// Usage:
///   1. Run `whisper.cpp` with its built-in HTTP server (default: http://localhost:8080).
///   2. Set `serverEndpoint` to the /inference path, e.g. "http://localhost:8080/inference".
///   3. Call `transcribeFile(at:)` with the URL returned by RecordingService.recordingURL.
///
/// When `serverEndpoint` is empty (default), `transcribeFile` returns nil and the caller
/// falls back to the SFSpeechRecognizer transcript already produced by RecordingService.
@Observable
final class WhisperTranscriptionService: Service {

    var serverEndpoint: String {
        get { UserDefaults.standard.string(forKey: "orin.whisper.endpoint") ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: "orin.whisper.endpoint") }
    }

    var isConfigured: Bool { !serverEndpoint.isEmpty }

    /// Sends the recorded audio file to whisper.cpp and returns the transcript, or nil on any error.
    func transcribeFile(at url: URL) async -> String? {
        guard isConfigured, let endpointURL = URL(string: serverEndpoint) else { return nil }
        do {
            let audioData = try Data(contentsOf: url)
            var request = URLRequest(url: endpointURL)
            request.httpMethod = "POST"
            // whisper.cpp /inference accepts raw audio bytes as body (wav or m4a)
            request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
            let (data, response) = try await URLSession.shared.upload(for: request, from: audioData)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
            // whisper.cpp returns {"text": "..."}
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let text = json["text"] as? String {
                return text.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        } catch { /* swallow errors — fall back to SFSpeechRecognizer transcript */ }
        return nil
    }
}
