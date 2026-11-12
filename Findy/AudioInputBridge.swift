import AVFoundation
import Foundation
import Speech

// The audio render callback never hops to the main actor or allocates a Task.
// Only this bridge crosses from the audio thread to the session controller.
final class AudioInputBridge: @unchecked Sendable {
    private let lock = NSLock()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var lastEnergyTime: TimeInterval = 0
    private var level: Float = -160
    private var receivedBuffers = 0
    private var lastBufferTime: TimeInterval = 0

    func listen(using request: SFSpeechAudioBufferRecognitionRequest) {
        lock.lock()
        self.request = request
        lastEnergyTime = 0
        lock.unlock()
    }

    func pauseRecognition() {
        lock.lock()
        request = nil
        lastEnergyTime = 0
        lock.unlock()
    }

    func consume(_ buffer: AVAudioPCMBuffer) {
        var sum: Float = 0
        let count = Int(buffer.frameLength)
        if let samples = buffer.floatChannelData?.pointee, count > 0 {
            for index in 0..<count { sum += samples[index] * samples[index] }
        }
        let decibels: Float = count > 0 ? 10 * log10(max(sum / Float(count), 1e-16)) : -160

        lock.lock()
        receivedBuffers += 1
        lastBufferTime = ProcessInfo.processInfo.systemUptime
        level = decibels
        if request != nil, decibels > -38 {
            lastEnergyTime = ProcessInfo.processInfo.systemUptime
        }
        request?.append(buffer)
        lock.unlock()
    }

    func snapshot() -> (lastEnergyTime: TimeInterval, level: Float, buffers: Int, lastBufferTime: TimeInterval) {
        lock.lock()
        defer { lock.unlock() }
        return (lastEnergyTime, level, receivedBuffers, lastBufferTime)
    }
}
