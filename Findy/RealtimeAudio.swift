import AVFoundation
import Foundation

/// Waiters are released only after the previous session has fully torn down.
@MainActor
final class VoiceShutdownWaiters {
    private var waiters: [UUID: CheckedContinuation<Void, Error>] = [:]
    private var isStopping = false
    var waiterCount: Int { waiters.count }

    func begin() { isStopping = true }

    func wait() async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                if Task.isCancelled { continuation.resume(throwing: CancellationError()) }
                else if !isStopping { continuation.resume() }
                else { waiters[id] = continuation }
            }
        } onCancel: { [weak self] in
            Task { @MainActor [weak self] in
                self?.waiters.removeValue(forKey: id)?.resume(throwing: CancellationError())
            }
        }
        try Task.checkCancellation()
    }

    func finish() {
        isStopping = false
        let pending = Array(waiters.values)
        waiters.removeAll()
        for waiter in pending { waiter.resume() }
    }
}

/// Short synthesized cues share the session's engine and never change the
/// AVAudioSession. Completion tracks playback, not just scheduling.
@MainActor
final class VoiceEarcons {
    enum Kind { case ready, search, end }
    private let player = AVAudioPlayerNode()
    private let format = AVAudioFormat(standardFormatWithSampleRate: 24_000, channels: 1)!
    private var pending: CheckedContinuation<Void, Never>?
    private var generation = UUID()
    var hasPendingPlayback: Bool { pending != nil }

    init(engine: AVAudioEngine) {
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: format)
    }

    func play(_ kind: Kind, timeout: Duration = .seconds(2)) async {
        stop()
        let frames = 3_600 // 150 ms
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)),
              let samples = buffer.floatChannelData?.pointee else { return }
        buffer.frameLength = AVAudioFrameCount(frames)
        for (index, sample) in Self.waveform(kind).enumerated() { samples[index] = sample }
        let token = UUID()
        generation = token
        Task { [weak self] in
            try? await Task.sleep(for: timeout)
            guard let self, self.generation == token, self.pending != nil else { return }
            self.stop()
        }
        await withCheckedContinuation { continuation in
            pending = continuation
            player.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { [weak self] _ in
                Task { @MainActor [weak self] in self?.finish(token) }
            }
            player.play()
        }
    }

    nonisolated static func waveform(_ kind: Kind) -> [Float] {
        (0..<3_600).map { index in
            let t = Double(index) / 24_000
            let segmentTime = kind == .search ? t.truncatingRemainder(dividingBy: 0.075) : t
            let segmentDuration = kind == .search ? 0.075 : 0.15
            let attack = min(1, segmentTime / 0.012)
            let release = min(1, max(0, (segmentDuration - segmentTime) / 0.035))
            let envelope = sin(.pi / 2 * attack) * exp(-segmentTime / 0.065) * sin(.pi / 2 * release)
            let phase: Double = switch kind {
            case .ready: 2 * .pi * 523.25 * t
            case .search: 2 * .pi * (index < 1_800 ? 392 : 493.88) * segmentTime
            case .end: 2 * .pi * (392 * t - (62 / 0.15) * t * t / 2)
            }
            let volume = kind == .search ? 0.070 : 0.090
            // A softly struck, decaying tone rather than a sustained sine.
            // Inharmonic overtones fade faster than the warm fundamental.
            let overtones = exp(-segmentTime / 0.025) * (0.19 * sin(2.71 * phase) + 0.05 * sin(4.07 * phase))
            return Float(volume * envelope * (sin(phase) + overtones) / 1.24)
        }
    }

    func stop() {
        generation = UUID()
        player.stop()
        let continuation = pending
        pending = nil
        continuation?.resume()
    }

    private func finish(_ token: UUID) {
        guard generation == token else { return }
        let continuation = pending
        pending = nil
        continuation?.resume()
    }
}

/// Captures PCM16/24 kHz without networking or spawning tasks on the render
/// thread. A single sender drains the bounded queue and applies backpressure.
final class RealtimeAudioInput: @unchecked Sendable {
    private let lock = NSLock()
    private let converter: AVAudioConverter
    private let target: AVAudioFormat
    private var pending = Data()
    private var buffers = 0
    private var lastBufferAt: TimeInterval = 0
    private var level: Float = -160
    private var failure = false
    private var enabled = true
    private var muted = false
    private static let maximumBytes = 24_000 * 2 * 8

