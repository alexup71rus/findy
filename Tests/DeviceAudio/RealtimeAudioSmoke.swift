import AVFoundation
import Foundation

/// Standalone software-only smoke check. Compile together with RealtimeAudio.swift.
/// No AVAudioEngine, microphone, player, audio session or network is started.
@main
enum RealtimeAudioSmoke {
    static func main() async throws {
        for (rate, channels) in [(24_000.0, 1), (48_000.0, 2), (44_100.0, 1)] {
            try checkConversion(sampleRate: rate, channels: AVAudioChannelCount(channels))
        }
        try checkStopClearsAndDisablesQueue()
        try checkCueGateDiscardsAudio()
        try checkCueWaveforms()
        await checkCueCancellation()
        await checkEndCueTimeout()
        try await checkShutdownWaiters()
        try checkEightSecondBackpressure()
        print("PASS: synthetic conversion, signal level, queue stop and eight-second backpressure")
    }

    @MainActor
    private static func checkShutdownWaiters() async throws {
        let gate = VoiceShutdownWaiters()
        gate.begin()
        let cancelled = Task { try await gate.wait() }
        let resumed = Task { try await gate.wait() }
        while gate.waiterCount < 2 { await Task.yield() }
        cancelled.cancel()
        do { try await cancelled.value; throw SmokeFailure(message: "Cancelled start waited successfully") }
        catch is CancellationError { }
        try require(gate.waiterCount == 1, "Cancelling one start removed another waiter")
        gate.finish()
        try await resumed.value
        try await gate.wait() // no missed wakeup if shutdown already finished
        try require(gate.waiterCount == 0, "Shutdown retained completed waiters")
        print("PASS: shutdown queues starts, isolates cancellation, and avoids missed completion")
    }

    @MainActor
    private static func checkEndCueTimeout() async {
        let engine = AVAudioEngine()
        let cues = VoiceEarcons(engine: engine)
        let started = ProcessInfo.processInfo.systemUptime
        await cues.play(.end, timeout: .milliseconds(350))
        precondition(ProcessInfo.processInfo.systemUptime - started < 1.5 && !cues.hasPendingPlayback)
        print("PASS: end cue times out and releases playback without a running engine")
    }

    @MainActor
    private static func checkCueCancellation() async {
        let engine = AVAudioEngine() // never started; no device is opened
        let cues = VoiceEarcons(engine: engine)
        var opened = false
        let playback = Task { await cues.play(.ready, onPlayedBack: { opened = true }) }
        while !cues.hasPendingPlayback { await Task.yield() }
        cues.stop()
        let played = await playback.value
        precondition(!played && !opened)
        print("PASS: stopping a pending cue releases its waiter without opening its gate")
    }

    private static func checkCueWaveforms() throws {
        let ready = VoiceEarcons.waveform(.ready)
        let search = VoiceEarcons.waveform(.search)
        let end = VoiceEarcons.waveform(.end)
        for samples in [ready, search, end] {
            try require(samples.count == 3_600 && samples.allSatisfy { $0.isFinite && abs($0) <= 0.10 }, "Cue duration or amplitude is invalid")
            try require(abs(samples[0]) < 0.001 && abs(samples[3_599]) < 0.001, "Cue lacks a smooth start or end")
            let largestStep = zip(samples, samples.dropFirst()).map { abs($0 - $1) }.max() ?? 0
            try require(largestStep < 0.03, "Cue has a discontinuity likely to click")
            try require(samples.contains { abs($0) > 0.015 }, "Cue signal is silent")
        }
        try require(abs(search[1_800]) < 0.001 && ready != search && ready != end && search != end, "Cues must be distinct and smoothly joined")
        let peaks = [ready, search, end].map { samples in samples.map { abs($0) }.max() ?? 0 }
        print("PASS: distinct 150 ms cues are finite, bounded and smooth; peaks \(peaks)")
    }

    private static func checkCueGateDiscardsAudio() throws {
        let format = try makeFormat(sampleRate: 24_000, channels: 1)
        let buffer = try sine(format: format, frameCount: 2_400)
        let input = try RealtimeAudioInput(format: format, initiallyMuted: true)
        input.consume(buffer)
        try require(input.snapshot().buffers == 1, "Muted input must still report the microphone heartbeat")
        try require(try input.drain() == nil, "Initial readiness cue leaked into the input queue")
        input.setMuted(false)
        input.consume(buffer)
        input.setMuted(true)
        try require(try input.drain() == nil, "Cue gate did not clear pre-gate queued audio")
        input.consume(buffer)
        try require(try input.drain() == nil, "Audio was queued during the cue")
        input.setMuted(false)
        input.consume(buffer)
        try require(try input.drain()?.isEmpty == false, "Input did not resume after the cue")
        input.stop()
        print("PASS: cue gate retains heartbeat, clears buffered audio, and resumes input")
    }

