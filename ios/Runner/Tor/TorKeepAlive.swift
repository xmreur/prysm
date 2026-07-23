import AVFoundation
import Foundation

/// Keeps the app process alive in background while Tor is running.
final class TorKeepAlive {
    static let shared = TorKeepAlive()

    private var player: AVAudioPlayer?
    private let lock = NSLock()

    private init() {}

    func start() {
        lock.lock()
        defer { lock.unlock() }

        guard player == nil else { return }

        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
            try session.setActive(true)

            let url = try Self.silentWavURL()
            let audioPlayer = try AVAudioPlayer(contentsOf: url)
            audioPlayer.numberOfLoops = -1
            audioPlayer.volume = 0.01
            audioPlayer.prepareToPlay()
            guard audioPlayer.play() else {
                NSLog("TorKeepAlive: play() returned false")
                return
            }
            player = audioPlayer
        } catch {
            NSLog("TorKeepAlive failed to start: \(error)")
        }
    }

    func stop() {
        lock.lock()
        defer { lock.unlock() }

        player?.stop()
        player = nil

        do {
            try AVAudioSession.sharedInstance().setActive(
                false,
                options: .notifyOthersOnDeactivation
            )
        } catch {
            NSLog("TorKeepAlive failed to deactivate session: \(error)")
        }
    }

    private static func silentWavURL() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("prysm_tor_keepalive.wav")

        if FileManager.default.fileExists(atPath: url.path) {
            return url
        }

        let sampleRate: UInt32 = 44100
        let channels: UInt16 = 1
        let bitsPerSample: UInt16 = 16
        let durationSeconds = 1.0
        let numSamples = Int(Double(sampleRate) * durationSeconds)
        let dataSize = numSamples * Int(channels) * Int(bitsPerSample / 8)
        let byteRate = sampleRate * UInt32(channels) * UInt32(bitsPerSample / 8)
        let blockAlign = channels * (bitsPerSample / 8)

        var data = Data()
        data.append(contentsOf: [0x52, 0x49, 0x46, 0x46]) // RIFF
        let chunkSize = UInt32(36 + dataSize)
        data.append(contentsOf: withUnsafeBytes(of: chunkSize.littleEndian) { Array($0) })
        data.append(contentsOf: [0x57, 0x41, 0x56, 0x45]) // WAVE
        data.append(contentsOf: [0x66, 0x6D, 0x74, 0x20]) // fmt
        data.append(contentsOf: withUnsafeBytes(of: UInt32(16).littleEndian) { Array($0) })
        data.append(contentsOf: withUnsafeBytes(of: UInt16(1).littleEndian) { Array($0) })
        data.append(contentsOf: withUnsafeBytes(of: channels.littleEndian) { Array($0) })
        data.append(contentsOf: withUnsafeBytes(of: sampleRate.littleEndian) { Array($0) })
        data.append(contentsOf: withUnsafeBytes(of: byteRate.littleEndian) { Array($0) })
        data.append(contentsOf: withUnsafeBytes(of: blockAlign.littleEndian) { Array($0) })
        data.append(contentsOf: withUnsafeBytes(of: bitsPerSample.littleEndian) { Array($0) })
        data.append(contentsOf: [0x64, 0x61, 0x74, 0x61]) // data
        data.append(contentsOf: withUnsafeBytes(of: UInt32(dataSize).littleEndian) { Array($0) })
        data.append(Data(count: dataSize))

        try data.write(to: url, options: .atomic)
        return url
    }
}
