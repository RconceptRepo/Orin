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
///
/// ## Thread-safety model
///
/// Lock-protected properties (`audioFile`, `recognitionRequest`, `_audioFileURL`,
/// `_hasWriteFailure`) are accessed under `lock` (NSLock) from both the Core-Audio
/// I/O thread and MainActor. NSLock is safe here because `endAudio()` — the XPC
/// call that triggers an unbounded kernel round-trip — is always called OUTSIDE the
/// lock (see `updateRequest` and `disarm`).
///
/// RT-thread counters (`_rtBuffersReceived`, `_rtBuffersAppended`) are NOT protected
/// by a lock. They are written ONLY in `feed()` (Core-Audio I/O thread) and read
/// ONLY after `removeTap()` returns (@MainActor). `removeTap()` is a synchronous
/// barrier: when it returns, the RT thread has exited the tap closure for the last
/// time, making all prior RT writes visible to the caller without any further
/// synchronization. Doc 14 §9.1 RULE-RT-02.
final class TapState: @unchecked Sendable {

    // MARK: - Lock-protected storage

    private let lock = NSLock()
    private var audioFile: AVAudioFile?
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?

    /// URL is stored separately so callers can read it after `disarm` closes the file.
    private var _audioFileURL: URL?

    /// Set to `true` inside `feed` if any `AVAudioFile.write(from:)` call throws.
    /// Reset to `false` in `arm` so each new recording session starts clean.
    private var _hasWriteFailure = false

    // MARK: - RT-thread counters (no lock — see ownership contract above)

    /// Total audio buffers received by the tap callback. Written only on the
    /// Core-Audio I/O thread; read only by @MainActor after `removeTap()` returns.
    private var _rtBuffersReceived: Int = 0

    /// Buffers successfully appended to the recognition request. Same threading
    /// contract as `_rtBuffersReceived`.
    private var _rtBuffersAppended: Int = 0

    // MARK: - Public interface

    /// The URL written to during the active recording.
    /// Safe to read from any thread; returns `nil` until `arm` is first called.
    var audioFileURL: URL? { lock.withLock { _audioFileURL } }

    /// `true` if at least one `AVAudioFile.write(from:)` call failed during the session.
    /// Thread-safe; read after `disarm` returns to determine whether the recording
    /// is likely incomplete or corrupt before saving the file path to the model.
    var hadWriteFailure: Bool { lock.withLock { _hasWriteFailure } }

    /// Total audio buffers the tap received this session.
    /// Read ONLY after `removeTap()` has returned (@MainActor). The removeTap()
    /// barrier guarantees all RT writes are visible before this is called.
    var buffersReceived: Int { _rtBuffersReceived }

    /// Buffers that were appended to the active recognition request this session.
    /// Same read constraint as `buffersReceived`.
    var buffersAppended: Int { _rtBuffersAppended }

#if DEBUG
    // MARK: - Testing support

    /// Marks the current session as having a write failure.
    ///
    /// **For testing only.** Reliably triggering `AVAudioFile.write(from:)` to
    /// throw in a unit-test environment requires hardware I/O conditions (full
    /// disk, revoked permissions) that are impractical to reproduce.  This method
    /// sets the flag directly under the lock so tests can verify that callers
    /// (`stopRecording`) correctly act on it — without simulating real I/O.
    func testOnly_recordWriteFailure() {
        lock.withLock { _hasWriteFailure = true }
    }
#endif

    /// Arm for recording. Call on MainActor **before** `installTap`.
    /// Resets the write-failure flag so a new session always starts clean.
    ///
    /// `recognitionRequest` is optional: pass `nil` when the SpeechTranscriber
    /// pipeline is active (Phase 2A) — audio is still written to `audioFile`
    /// but `recognitionRequest?.append(_:)` becomes a no-op in `feed`.
    func arm(
        audioFile: AVAudioFile,
        recognitionRequest: SFSpeechAudioBufferRecognitionRequest? = nil
    ) {
        // Reset RT counters before installTap. Safe: arm() is called on @MainActor
        // before installTap(), so no RT thread is writing to these yet.
        _rtBuffersReceived = 0
        _rtBuffersAppended = 0
        lock.withLock {
            self.audioFile          = audioFile
            self._audioFileURL      = audioFile.url
            self.recognitionRequest = recognitionRequest
            self._hasWriteFailure   = false
        }
    }

    /// Swap in a new recognition request (transparent ~60-second restart).
    /// Call on MainActor while the tap is still installed.
    ///
    /// `endAudio()` is called on the OLD request AFTER the lock is released so
    /// the audio IO thread (which calls `feed` under the same lock) is never
    /// blocked waiting for the speech-daemon XPC round-trip that `endAudio`
    /// triggers. Failing to call `endAudio` on the replaced request causes the
    /// daemon to throw a serialised ObjC exception that propagates back onto the
    /// audio IO thread and terminates the process via `std::terminate()`.
    func updateRequest(_ request: SFSpeechAudioBufferRecognitionRequest?) {
        var old: SFSpeechAudioBufferRecognitionRequest?
        lock.withLock {
            old = recognitionRequest
            recognitionRequest = request
        }
        old?.endAudio()  // outside lock — must not block the audio IO thread
    }

    /// Signal end-of-audio, then release both resources.
    /// `audioFileURL` is intentionally preserved so the recording path can be
    /// read by `stopRecording` after this call returns.
    /// Call on MainActor **after** `removeTap` returns.
    func disarm() {
        var old: SFSpeechAudioBufferRecognitionRequest?
        lock.withLock {
            old                = recognitionRequest
            recognitionRequest = nil
            audioFile          = nil
        }
        old?.endAudio()  // outside lock — XPC call; mirrors updateRequest() pattern (RULE-RT-02)
    }

    /// Deliver a captured audio buffer. Called on the Core-Audio I/O thread.
    ///
    /// Write errors are recorded in `hadWriteFailure` so `stopRecording` can surface
    /// them to the user instead of silently producing an incomplete or empty file.
    func feed(buffer: AVAudioPCMBuffer) {
        var didAppend = false
        lock.withLock {
            didAppend = recognitionRequest != nil
            recognitionRequest?.append(buffer)
            do {
                try audioFile?.write(from: buffer)
            } catch {
                _hasWriteFailure = true
            }
        }
        // No lock needed: written only here (Core-Audio I/O thread), read only by
        // @MainActor after removeTap() returns. removeTap() is the synchronization
        // barrier; when it returns, all RT writes are visible. (RULE-RT-02)
        _rtBuffersReceived &+= 1
        if didAppend { _rtBuffersAppended &+= 1 }
    }
}