    private static func checkConversion(sampleRate: Double, channels: AVAudioChannelCount) throws {
        let format = try makeFormat(sampleRate: sampleRate, channels: channels)
        let input = try RealtimeAudioInput(format: format)
        let frames = Int(sampleRate / 10)
        for index in 0..<10 {
            input.consume(try sine(format: format, frameCount: frames, offset: index * frames))
        }
        let snapshot = input.snapshot()
        try require(snapshot.buffers == 10, "Not all synthetic input buffers were consumed")
        try require(snapshot.lastBufferAt > 0, "Input heartbeat was not recorded")
        try require(snapshot.level.isFinite && snapshot.level > -20 && snapshot.level < -10,
                    "Input RMS does not match a nonzero 0.25-amplitude sine")

        let data = try drainAll(input)
        let expectedBytes = 24_000 * MemoryLayout<Int16>.size
        // Resampling may retain a short filter/priming tail. A ±43 ms window
        // still distinguishes 24 kHz mono PCM16 from a wrong channel/rate/width.
        try require(abs(data.count - expectedBytes) <= 2_048,
                    "Converted byte count is incompatible with one second of PCM16 mono/24 kHz")
        let samples: [Int16] = data.withUnsafeBytes { bytes in
            (0..<(bytes.count / 2)).map { Int16(littleEndian: bytes.loadUnaligned(fromByteOffset: $0 * 2, as: Int16.self)) }
        }
        try require(samples.contains(where: { $0 > 0 }) && samples.contains(where: { $0 < 0 }),
                    "Converted PCM has no signed waveform")
        let energy = samples.reduce(0.0) { result, value in
            let normalized = Double(value) / 32_768
            return result + normalized * normalized
        }
        let rms = sqrt(energy / Double(samples.count))
        try require(rms > 0.10 && rms < 0.26, "PCM16 signal amplitude is invalid or not little-endian")
        input.stop()
        print("PASS: \(Int(sampleRate)) Hz / \(channels) channel(s) → PCM16 mono/24000 Hz; \(data.count) bytes")
    }

    private static func checkStopClearsAndDisablesQueue() throws {
        let format = try makeFormat(sampleRate: 24_000, channels: 1)
        let input = try RealtimeAudioInput(format: format)
        let buffer = try sine(format: format, frameCount: 7_200)
        input.consume(buffer)
        let first = try input.drain()
        try require(first?.count == 4_800, "Drain should return at most 100 ms and leave queued audio")
        input.stop()
        try require(try input.drain() == nil, "Stop did not clear queued audio")
        let buffersAfterStop = input.snapshot().buffers
        input.consume(buffer)
        try require(try input.drain() == nil, "Stopped input accepted more audio")
        try require(input.snapshot().buffers == buffersAfterStop, "Stopped input advanced its heartbeat")
        print("PASS: stop clears pending audio and rejects later input")
    }

    private static func checkEightSecondBackpressure() throws {
        let format = try makeFormat(sampleRate: 24_000, channels: 1)
        let buffer = try sine(format: format, frameCount: 2_400)
        let atLimit = try RealtimeAudioInput(format: format)
        for _ in 0..<80 { atLimit.consume(buffer) }
        let accepted = try drainAll(atLimit)
        try require(accepted.count == 24_000 * 2 * 8, "Eight seconds of same-rate PCM16 should fit the queue exactly")
        atLimit.stop()

        let overflow = try RealtimeAudioInput(format: format)
        for _ in 0..<81 { overflow.consume(buffer) }
        var rejected = false
        do { _ = try overflow.drain() } catch { rejected = true }
        try require(rejected, "Producing more than eight seconds without a consumer did not raise backpressure")
        overflow.consume(buffer)
        var stillRejected = false
        do { _ = try overflow.drain() } catch { stillRejected = true }
        try require(stillRejected, "Overflow was silently cleared instead of remaining a terminal input failure")
        overflow.stop()
        print("PASS: 8.0 seconds fit; 8.1 seconds without draining raise bounded backpressure")
    }

    private static func makeFormat(sampleRate: Double, channels: AVAudioChannelCount) throws -> AVAudioFormat {
        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: channels, interleaved: false) else {
            throw SmokeFailure(message: "Could not allocate a synthetic float PCM format")
        }
        return format
    }

    private static func sine(format: AVAudioFormat, frameCount: Int, offset: Int = 0) throws -> AVAudioPCMBuffer {
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frameCount)),
              let channels = buffer.floatChannelData else {
            throw SmokeFailure(message: "Could not allocate a synthetic float PCM buffer")
        }
        buffer.frameLength = AVAudioFrameCount(frameCount)
        for channel in 0..<Int(format.channelCount) {
            for index in 0..<frameCount {
                channels[channel][index] = 0.25 * Float(sin(2 * Double.pi * 440 * Double(offset + index) / format.sampleRate))
            }
        }
        return buffer
    }

    private static func drainAll(_ input: RealtimeAudioInput) throws -> Data {
        var result = Data()
        while let chunk = try input.drain() {
            try require(!chunk.isEmpty && chunk.count <= 4_800 && chunk.count.isMultiple(of: 2), "Invalid PCM16 drain chunk")
            result.append(chunk)
        }
        return result
    }

    private static func require(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
        guard try condition() else { throw SmokeFailure(message: message) }
    }
}

private struct SmokeFailure: Error, CustomStringConvertible {
    let message: String
    var description: String { message }
}
