//  OutputRecorder.swift
//  撮影用。このアプリがスピーカーへ出している音（鎖を通った後）をファイルへ書く。
//  **Debug ビルドだけ。**引数 -ETRecordOutput <秒> を付けたときだけ動く。既定は何もしない。
//
//  iOS の画面収録がこのアプリの音を拾わなかったときの代わり。書く先は
//    Documents/et-output.caf    48kHz（セッションのレート）float32 の stereo
//    Documents/et-output.json   最初のサンプルの host time と UNIX 時刻（画面収録と合わせる用）
//
//  取り方は mainMixerNode の tap。tap のブロックは音のスレッドではないので、そこで写して
//  直列のキューで書く。音のスレッド（AudioIO の AVAudioSourceNode）には何も足さない。
//
//  CAF は data の大きさを -1（ファイルの終わりまで）で書いておく。アプリが途中で
//  落とされても読める。決めた秒数に達したら大きさを書き直して閉じる。
//  engine の組み直しで空いた間は host time から無音で埋めるので、ファイルの時刻は
//  最初のサンプルからの実時間のまま進む。

#if DEBUG
import AVFoundation
import Foundation
import os

final class ETOutputRecorder: @unchecked Sendable {
    static let shared = ETOutputRecorder()

    /// 書く秒数。0 なら何もしない。
    let seconds: Double = max(0, UserDefaults.standard.double(forKey: "ETRecordOutput"))
    var enabled: Bool { seconds > 0 }

    private let log = Logger(subsystem: "ai.nemut.effetune", category: "record")
    private let queue = DispatchQueue(label: "ai.nemut.effectpass.output-recorder", qos: .utility)
    private let done = OSAllocatedUnfairLock(initialState: false)

    // 以下は queue の上でだけ触る。
    private var handle: FileHandle?
    private var sampleRate: Double = 0
    private var framesWritten = 0
    private var maxFrames = 0
    private var nextHostSeconds: Double?
    private var firstHostTime: UInt64 = 0
    private var firstUnix: Double = 0
    private var reportedRateMismatch = false

    private static let dataSizeOffset: UInt64 = 56   // 'caff'(8) + 'desc'(12+32) + 'data' の型(4)

