import AVFoundation
import Speech

/// Thread-safe container for the two resources that cross the MainActor /
/// Core-Audio-I/O-thread boundary during a recording session.
///
/// ## Ownership contract
///
/// | Caller              | Thread                 | Method(s)              |
/// |---------------------|------------------------|------------------------|
/// | `startRecording`    | MainActor (before tap) | `arm`                  |
/// | `installTap` block  | Core-Audio I/O thread  | `feed`                 |
/// | 60-s restart        | MainActor              | `updateRequest`        |
/// | `stopRecording`     | MainActor (after tap)  | `disarm`               |
///
/// `arm` must be called **before** `installTap` so the callback always sees
/// valid references from the very first audio buffer.
///
/// `disarm` must be called **after** `removeTap` returns so no `feed` call can
/// be in-flight while the resources are being released.
final class TapState {

    // MARK: - Lock-protected storage

    private let lock = NSLock()
    private var audioFile: AVAudioFile?
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?

    /// URL is stored separately so callers can read it after `disarm` closes the file.
    private var _audioFileURL: URL?

    // MARK: - Public interface

    /// The URL written to during the active recording.
    /// Safe to read from any thread; returns `nil` until `arm` is first called.
    var audioFileURL: URL? { lock.withLock { _audioFileURL } }

    /// Arm both resources. Call on MainActor **before** `installTap`.
    func arm(
        audioFile: AVAudioFile,
        recognitionRequest: SFSpeechAudioBufferRecognitionRequest
    ) {
        lock.withLock {
            self.audioFile        = audioFile
            self._audioFileURL    = audioFile.url
            self.recognitionRequest = recognitionRequest
        }
    }

    /// Swap in a new recognition request (transparent ~60-second restart).
    /// Call on MainActor while the tap is still installed.
    func updateRequest(_ request: SFSpeechAudioBufferRecognitionRequest?) {
        lock.withLock { recognitionRequest = request }
    }

    /// Signal end-of-audio, then release both resources.
    /// `audioFileURL` is intentionally preserved so the recording path can be
    /// read by `stopRecording` after this call returns.
    /// Call on MainActor **after** `removeTap` returns.
    func disarm() {
        lock.withLock {
            recognitionRequest?.endAudio()
            recognitionRequest = nil
            audioFile          = nil
        }
    }

    /// Deliver a captured audio buffer. Called on the Core-Audio I/O thread.
    func feed(buffer: AVAudioPCMBuffer) {
        lock.withLock {
            recognitionRequest?.append(buffer)
            try? audioFile?.write(from: buffer)
        }
    }
}