    init(format: AVAudioFormat, initiallyMuted: Bool = false) throws {
        guard let target = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 24_000, channels: 1, interleaved: true),
              let converter = AVAudioConverter(from: format, to: target) else {
            throw RealtimeAudioError.invalidFormat
        }
        self.target = target
        self.converter = converter
        self.muted = initiallyMuted
    }

    func consume(_ buffer: AVAudioPCMBuffer) {
        let count = Int(buffer.frameLength)
        var sum: Float = 0
        if let samples = buffer.floatChannelData?.pointee, count > 0 {
            for index in 0..<count { sum += samples[index] * samples[index] }
        }
        let decibels: Float = count > 0 ? 10 * log10(max(sum / Float(count), 1e-16)) : -160
        let capacity = AVAudioFrameCount(ceil(Double(buffer.frameLength) * target.sampleRate / buffer.format.sampleRate) + 32)
        guard let converted = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else {
            markFailed()
            return
        }
        var supplied = false
        var error: NSError?
        let status = converter.convert(to: converted, error: &error) { _, inputStatus in
            guard !supplied else { inputStatus.pointee = .noDataNow; return nil }
            supplied = true
            inputStatus.pointee = .haveData
            return buffer
        }
        let instant = ProcessInfo.processInfo.systemUptime
        lock.lock()
        defer { lock.unlock() }
        guard enabled else { return }
        buffers += 1
        lastBufferAt = instant
        level = decibels
        guard !muted else { return }
        guard error == nil, status != .error else { failure = true; return }
        guard converted.frameLength > 0, let samples = converted.int16ChannelData?.pointee else { return }
        let size = Int(converted.frameLength) * MemoryLayout<Int16>.size
        guard pending.count + size <= Self.maximumBytes else { failure = true; return }
        pending.append(UnsafeBufferPointer(start: UnsafeRawPointer(samples).assumingMemoryBound(to: UInt8.self), count: size))
    }

    func drain() throws -> Data? {
        lock.lock()
        defer { lock.unlock() }
        guard !failure else { throw RealtimeAudioError.inputBackpressure }
        guard enabled, !pending.isEmpty else { return nil }
        let count = min(pending.count, 4_800) // at most 100 ms per WS message
        let data = Data(pending.prefix(count))
        pending.removeFirst(count)
        return data
    }

    func snapshot() -> (buffers: Int, lastBufferAt: TimeInterval, level: Float) {
        lock.lock()
        defer { lock.unlock() }
        return (buffers, lastBufferAt, level)
    }

    func stop() {
        lock.lock()
        enabled = false
        pending.removeAll(keepingCapacity: false)
        lock.unlock()
    }

    func setMuted(_ muted: Bool) {
        lock.lock()
        self.muted = muted
        if muted { pending.removeAll(keepingCapacity: true) }
        lock.unlock()
    }

    private func markFailed() {
        lock.lock()
        failure = true
        lock.unlock()
    }
}

/// Streams server PCM into the same engine that owns the AirPods microphone.
/// Completion uses dataPlayedBack, so the silence clock starts after hearing
/// the answer, not after the server finishes generating it.
@MainActor
final class RealtimeAudioOutput {
    struct Position {
        let itemID: String
        let contentIndex: Int
        let milliseconds: Int
    }

    private struct Segment {
        let itemID: String
        let contentIndex: Int
        let start: Int64
        var end: Int64
    }

    private struct MeterWindow {
        let end: Int64
        let decibels: Float
    }

    private let player = AVAudioPlayerNode()
    private let format = AVAudioFormat(standardFormatWithSampleRate: 24_000, channels: 1)!
    private var generation = UUID()
    private var scheduledFrames: Int64 = 0
    private var completedFrames: Int64 = 0
    private var segments: [Segment] = []
    private var playedOffsets: [String: Int64] = [:]
    private var pendingBuffers = 0
    private var meterWindows: [MeterWindow] = []
    private var meterSquareSum: Float = 0
    private var meterWindowSamples = 0
    var onDrained: (() -> Void)?

    var isPlaying: Bool { pendingBuffers > 0 }

    /// Sampled by the existing 100 ms session monitor. Windows follow the
    /// player's playhead, rather than the faster arriving network chunks.
    func playbackLevel() -> Float {
        guard isPlaying, let render = player.lastRenderTime,
              let time = player.playerTime(forNodeTime: render) else { return -160 }
        let played = min(scheduledFrames, max(completedFrames, time.sampleTime))
        if let index = meterWindows.firstIndex(where: { $0.end > played }) {
            if index > 0 { meterWindows.removeFirst(index) }
            return meterWindows.first?.decibels ?? -160
        }
        meterWindows.removeAll(keepingCapacity: true)
        return -160
    }