    private var docs: URL { FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0] }
    private var cafURL: URL { docs.appendingPathComponent("et-output.caf") }
    private var jsonURL: URL { docs.appendingPathComponent("et-output.json") }

    /// engine.start() のたびに呼ぶ。engine を作り直しても tap が付き直る。
    /// **@MainActor にしない。**tap のブロックが main の隔離を継いで、tap のスレッドで落ちるのを避ける。
    func attach(to engine: AVAudioEngine) {
        guard enabled, !done.withLock({ $0 }) else { return }
        let session = AVAudioSession.sharedInstance()
        let line = String(format: "ETRecordOutput attach sr=%.0f outputLatency=%.4f ioBuffer=%.4f",
                          session.sampleRate, session.outputLatency, session.ioBufferDuration)
        log.notice("\(line, privacy: .public)")
        print(line)
        let mixer = engine.mainMixerNode
        mixer.removeTap(onBus: 0)
        mixer.installTap(onBus: 0, bufferSize: 4096, format: nil) { [weak self] buffer, when in
            self?.take(buffer, when)
        }
    }

    /// tap のスレッド。stereo のインターリーブへ写して queue へ渡す。
    private func take(_ buffer: AVAudioPCMBuffer, _ when: AVAudioTime) {
        guard !done.withLock({ $0 }) else { return }
        let frames = Int(buffer.frameLength)
        let channels = Int(buffer.format.channelCount)
        guard frames > 0, channels > 0, let ch = buffer.floatChannelData else { return }
        let stride = buffer.stride
        let left = ch[0]
        let right = buffer.format.isInterleaved ? ch[0] + (channels > 1 ? 1 : 0)
                                                : ch[channels > 1 ? 1 : 0]
        var data = Data(count: frames * 8)
        data.withUnsafeMutableBytes { raw in
            let out = raw.bindMemory(to: Float.self)
            for i in 0..<frames {
                out[i * 2] = left[i * stride]
                out[i * 2 + 1] = right[i * stride]
            }
        }
        let rate = buffer.format.sampleRate
        let host: UInt64? = when.isHostTimeValid ? when.hostTime : nil
        queue.async { self.write(data, frames: frames, rate: rate, host: host) }
    }

    private func write(_ data: Data, frames: Int, rate: Double, host: UInt64?) {
        guard !done.withLock({ $0 }) else { return }
        if handle == nil, !open(rate: rate, host: host) {
            done.withLock { $0 = true }
            return
        }
        guard let handle else { return }
        guard rate == sampleRate else {
            if !reportedRateMismatch {
                reportedRateMismatch = true
                let line = "ETRecordOutput rate changed \(rate) != \(sampleRate), skipping those buffers"
                log.error("\(line, privacy: .public)")
                print(line)
            }
            return
        }
        let hostSeconds = host.map { AVAudioTime.seconds(forHostTime: $0) }
        // 組み直しで空いた間は無音で埋める（ファイルの時刻を実時間に揃えておく）。
        if let now = hostSeconds, let expected = nextHostSeconds, now - expected > 0.02 {
            let gap = min(Int((now - expected) * rate), maxFrames - framesWritten)
            if gap > 0 {
                handle.write(Data(count: gap * 8))
                framesWritten += gap
                let line = String(format: "ETRecordOutput gap %.3fs filled at t=%.3f",
                                  now - expected, Double(framesWritten) / rate)
                log.notice("\(line, privacy: .public)")
                print(line)
            }
        }
        let take = min(frames, maxFrames - framesWritten)
        if take > 0 {
            handle.write(take == frames ? data : data.prefix(take * 8))
            framesWritten += take
        }
        let base = hostSeconds ?? nextHostSeconds ?? 0
        nextHostSeconds = base + Double(frames) / rate
        if framesWritten >= maxFrames { finish() }
    }

    private func open(rate: Double, host: UInt64?) -> Bool {
        let fm = FileManager.default
        try? fm.removeItem(at: cafURL)
        guard rate > 0, fm.createFile(atPath: cafURL.path, contents: Self.header(sampleRate: rate)),
              let h = try? FileHandle(forWritingTo: cafURL) else {
            log.error("ETRecordOutput cannot create \(self.cafURL.path, privacy: .public)")
            print("ETRecordOutput cannot create \(cafURL.path)")
            return false
        }
        _ = try? h.seekToEnd()
        handle = h
        sampleRate = rate
        maxFrames = Int(seconds * rate)
        // 最初のサンプルの時刻。host time が無ければいまを使う。
        let nowHost = mach_absolute_time()
        firstHostTime = host ?? nowHost
        let age = AVAudioTime.seconds(forHostTime: nowHost) - AVAudioTime.seconds(forHostTime: firstHostTime)
        firstUnix = Date().timeIntervalSince1970 - age
        writeSidecar(frames: nil)
        let line = String(format: "ETRecordOutput first sample hostTime=%llu hostSeconds=%.6f unix=%.6f sr=%.0f file=%@",
                          firstHostTime, AVAudioTime.seconds(forHostTime: firstHostTime), firstUnix, rate, cafURL.path)
        log.notice("\(line, privacy: .public)")
        print(line)
        return true
    }

    private func finish() {
        guard let handle else { return }
        // data の大きさ = editCount(4) + 音のバイト数。
        var size = Int64(4 + framesWritten * 8).bigEndian
        try? handle.seek(toOffset: Self.dataSizeOffset)
        handle.write(Data(bytes: &size, count: 8))
        try? handle.close()
        self.handle = nil
        done.withLock { $0 = true }
        writeSidecar(frames: framesWritten)
        let line = String(format: "ETRecordOutput done frames=%d seconds=%.3f", framesWritten,
                          Double(framesWritten) / sampleRate)
        log.notice("\(line, privacy: .public)")
        print(line)
    }

    private func writeSidecar(frames: Int?) {
        var info: [String: Any] = [
            "file": "et-output.caf",
            "sampleRate": sampleRate,
            "channels": 2,
            "format": "float32le interleaved",
            "firstSampleHostTime": firstHostTime,
            "firstSampleHostSeconds": AVAudioTime.seconds(forHostTime: firstHostTime),
            "firstSampleUnix": firstUnix,
            "requestedSeconds": seconds,
        ]
        if let frames { info["frames"] = frames }
        if let json = try? JSONSerialization.data(withJSONObject: info, options: [.prettyPrinted, .sortedKeys]) {
            try? json.write(to: jsonURL, options: .atomic)
        }
    }

    /// CAF の頭（Apple の CAF 仕様）。数は big endian、音は little endian の float32。
    private static func header(sampleRate: Double) -> Data {
        var d = Data()
        func u32(_ v: UInt32) { var b = v.bigEndian; d.append(Data(bytes: &b, count: 4)) }
        func u16(_ v: UInt16) { var b = v.bigEndian; d.append(Data(bytes: &b, count: 2)) }
        func i64(_ v: Int64) { var b = v.bigEndian; d.append(Data(bytes: &b, count: 8)) }
        func tag(_ s: String) { d.append(contentsOf: Array(s.utf8)) }
        tag("caff"); u16(1); u16(0)
        tag("desc"); i64(32)
        var rate = sampleRate.bitPattern.bigEndian
        d.append(Data(bytes: &rate, count: 8))
        tag("lpcm")
        u32(1 | 2)      // kCAFLinearPCMFormatFlagIsFloat | IsLittleEndian
        u32(8)          // bytes per packet（stereo float32）
        u32(1)          // frames per packet
        u32(2)          // channels
        u32(32)         // bits per channel
        tag("data"); i64(-1)   // 大きさ不明＝ファイルの終わりまで。finish() で書き直す
        u32(0)          // edit count
        return d
    }
}
#endif