    init(engine: AVAudioEngine) {
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: format)
    }

    func append(_ data: Data, itemID: String, contentIndex: Int) throws {
        guard data.count % 2 == 0 else { throw RealtimeAudioError.invalidFormat }
        guard !data.isEmpty else { return }
        let count = data.count / 2
        guard count <= 24_000 * 10,
              pendingBuffers < 4_096,
              scheduledFrames - completedFrames + Int64(count) <= 24_000 * 90,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count)),
              let destination = buffer.floatChannelData?.pointee else { throw RealtimeAudioError.outputBackpressure }
        buffer.frameLength = AVAudioFrameCount(count)
        data.withUnsafeBytes { bytes in
            for index in 0..<count {
                let value = bytes.loadUnaligned(fromByteOffset: index * 2, as: Int16.self)
                let sample = Float(Int16(littleEndian: value)) / 32768
                destination[index] = sample
                meterSquareSum += sample * sample
                meterWindowSamples += 1
                // Carry partial windows across network chunks: at most 1,800
                // readings for the already bounded 90 second playback queue.
                if meterWindowSamples == 1_200 {
                    meterWindows.append(MeterWindow(end: scheduledFrames + Int64(index + 1),
                        decibels: 10 * log10(max(meterSquareSum / Float(meterWindowSamples), 1e-16))))
                    meterSquareSum = 0
                    meterWindowSamples = 0
                }
            }
        }
        if let last = segments.indices.last, segments[last].itemID == itemID, segments[last].contentIndex == contentIndex {
            segments[last].end += Int64(count)
        } else {
            segments.append(Segment(itemID: itemID, contentIndex: contentIndex, start: scheduledFrames, end: scheduledFrames + Int64(count)))
        }
        scheduledFrames += Int64(count)
        pendingBuffers += 1
        let token = generation
        player.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.generation == token else { return }
                self.completedFrames += Int64(count)
                self.pendingBuffers -= 1
                if self.pendingBuffers == 0 {
                    for segment in self.segments {
                        self.playedOffsets[segment.itemID, default: 0] += segment.end - segment.start
                    }
                    if self.playedOffsets.count > 64 {
                        self.playedOffsets = [itemID: self.playedOffsets[itemID] ?? 0]
                    }
                    // A player timeline includes idle time. Reset it whenever
                    // the queue empties; offsets retain actual played audio.
                    self.generation = UUID()
                    self.player.stop()
                    self.scheduledFrames = 0
                    self.completedFrames = 0
                    self.segments = []
                    self.meterWindows.removeAll(keepingCapacity: true)
                    self.meterSquareSum = 0
                    self.meterWindowSamples = 0
                    self.onDrained?()
                }
            }
        }
        if !player.isPlaying { player.play() }
    }

    @discardableResult
    func interrupt() -> Position? {
        let played: Int64
        if let render = player.lastRenderTime, let time = player.playerTime(forNodeTime: render) {
            played = min(scheduledFrames, max(completedFrames, time.sampleTime))
        } else { played = completedFrames }
        let segment = segments.first { $0.end > played }
        let position = segment.map {
            Position(itemID: $0.itemID, contentIndex: $0.contentIndex,
                     milliseconds: max(0, Int(Double((playedOffsets[$0.itemID] ?? 0) + played - $0.start) / 24)))
        }
        generation = UUID()
        player.stop()
        scheduledFrames = 0
        completedFrames = 0
        pendingBuffers = 0
        segments = []
        meterWindows.removeAll(keepingCapacity: true)
        meterSquareSum = 0
        meterWindowSamples = 0
        playedOffsets = [:]
        return position
    }

    func stop() {
        generation = UUID()
        player.stop()
        pendingBuffers = 0
        segments = []
        meterWindows = []
        meterSquareSum = 0
        meterWindowSamples = 0
        playedOffsets = [:]
        onDrained = nil
    }
}

private enum RealtimeAudioError: LocalizedError {
    case invalidFormat, inputBackpressure, outputBackpressure
    var errorDescription: String? {
        switch self {
        case .invalidFormat: return "Не удалось преобразовать голос в аудиоформат Realtime."
        case .inputBackpressure: return "Соединение Realtime не успевает передавать звук. Повторите запуск."
        case .outputBackpressure: return "Ответ Realtime превысил доступный аудиобуфер."
        }
    }
}
