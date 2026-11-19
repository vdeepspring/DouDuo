// 无缝倍速音频管线：
// AVPlayer（及 AVSampleBufferAudioRenderer）底层共用 FigAudioQueue，任意两个非零速率切换（如 1x↔2x）
// 都会触发内部队列自动 Flush，造成 60~90ms 静音空洞与恢复瞬间的硬切爆音。
// 本模块将短视频解耦为：
//   1. 画面：继续由 AVPlayer 硬解渲染，但禁用 AVPlayerItem 的音频轨（不建 FigAudioQueue，变速 0ms 停顿）
//   2. 声音：通过 iOS 16+ 原生 AVSampleCursor + AVSampleBufferGenerator 走 HTTP Range 按需拉取 AAC/HE-AAC 包，
//      经 AVAudioConverter 连续解码为 PCM（分片间返回 .noDataNow 保持 MDCT 窗口连续），
//      送入全局唯一 AVAudioEngine（AVAudioPlayerNode → AVAudioUnitTimePitch）实时变速不变调播放。
import Foundation
import AVFoundation
import CoreMedia
import AudioToolbox
#if canImport(UIKit)
import UIKit
#endif

// MARK: - 1. 全局唯一硬件音频输出引擎（避免多页滑动反复启停 CoreAudio 线程，杜绝双声与后台漏音）

// BEGIN DDAudioInterruptionGate
/// 非 1x 共享引擎的中断门闩。自动重开只在 clear 时允许；系统不允许恢复时保持锁，直到当前 owner 再次显式 play。
struct DDAudioInterruptionGate: Equatable {
    enum Phase: Equatable {
        case clear
        case active
        case endedWithoutResume
    }
    var phase: Phase = .clear

    mutating func began() { phase = .active }

    mutating func ended(shouldResume: Bool) {
        guard phase == .active else { return }
        phase = shouldResume ? .clear : .endedWithoutResume
    }

    var allowsAutomaticStart: Bool { phase == .clear }

    mutating func explicitPlay() {
        if phase == .endedWithoutResume { phase = .clear }
    }
}
// END DDAudioInterruptionGate

@MainActor
final class DDAudioEngineHub {
    static let shared = DDAudioEngineHub()

    let engine = AVAudioEngine()
    let playerNode = AVAudioPlayerNode()
    let timePitch = AVAudioUnitTimePitch()

    private(set) var activeOwner: UUID?
    private var connectedFormat: AVAudioFormat?
    private var isMuted = false
    private var interruption = DDAudioInterruptionGate()
    var allowsAutomaticStart: Bool { interruption.allowsAutomaticStart }

    private init() {
        engine.attach(playerNode)
        engine.attach(timePitch)
        timePitch.rate = 1.0
        timePitch.pitch = 0.0
        timePitch.overlap = 8.0
        installObservers()
    }

    private func installObservers() {
        #if canImport(UIKit)
        NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: AVAudioSession.sharedInstance(),
            queue: .main
        ) { [weak self] note in
            guard let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
            let optionsRaw = note.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
            let shouldResume = AVAudioSession.InterruptionOptions(rawValue: optionsRaw).contains(.shouldResume)
            MainActor.assumeIsolated {
                guard let self else { return }
                switch type {
                case .began:
                    self.interruption.began()
                    self.playerNode.pause()
                case .ended:
                    self.interruption.ended(shouldResume: shouldResume)
                default:
                    break
                }
            }
        }
        #endif

        NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: .main
        ) { [weak self] _ in
            // 蓝牙耳机插拔导致硬件采样率变化时，引擎会自动停机，按需重连拉起
            MainActor.assumeIsolated {
                guard let self, self.activeOwner != nil, let fmt = self.connectedFormat else { return }
                self.reconnectGraph(format: fmt, force: true)
            }
        }
    }

    func acquire(owner: UUID, format: AVAudioFormat, rate: Float, muted: Bool) throws {
        // 每次新起播/Seek/循环都重置 playerNode 采样计数为 0，使其与 stream.anchorMediaTime 严格对齐
        playerNode.stop()
        activeOwner = owner
        reconnectGraph(format: format, force: false)
        timePitch.rate = max(0.25, min(4.0, rate))
        setMuted(muted, owner: owner)
        try ensureRunning()
    }

    private func reconnectGraph(format: AVAudioFormat, force: Bool) {
        if !force, let cur = connectedFormat,
           cur.sampleRate == format.sampleRate,
           cur.channelCount == format.channelCount {
            return
        }
        let wasRunning = engine.isRunning
        if wasRunning { playerNode.stop() }
        engine.disconnectNodeOutput(playerNode)
        engine.disconnectNodeOutput(timePitch)
        engine.connect(playerNode, to: timePitch, format: format)
        engine.connect(timePitch, to: engine.mainMixerNode, format: format)
        connectedFormat = format
        if wasRunning, !engine.isRunning {
            try? engine.start()
        }
    }

    func ensureRunning() throws {
        #if canImport(UIKit)
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .moviePlayback)
        try? session.setActive(true)
        #endif
        if !engine.isRunning {
            try engine.start()
        }
    }

    func setRate(_ rate: Float, owner: UUID) {
        guard activeOwner == owner else { return }
        timePitch.rate = max(0.25, min(4.0, rate))
    }

    func setMuted(_ muted: Bool, owner: UUID) {
        guard activeOwner == owner else { return }
        isMuted = muted
        engine.mainMixerNode.outputVolume = muted ? 0.0 : 1.0
    }

    /// 当前 owner 显式要求播放。中断仍在进行时不解锁；系统拒绝恢复之后，这一次调用才清掉锁。
    func noteExplicitPlaybackRequest() {
        interruption.explicitPlay()
    }

    func pause(owner: UUID) {
        guard activeOwner == owner else { return }
        if playerNode.isPlaying {
            playerNode.pause()
        }
    }

    /// 全局立即停声（切后台 / 失焦时由 DDPlayback.pauseAll 调用）
    func pauseAll() {
        if playerNode.isPlaying {
            playerNode.pause()
        }
        if engine.isRunning {
            engine.stop()
        }
    }

    func release(owner: UUID) {
        guard activeOwner == owner else { return }
        playerNode.stop()
        activeOwner = nil
        if engine.isRunning {
            engine.stop()
        }
    }

    var hardwareOutputLatency: Double {
        #if canImport(UIKit)
        return AVAudioSession.sharedInstance().outputLatency
        #else
        return engine.outputNode.presentationLatency
        #endif
    }

    /// 已消耗的源音频采样帧数（在 2x 下由 TimePitch 自动按 2 倍速率拉取累加）
    func consumedSourceSeconds(owner: UUID) -> Double? {
        guard activeOwner == owner,
              let fmt = connectedFormat,
              fmt.sampleRate > 0,
              let nodeTime = playerNode.lastRenderTime,
              let playerTime = playerNode.playerTime(forNodeTime: nodeTime) else {
            return nil
        }
        return Double(max(0, playerTime.sampleTime)) / fmt.sampleRate
    }
}

// MARK: - 2. 单条视频的音频流读取与连续 AAC/HE-AAC 解码器（支持在 DYPreloader 中提前预热首秒 PCM）

@MainActor
final class DDAudioStream {
    enum PrepState {
        case idle
        case ready
        case noAudio
        case unsupported
    }

    let asset: AVURLAsset
    private(set) var state: PrepState = .idle
    private(set) var pcmFormat: AVAudioFormat?
    private(set) var anchorMediaTime: Double = 0.0
    private(set) var reachedEOF = false

    private var audioTrack: AVAssetTrack?
    private var generator: AVSampleBufferGenerator?
    private var cursor: AVSampleCursor?
    private var converter: AVAudioConverter?
    private var packetQueue: [CMSampleBuffer] = []
    private var predecoded: [AVAudioPCMBuffer] = []
    private(set) var hasPoppedAny = false
    private var prepTask: Task<PrepState, Never>?
    private(set) var epoch: UInt64 = 0

    init(asset: AVURLAsset) {
        self.asset = asset
    }

    /// - Parameter prewarm: 是否预解码开头 2 块。就地交接马上要 seek 到当前位置，开头那 2 块用不上
    func prepareAndPrewarm(videoItem: AVPlayerItem? = nil, prewarm: Bool = true) async -> PrepState {
        if state != .idle {
            if state == .ready, let videoItem { Self.disableAudioTracks(on: videoItem) }
            return state
        }
        if let existing = prepTask {
            let s = await existing.value
            if s == .ready, let videoItem { Self.disableAudioTracks(on: videoItem) }
            return s
        }
        let task = Task<PrepState, Never> { @MainActor [weak self] in
            guard let self else { return .unsupported }
            return await self.doPrepare(videoItem: videoItem, prewarm: prewarm)
        }
        prepTask = task
        return await task.value
    }

    private func doPrepare(videoItem: AVPlayerItem?, prewarm: Bool) async -> PrepState {
        let startEpoch = epoch
        do {
            let tracks = try await asset.loadTracks(withMediaType: .audio)
            guard !Task.isCancelled, epoch == startEpoch else { return .unsupported }
            guard let aTrack = tracks.first else {
                state = .noAudio
                return .noAudio
            }
            guard try await aTrack.load(.canProvideSampleCursors),
                  let sampleCursor = aTrack.makeSampleCursor(presentationTimeStamp: .zero),
                  let fmtDesc = try await aTrack.load(.formatDescriptions).first else {
                state = .unsupported
                return .unsupported
            }
            guard !Task.isCancelled, epoch == startEpoch else { return .unsupported }

            let srcFormat = AVAudioFormat(cmAudioFormatDescription: fmtDesc)
            // 使用 RichestDecodableFormat 自动识别 HE-AAC v1/v2 的 SBR 48kHz 与 PS 双声道，防止降级成 24kHz 闷声
            let richest = CMAudioFormatDescriptionGetRichestDecodableFormat(fmtDesc)?.pointee.mASBD
            let outSR = (richest?.mSampleRate ?? 0) > 0 ? richest!.mSampleRate : srcFormat.sampleRate
            let rawCh = (richest?.mChannelsPerFrame ?? 0) > 0 ? richest!.mChannelsPerFrame : srcFormat.channelCount
            let outCh = max(1, min(2, rawCh))

            guard outSR > 0,
                  let outFormat = AVAudioFormat(standardFormatWithSampleRate: outSR, channels: outCh),
                  let audioConv = AVAudioConverter(from: srcFormat, to: outFormat) else {
                state = .unsupported
                return .unsupported
            }

            self.audioTrack = aTrack
            self.cursor = sampleCursor
            self.generator = AVSampleBufferGenerator(asset: asset, timebase: nil)
            self.pcmFormat = outFormat
            self.converter = audioConv
            self.anchorMediaTime = max(0, CMTimeGetSeconds(sampleCursor.presentationTimeStamp))
            self.state = .ready

            if let videoItem { Self.disableAudioTracks(on: videoItem) }

            // 预解码开头 2 块（约 1 秒音频，仅 ~16KB 网络请求），滑入时 0ms 瞬时出声
            guard prewarm else { return .ready }
            if let b1 = await decodeNextChunk(expectedEpoch: startEpoch) { predecoded.append(b1) }
            if let b2 = await decodeNextChunk(expectedEpoch: startEpoch) { predecoded.append(b2) }
            return .ready
        } catch {
            state = .unsupported
            return .unsupported
        }
    }

    /// 回退原生声音时要把关掉的音轨重新打开，否则只取消静音也没声
    static func enableAudioTracks(on item: AVPlayerItem) {
        for t in item.tracks where t.assetTrack?.mediaType == .audio && !t.isEnabled { t.isEnabled = true }
    }

    static func disableAudioTracks(on item: AVPlayerItem) {
        for t in item.tracks where t.assetTrack?.mediaType == .audio {
            if t.isEnabled { t.isEnabled = false }
        }
    }

    func seek(to seconds: Double) {
        guard state == .ready, let audioTrack else { return }
        epoch &+= 1
        packetQueue.removeAll()
        predecoded.removeAll()
        hasPoppedAny = false
        converter?.reset()
        reachedEOF = false

        let target = CMTime(seconds: max(0, seconds), preferredTimescale: 60000)
        if let newCursor = audioTrack.makeSampleCursor(presentationTimeStamp: target) {
            let refresh = newCursor.samplesRequiredForDecoderRefresh
            if refresh > 0 {
                _ = newCursor.stepInDecodeOrder(byCount: -Int64(min(refresh, 2)))
            }
            self.cursor = newCursor
            self.anchorMediaTime = max(0, CMTimeGetSeconds(newCursor.presentationTimeStamp))
        }
    }

    func popNextBuffer() async -> AVAudioPCMBuffer? {
        hasPoppedAny = true
        if !predecoded.isEmpty {
            return predecoded.removeFirst()
        }
        return await decodeNextChunk(expectedEpoch: epoch)
    }

    private func decodeNextChunk(expectedEpoch: UInt64) async -> AVAudioPCMBuffer? {
        guard state == .ready,
              epoch == expectedEpoch,
              let generator, let cursor, let converter, let pcmFormat else { return nil }

        if packetQueue.isEmpty && !reachedEOF {
            let batch = generator.makeBatch()
            var fetched: [CMSampleBuffer] = []
            let batchPackets = 22 // AAC-LC 约 0.47s，HE-AAC 约 0.93s
            for _ in 0..<batchPackets {
                let req = AVSampleBufferRequest(start: cursor)
                req.direction = .forward
                req.preferredMinSampleCount = 1
                req.maxSampleCount = 1
                guard let sb = try? generator.makeSampleBuffer(for: req, addTo: batch) else {
                    reachedEOF = true
                    break
                }
                fetched.append(sb)
                if cursor.stepInDecodeOrder(byCount: 1) == 0 {
                    reachedEOF = true
                    break
                }
            }
            if fetched.isEmpty {
                reachedEOF = true
            } else {
                do {
                    try await batch.makeDataReady()
                } catch {
                    return nil
                }
                guard epoch == expectedEpoch else { return nil }
                packetQueue.append(contentsOf: fetched)
            }
        }

        guard !packetQueue.isEmpty else { return nil }

        let srcFormat = converter.inputFormat
        // 兼容 HE-AAC 每包 2048 帧，留足容量避免单次转换截断
        let frameCap = AVAudioFrameCount((packetQueue.count + 4) * 2048)
        guard let pcmBuf = AVAudioPCMBuffer(pcmFormat: pcmFormat, frameCapacity: frameCap) else { return nil }

        let hitEOF = reachedEOF
        var convErr: NSError?
        _ = converter.convert(to: pcmBuf, error: &convErr) { [weak self] _, outStatus in
            guard let self else {
                outStatus.pointee = .noDataNow
                return nil
            }
            while !self.packetQueue.isEmpty {
                let sb = self.packetQueue.removeFirst()
                guard let dataBuf = CMSampleBufferGetDataBuffer(sb) else { continue }
                // 数据缓冲区可能由多段不连续的内存拼成：GetDataPointer 只保证第一段连续。
                // 之前直接按总长度 memcpy，遇到不连续的包就读越界（EXC_BAD_ACCESS，SeamlessAudioPlayer 第 371 行）。
                // 改为先拷成一块连续内存，再喂给解码器。
                let totalLen = CMBlockBufferGetDataLength(dataBuf)
                guard totalLen > 0 else { continue }
                var contiguous = [UInt8](repeating: 0, count: totalLen)
                let copied = contiguous.withUnsafeMutableBytes { raw -> OSStatus in
                    guard let base = raw.baseAddress else { return kCMBlockBufferStructureAllocationFailedErr }
                    return CMBlockBufferCopyDataBytes(dataBuf, atOffset: 0, dataLength: totalLen, destination: base)
                }
                guard copied == kCMBlockBufferNoErr else { continue }

                var descBytes = 0
                CMSampleBufferGetAudioStreamPacketDescriptions(sb, allocatedSize: 0, packetDescriptionsOut: nil,
                                                               packetDescriptionsSizeNeededOut: &descBytes)
                let pktCount = max(1, descBytes / MemoryLayout<AudioStreamPacketDescription>.stride)
                let comp = AVAudioCompressedBuffer(format: srcFormat,
                                                   packetCapacity: AVAudioPacketCount(pktCount),
                                                   maximumPacketSize: totalLen)
                contiguous.withUnsafeBytes { raw in
                    if let base = raw.baseAddress { memcpy(comp.data, base, totalLen) }
                }
                comp.byteLength = UInt32(totalLen)
                if descBytes > 0, let descs = comp.packetDescriptions {
                    CMSampleBufferGetAudioStreamPacketDescriptions(sb, allocatedSize: descBytes,
                                                                   packetDescriptionsOut: descs,
                                                                   packetDescriptionsSizeNeededOut: nil)
                    comp.packetCount = AVAudioPacketCount(pktCount)
                } else {
                    comp.packetDescriptions?.pointee = AudioStreamPacketDescription(
                        mStartOffset: 0, mVariableFramesInPacket: 0, mDataByteSize: UInt32(totalLen)
                    )
                    comp.packetCount = 1
                }
                outStatus.pointee = .haveData
                return comp
            }
            // 分片间必须返回 .noDataNow（而非 .endOfStream），保持 AAC 跨块 MDCT 重叠状态不断裂
            outStatus.pointee = (hitEOF && self.packetQueue.isEmpty) ? .endOfStream : .noDataNow
            return nil
        }

        return pcmBuf.frameLength > 0 ? pcmBuf : nil
    }

    func cancel() {
        epoch &+= 1
        prepTask?.cancel()
        prepTask = nil
        packetQueue.removeAll()
        predecoded.removeAll()
    }
}

// MARK: - 3. 预加载池（供 DYPreloader 预热音频首包，PlayerPage 起播按 AVURLAsset 直接领用）

@MainActor
final class DDAudioPreloadPool {
    static let shared = DDAudioPreloadPool()
    private var byID: [String: DDAudioStream] = [:]
    private var byAsset: [ObjectIdentifier: String] = [:]

    func prewarm(id: String, asset: AVURLAsset, item: AVPlayerItem) {
        // 起播不用引擎，就不预解码音频（省掉滑动时主线程上的解码）
        guard DDSeamlessController.engineWanted, byID[id] == nil else { return }
        let stream = DDAudioStream(asset: asset)
        byID[id] = stream
        byAsset[ObjectIdentifier(asset)] = id
        Task { @MainActor in
            _ = await stream.prepareAndPrewarm(videoItem: item)
        }
    }

    func take(for asset: AVURLAsset) -> DDAudioStream? {
        guard let id = byAsset.removeValue(forKey: ObjectIdentifier(asset)),
              let stream = byID.removeValue(forKey: id) else { return nil }
        return stream
    }

    func discard(id: String) {
        guard let stream = byID.removeValue(forKey: id) else { return }
        byAsset.removeValue(forKey: ObjectIdentifier(stream.asset))
        stream.cancel()
    }

    func clear() {
        for (_, s) in byID { s.cancel() }
        byID.removeAll()
        byAsset.removeAll()
    }
}

// MARK: - 4. 页面级无缝音画同步控制器（供 PlayerPage 持有）

@MainActor
final class DDSeamlessController {
    enum Mode {
        case preparing
        case engaged          // 双管线无缝倍速已接管
        case noAudio          // 纯画面无音轨视频
        case fallbackAVPlayer // 罕见非 MP4 流，回退 AVPlayer 原生音频
    }

    let ownerID = UUID()
    private(set) var mode: Mode = .preparing
    var isEngaged: Bool { mode == .engaged }

    private var stream: DDAudioStream?
    private weak var videoPlayer: AVPlayer?
    private var itemStatusObs: NSKeyValueObservation?
    private var itemTracksObs: NSKeyValueObservation?

    private var feedTask: Task<Void, Never>?
    private var syncTimer: Timer?
    private var bindGen: UInt64 = 0
    private var pendingBuffers = 0
    private let maxBufferedChunks = 8

    private(set) var targetRate: Float = 1.0
    private var wantPlaying = false
    private var isMuted = false
    var onBackgroundEnded: (() -> Void)?

    /// 1x 原生声音下第一次变速（长按 2x、上滑取消、锁定）时，就地把这一条的声音交给独立引擎。
    /// 实测 AVPlayer 带着音轨改速率会冲刷内部音频队列：画面停 50~110ms、声音断一截，长按开始和松手各一次。
    /// 而播放中关掉音轨本身不停画面，之后改速率也不停。所以：引擎先在画面前方对齐起播
    /// （TimePitch 前瞻窗口内还没出声，原生声音照常响），引擎刚出声那一刻关原生音轨、画面切到目标速率。
    /// 之后这一条留在引擎上（松手、再按都是 0ms 切换）；滑走后重新绑定时回到原生声音，不增加平时滑动的开销。
    private var handoffAllowed = false
    private var handoffGen: UInt64 = 0
    private var handoffPending = false
    /// 声音交接要等流准备好；等太久（在线流首包慢）就先按原生方式变速，交接完成后接着无缝
    private let handoffNativeFallbackDelay: Double = 0.35

    /// 起播一律用 AVPlayer 原生声音（任何倍速），只在播放中**改速度**（长按加速、锁定、菜单改速）时
    /// 才就地交给独立引擎（engineHandoff），保住变速不断声不爆音。
    /// 原生声音才有系统空间音频；以前设置里的速度不是 1x 时整条视频都走引擎，倍速看视频就没了空间音频
    /// （议题 #52-1，老板 2026-11-18 定方案 B）。引擎在主线程解码，平时不用它也省了滑动开销。
    /// 交接后这条视频剩下的时间留在引擎上（切回原生会再断一下声），滑到下一条重新用原生声音。
    nonisolated static var engineWanted: Bool { false }

    /// - Parameter engineHandoff: 原生声音时，变速是否允许就地交给独立引擎（画中画要原生声音，不允许）
    func bind(player: AVPlayer, initialPosition: Double?, isActive: Bool, isPlaying: Bool, rate: Float, muted: Bool,
              useEngine: Bool = DDSeamlessController.engineWanted, engineHandoff: Bool = false) {
        reset()
        bindGen &+= 1
        let gen = bindGen

        self.videoPlayer = player
        self.targetRate = max(0.25, rate)
        self.wantPlaying = isActive && isPlaying
        self.isMuted = muted
        self.mode = .preparing
        #if DEBUG
        ddWrite("DDSEAM bind engine=\(useEngine) handoff=\(engineHandoff) rate=\(rate)")
        #endif
        // 原生声音起播（任何倍速）：不建音频流（预热池里若有这条的流也一并丢掉，音轨重新打开）
        if !useEngine {
            mode = .fallbackAVPlayer
            handoffAllowed = engineHandoff
            if let asset = player.currentItem?.asset as? AVURLAsset {
                DDAudioPreloadPool.shared.take(for: asset)?.cancel()
            }
            if let it = player.currentItem { DDAudioStream.enableAudioTracks(on: it) }
            player.isMuted = !wantPlaying || muted
            if wantPlaying { player.rate = targetRate } else { player.pause() }
            return
        }

        // 准备期间先保持 AVPlayer 静音，防止未禁用音轨前漏出原生声音
        player.isMuted = true

        guard let item = player.currentItem,
              let asset = item.asset as? AVURLAsset else {
            mode = .fallbackAVPlayer
            player.isMuted = !isActive || muted
            return
        }

        let audioStream = DDAudioPreloadPool.shared.take(for: asset) ?? DDAudioStream(asset: asset)
        self.stream = audioStream

        // 一旦 item 就绪或 tracks 更新，若已进入 engaged 模式则立即确保原生音频轨关闭
        itemStatusObs = item.observe(\.status, options: [.initial, .new]) { [weak self] it, _ in
            guard it.status == .readyToPlay else { return }
            DispatchQueue.main.async {
                guard let self, self.bindGen == gen, self.mode == .engaged else { return }
                DDAudioStream.disableAudioTracks(on: it)
            }
        }
        itemTracksObs = item.observe(\.tracks, options: [.new]) { [weak self] it, _ in
            DispatchQueue.main.async {
                guard let self, self.bindGen == gen, self.mode == .engaged else { return }
                DDAudioStream.disableAudioTracks(on: it)
            }
        }

        Task { @MainActor [weak self] in
            guard let self else { return }
            let prep = await audioStream.prepareAndPrewarm(videoItem: item)
            guard self.bindGen == gen, let vp = self.videoPlayer else { return }

            switch prep {
            case .ready:
                self.mode = .engaged
                vp.isMuted = true
                if let it = vp.currentItem { DDAudioStream.disableAudioTracks(on: it) }
                let curPos = initialPosition ?? vp.currentTime().seconds
                if curPos.isFinite, curPos > 0.15 {
                    audioStream.seek(to: curPos)
                }
                if self.wantPlaying {
                    self.startEngagedPlayback()
                }
            case .noAudio:
                self.mode = .noAudio
                vp.isMuted = true
                if self.wantPlaying { vp.rate = self.targetRate }
            case .unsupported, .idle:
                self.mode = .fallbackAVPlayer
                if let it = vp.currentItem { DDAudioStream.enableAudioTracks(on: it) }
                vp.isMuted = !self.wantPlaying || self.isMuted
                if self.wantPlaying { vp.rate = self.targetRate }
            }
        }
    }

    func setActive(_ active: Bool, isPlaying: Bool, rate: Float, muted: Bool) {
        targetRate = max(0.25, rate)
        isMuted = muted
        wantPlaying = active && isPlaying

        if !active {
            stopEngineOutput()
            videoPlayer?.isMuted = true
            videoPlayer?.pause()
            // 长按时临时交给引擎的 1x 视频：滑走就还给原生声音，滑回来按 1x 原路起播（流保留，下次长按免准备）
            if engagedByHandoff {
                engagedByHandoff = false
                mode = .fallbackAVPlayer
                itemTracksObs?.invalidate(); itemTracksObs = nil
                if let it = videoPlayer?.currentItem { DDAudioStream.enableAudioTracks(on: it) }
            }
            return
        }

        switch mode {
        case .preparing:
            videoPlayer?.isMuted = true
            if wantPlaying { videoPlayer?.rate = targetRate }
        case .engaged:
            videoPlayer?.isMuted = true
            if let it = videoPlayer?.currentItem { DDAudioStream.disableAudioTracks(on: it) }
            if wantPlaying {
                if let vp = videoPlayer, let stream {
                    let vSec = vp.currentTime().seconds
                    if !stream.hasPoppedAny && vSec < 0.15 {
                        // 直接复用 DYPreloader 预解码好的首秒 PCM，0ms 瞬时起播
                    } else if vSec.isFinite {
                        stream.seek(to: vSec)
                    }
                }
                startEngagedPlayback()
            }
        case .noAudio:
            videoPlayer?.isMuted = true
            if wantPlaying { videoPlayer?.rate = targetRate }
        case .fallbackAVPlayer:
            videoPlayer?.isMuted = muted
            if wantPlaying { videoPlayer?.rate = targetRate }
        }
    }

    /// 长按 2x / 松手恢复 / 菜单切换倍速：0ms 瞬时无损切换
    func setRate(_ newRate: Float) {
        guard newRate > 0 else {
            pause()
            return
        }
        targetRate = newRate
        switch mode {
        case .engaged:
            DDAudioEngineHub.shared.setRate(newRate, owner: ownerID)
            if wantPlaying { videoPlayer?.rate = newRate }
        case .preparing, .noAudio:
            if wantPlaying { videoPlayer?.rate = newRate }
        case .fallbackAVPlayer:
            guard wantPlaying, let vp = videoPlayer else { return }
            if handoffPending {
                // 交接中：完成时按最新的 targetRate 起；已经先按原生方式变过速的，原生继续跟着变
                if handoffNativeFallen, abs(vp.rate - newRate) > 0.001 { vp.softRate(newRate) }
                return
            }
            if vp.rate > 0, abs(vp.rate - newRate) < 0.001 { return }
            if handoffAllowed, vp.rate > 0 { beginEngineHandoff() } else { vp.softRate(newRate) }
        }
    }

    // MARK: 原生声音 → 独立引擎（就地交接，见 handoffAllowed）

    private var handoffNativeFallen = false
    private var engagedByHandoff = false

    /// 作废进行中的交接；交接途中已占用的引擎当场释放（旧任务醒来发现代号变了就直接退出，不再碰引擎）
    private func cancelHandoff() {
        let wasPending = handoffPending
        handoffGen &+= 1
        handoffPending = false
        handoffNativeFallen = false
        if wasPending, mode == .fallbackAVPlayer, DDAudioEngineHub.shared.activeOwner == ownerID {
            syncTimer?.invalidate(); syncTimer = nil
            pendingBuffers = 0
            DDAudioEngineHub.shared.release(owner: ownerID)
        }
    }

    /// 变速时交给引擎的这一条，就地把声音还给 AVPlayer 原生音轨（离开 App 前调用：系统画中画只认原生声音）。
    /// 引擎停、原生音轨开、按当前目标速率继续；之后在前台再变速还会重新交给引擎。
    /// - Returns: 真的从引擎（或进行中的交接）切回来了才返回 true
    @discardableResult
    func returnToNativeAudio(reason: String) -> Bool {
        guard mode == .fallbackAVPlayer || (mode == .engaged && engagedByHandoff) else { return false }
        let wasPending = handoffPending
        let wasEngaged = mode == .engaged
        guard wasPending || wasEngaged else { return false }
        let heard = currentMediaTime
        if wasPending { cancelHandoff() }
        if wasEngaged {
            stopEngineOutput()
            engagedByHandoff = false
            mode = .fallbackAVPlayer
            itemTracksObs?.invalidate(); itemTracksObs = nil
        }
        guard let vp = videoPlayer else { return true }
        if let it = vp.currentItem { DDAudioStream.enableAudioTracks(on: it) }
        vp.isMuted = isMuted
        if wantPlaying, abs(vp.rate - targetRate) > 0.001 { vp.rate = targetRate }
        DYLiveModel.log("DDSEAM back-to-native reason=\(reason) engaged=\(wasEngaged) pending=\(wasPending) rate=\(targetRate) v=\(String(format: "%.2f", vp.currentTime().seconds)) a=\(heard.map { String(format: "%.2f", $0) } ?? "-")")
        return true
    }

    private func beginEngineHandoff() {
        guard let vp = videoPlayer, let item = vp.currentItem, let asset = item.asset as? AVURLAsset else {
            handoffAllowed = false
            videoPlayer?.softRate(targetRate)
            return
        }
        cancelHandoff()
        handoffPending = true
        let hGen = handoffGen, gen = bindGen
        let audioStream = stream ?? DDAudioPreloadPool.shared.take(for: asset) ?? DDAudioStream(asset: asset)
        stream = audioStream
        let started = CACurrentMediaTime()

        DispatchQueue.main.asyncAfter(deadline: .now() + handoffNativeFallbackDelay) { [weak self] in
            guard let self, self.handoffGen == hGen, self.handoffPending, self.wantPlaying,
                  let vp = self.videoPlayer else { return }
            self.handoffNativeFallen = true
            DYLiveModel.log("DDSEAM handoff slow → native rate \(self.targetRate)")
            if abs(vp.rate - self.targetRate) > 0.001 { vp.softRate(self.targetRate) }
        }

        feedTask?.cancel()
        feedTask = Task { @MainActor [weak self] in
            // 不传 videoItem：准备好时不能马上关原生音轨，要等引擎出声那一刻
            let prep = await audioStream.prepareAndPrewarm(prewarm: false)
            guard let self, self.handoffGen == hGen, self.bindGen == gen, self.mode == .fallbackAVPlayer else { return }
            guard prep == .ready, let fmt = audioStream.pcmFormat else {
                // 无音轨 / 格式不支持：这一条以后都按原生方式变速
                DYLiveModel.log("DDSEAM handoff unavailable prep=\(prep)")
                self.handoffAllowed = false
                self.abortHandoff(hGen)
                return
            }
            await self.completeEngineHandoff(stream: audioStream, format: fmt, hGen: hGen, gen: gen, started: started)
        }
    }

    /// 交接失败：释放引擎，原生声音按当前目标速率继续。已被别处作废（暂停 / 滑走 / 重新绑定）的旧交接什么都不做。
    private func abortHandoff(_ hGen: UInt64) {
        guard handoffGen == hGen, handoffPending else { return }
        cancelHandoff()
        if wantPlaying, let vp = videoPlayer, abs(vp.rate - targetRate) > 0.001 { vp.softRate(targetRate) }
    }

    private func completeEngineHandoff(stream: DDAudioStream, format: AVAudioFormat,
                                       hGen: UInt64, gen: UInt64, started: CFTimeInterval) async {
        let hub = DDAudioEngineHub.shared
        func live() -> Bool {
            handoffGen == hGen && bindGen == gen && wantPlaying && mode == .fallbackAVPlayer && videoPlayer != nil
        }
        guard live(), hub.allowsAutomaticStart, let vp = videoPlayer else { abortHandoff(hGen); return }
        pendingBuffers = 0
        // 出声前引擎按画面当前速率走（和原生声音同速），切换那一刻两边一起换到目标速率
        let nativeRate = Double(max(vp.rate, 0.25))
        do {
            try hub.acquire(owner: ownerID, format: format, rate: Float(nativeRate), muted: isMuted)
        } catch {
            handoffAllowed = false
            abortHandoff(hGen)
            return
        }
        // 引擎从 play() 到真正出声隔着 TimePitch 前瞻窗口；再留一点给解码首块。
        // 从画面「那时会走到的位置」开始解码，原生声音在此期间照常响。
        let lead = max(0.02, min(0.12, hub.timePitch.latency))
        stream.seek(to: vp.currentTime().seconds + (lead + 0.05) * nativeRate)
        let epoch = stream.epoch
        // 一块约 0.5~0.9 秒声音，够撑到切换后喂包循环接上
        await enqueueOneChunk(gen: gen, streamEpoch: epoch)
        guard live(), pendingBuffers > 0, hub.activeOwner == ownerID else { abortHandoff(hGen); return }

        // 等画面走到「引擎出声时正好对上」的那一刻再 play
        let wait = (stream.anchorMediaTime - vp.currentTime().seconds) / nativeRate - lead
        if wait > 0 { try? await Task.sleep(nanoseconds: UInt64(min(wait, 0.5) * 1_000_000_000)) }
        guard live(), hub.activeOwner == ownerID else { abortHandoff(hGen); return }
        try? hub.ensureRunning()
        hub.playerNode.play()
        try? await Task.sleep(nanoseconds: UInt64(lead * 1_000_000_000))
        guard live(), hub.activeOwner == ownerID else { abortHandoff(hGen); return }

        // 引擎此刻出声：关原生音轨、画面切到目标速率——两步都不冲刷画面
        guard let vpNow = videoPlayer, let item = vpNow.currentItem else { abortHandoff(hGen); return }
        DDAudioStream.disableAudioTracks(on: item)
        vpNow.isMuted = true
        hub.setRate(targetRate, owner: ownerID)   // 交接途中可能已经松手 / 改速
        hub.setMuted(isMuted, owner: ownerID)
        vpNow.rate = targetRate
        mode = .engaged
        engagedByHandoff = true
        handoffPending = false
        handoffNativeFallen = false
        itemTracksObs = item.observe(\.tracks, options: [.new]) { [weak self] it, _ in
            DispatchQueue.main.async {
                guard let self, self.bindGen == gen, self.mode == .engaged else { return }
                DDAudioStream.disableAudioTracks(on: it)
            }
        }
        let drift = vpNow.currentTime().seconds - (currentMediaTime ?? .nan)
        DYLiveModel.log("DDSEAM handoff done in \(Int((CACurrentMediaTime() - started) * 1000))ms rate=\(targetRate) wait=\(Int(wait * 1000))ms drift=\(Int(drift * 1000))ms")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            guard let self, self.mode == .engaged, let vp = self.videoPlayer, let a = self.currentMediaTime else { return }
            DYLiveModel.log("DDSEAM handoff +1s drift=\(Int((vp.currentTime().seconds - a) * 1000))ms rate=\(vp.rate)")
        }
        startSyncLoop()
        await feedLoop(stream: stream, gen: gen, streamEpoch: epoch)
    }

    private func feedLoop(stream: DDAudioStream, gen: UInt64, streamEpoch: UInt64) async {
        while !Task.isCancelled && bindGen == gen && stream.epoch == streamEpoch {
            if pendingBuffers < maxBufferedChunks && !stream.reachedEOF {
                await enqueueOneChunk(gen: gen, streamEpoch: streamEpoch)
            } else {
                try? await Task.sleep(nanoseconds: 40_000_000)
            }
        }
    }

    func setMuted(_ muted: Bool) {
        isMuted = muted
        switch mode {
        case .engaged:
            videoPlayer?.isMuted = true
            DDAudioEngineHub.shared.setMuted(muted, owner: ownerID)
        case .preparing, .noAudio:
            videoPlayer?.isMuted = true
        case .fallbackAVPlayer:
            videoPlayer?.isMuted = muted
        }
    }

    func play(rate: Float, muted: Bool) {
        targetRate = max(0.25, rate)
        isMuted = muted
        wantPlaying = true

        switch mode {
        case .engaged:
            videoPlayer?.isMuted = true
            let hub = DDAudioEngineHub.shared
            if hub.activeOwner == ownerID {
                hub.noteExplicitPlaybackRequest()
            }
            if hub.activeOwner == ownerID, pendingBuffers > 0, hub.allowsAutomaticStart {
                try? hub.ensureRunning()
                hub.setRate(targetRate, owner: ownerID)
                hub.setMuted(muted, owner: ownerID)
                if shouldPlayAudioNow() { hub.playerNode.play() }
                videoPlayer?.rate = targetRate
                startSyncLoop()
            } else {
                if let vSec = videoPlayer?.currentTime().seconds, vSec.isFinite {
                    stream?.seek(to: vSec)
                }
                startEngagedPlayback()
            }
        case .preparing, .noAudio:
            videoPlayer?.isMuted = true
            videoPlayer?.rate = targetRate
        case .fallbackAVPlayer:
            videoPlayer?.isMuted = muted
            videoPlayer?.rate = targetRate
        }
    }

    func pause() {
        wantPlaying = false
        cancelHandoff()
        syncTimer?.invalidate()
        DDAudioEngineHub.shared.pause(owner: ownerID)
        videoPlayer?.pause()
    }

    /// 拖动进度条前先停旧音频，等视频关键帧 seek 落稳后再从精确落点起播
    func prepareForSeek() {
        guard mode == .engaged else { return }
        feedTask?.cancel()
        if DDAudioEngineHub.shared.activeOwner == ownerID {
            DDAudioEngineHub.shared.playerNode.stop()
        }
        pendingBuffers = 0
    }

    func didFinishVideoSeek(landedSeconds: Double, resumePlaying: Bool, rate: Float, muted: Bool) {
        targetRate = max(0.25, rate)
        isMuted = muted
        wantPlaying = resumePlaying
        guard mode == .engaged, let stream else { return }
        stream.seek(to: landedSeconds)
        if wantPlaying {
            startEngagedPlayback()
        }
    }

    func loopToZero(rate: Float, muted: Bool) {
        didFinishVideoSeek(landedSeconds: 0, resumePlaying: true, rate: rate, muted: muted)
    }

    /// 从后台回前台时对齐画面到音频主时钟（支持「后台听书」期间音频已往前走的情况）
    func syncAfterForeground(rate: Float, muted: Bool) {
        targetRate = max(0.25, rate)
        isMuted = muted
        guard mode == .engaged, let vp = videoPlayer else { return }
        if DDPlayback.bgPlay, wantPlaying, let aSec = currentMediaTime {
            vp.seek(to: CMTime(seconds: aSec, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
                DispatchQueue.main.async {
                    guard let self, self.wantPlaying else { return }
                    vp.rate = self.targetRate
                }
            }
        } else if wantPlaying {
            play(rate: targetRate, muted: muted)
        }
    }

    var currentMediaTime: Double? {
        guard mode == .engaged,
              let stream,
              let consumed = DDAudioEngineHub.shared.consumedSourceSeconds(owner: ownerID) else {
            return nil
        }
        let hub = DDAudioEngineHub.shared
        let heard = stream.anchorMediaTime + consumed - hub.timePitch.latency - hub.hardwareOutputLatency * Double(targetRate)
        return max(0, heard)
    }

    private func startEngagedPlayback() {
        guard mode == .engaged,
              let stream,
              let fmt = stream.pcmFormat,
              let vp = videoPlayer else { return }

        feedTask?.cancel()
        pendingBuffers = 0
        let gen = bindGen
        let streamEpoch = stream.epoch

        do {
            try DDAudioEngineHub.shared.acquire(owner: ownerID, format: fmt, rate: targetRate, muted: isMuted)
        } catch {
            // 极端情况下引擎启动失败则安全回退原生音频
            mode = .fallbackAVPlayer
            if let it = vp.currentItem { DDAudioStream.enableAudioTracks(on: it) }
            vp.isMuted = isMuted
            if wantPlaying { vp.rate = targetRate }
            return
        }

        vp.isMuted = true
        let likelyReady = vp.currentItem?.isPlaybackLikelyToKeepUp == true
        if wantPlaying {
            if likelyReady { vp.pause() } else { vp.rate = targetRate }
        }

        feedTask = Task { @MainActor [weak self] in
            guard let self else { return }
            // 先塞入开头 2 块再启动 playerNode
            await self.enqueueOneChunk(gen: gen, streamEpoch: streamEpoch)
            await self.enqueueOneChunk(gen: gen, streamEpoch: streamEpoch)
            guard self.bindGen == gen, self.wantPlaying,
                  DDAudioEngineHub.shared.activeOwner == self.ownerID else { return }
            if self.shouldPlayAudioNow(), DDAudioEngineHub.shared.allowsAutomaticStart {
                try? DDAudioEngineHub.shared.ensureRunning()
                DDAudioEngineHub.shared.playerNode.play()
                // 已缓冲就绪时等 TimePitch 前瞻窗口（~85ms）出声同刻再推进画面，消除起播 ~85ms 超前
                if likelyReady {
                    let delayNs = UInt64(max(0, min(0.10, DDAudioEngineHub.shared.timePitch.latency)) * 1_000_000_000)
                    if delayNs > 0 { try? await Task.sleep(nanoseconds: delayNs) }
                }
            }
            guard self.bindGen == gen, self.wantPlaying else { return }
            self.videoPlayer?.rate = self.targetRate
            self.startSyncLoop()
            await self.feedLoop(stream: stream, gen: gen, streamEpoch: streamEpoch)
        }
    }

    private func enqueueOneChunk(gen: UInt64, streamEpoch: UInt64) async {
        guard bindGen == gen, let stream, stream.epoch == streamEpoch else { return }
        guard let buf = await stream.popNextBuffer(),
              bindGen == gen,
              stream.epoch == streamEpoch,
              DDAudioEngineHub.shared.activeOwner == ownerID else { return }

        pendingBuffers += 1
        DDAudioEngineHub.shared.playerNode.scheduleBuffer(buf) { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, self.bindGen == gen, self.stream?.epoch == streamEpoch else { return }
                self.pendingBuffers = max(0, self.pendingBuffers - 1)
            }
        }
    }

    private func shouldPlayAudioNow() -> Bool {
        guard wantPlaying else { return false }
        // 后台听书模式下视频 AVPlayer 会停，音频独立持续播
        if DDPlayback.bgPlay && UIApplication.shared.applicationState == .background { return true }
        guard let vp = videoPlayer else { return false }
        return vp.timeControlStatus == .playing || (vp.currentItem?.isPlaybackLikelyToKeepUp == true)
    }

    private func startSyncLoop() {
        syncTimer?.invalidate()
        syncTimer = Timer.scheduledTimer(withTimeInterval: 0.18, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.syncTick()
            }
        }
    }

    private func syncTick() {
        guard mode == .engaged, wantPlaying, let stream else { return }
        let hub = DDAudioEngineHub.shared
        guard hub.activeOwner == ownerID else { return }
        guard hub.allowsAutomaticStart else { return }

        // 后台听书模式：处理后台播完单曲循环或切下一首
        if DDPlayback.bgPlay && UIApplication.shared.applicationState == .background {
            if !hub.playerNode.isPlaying && pendingBuffers > 0 {
                try? hub.ensureRunning()
                hub.playerNode.play()
            } else if stream.reachedEOF && pendingBuffers == 0 {
                onBackgroundEnded?()
            }
            return
        }

        guard let vp = videoPlayer else { return }

        // 前台弱网卡顿时：视频在缓冲等待则暂停音频，视频恢复立即同步接着响
        if vp.timeControlStatus == .waitingToPlayAtSpecifiedRate {
            if hub.playerNode.isPlaying { hub.playerNode.pause() }
            return
        }
        if !hub.playerNode.isPlaying && pendingBuffers > 0 {
            try? hub.ensureRunning()
            hub.playerNode.play()
        }

        guard hub.playerNode.isPlaying, let audioSec = currentMediaTime else { return }
        let videoSec = vp.currentTime().seconds
        guard videoSec.isFinite else { return }
        let drift = videoSec - audioSec // >0 画面快于声音

        // 画面速率保持不动：每 0.18s 改一次 AVPlayer 速率会让画面掉帧（抽帧感）。
        // 改成声音跟画面：TimePitch 速率在 ±3% 内微调，耳朵听不出来
        if abs(vp.rate - targetRate) > 0.002 { vp.rate = targetRate }
        if abs(drift) > 0.5 {
            // 偏太多（弱网卡顿恢复等）：把声音重新定位到画面所在位置
            prepareForSeek()
            didFinishVideoSeek(landedSeconds: videoSec, resumePlaying: true, rate: targetRate, muted: isMuted)
            return
        }
        let nudge = abs(drift) > 0.03 ? Float(max(-0.03, min(0.03, drift * 0.5))) : 0
        hub.setRate(targetRate * (1 + nudge), owner: ownerID)
    }

    private func stopEngineOutput() {
        cancelHandoff()
        feedTask?.cancel()
        feedTask = nil
        syncTimer?.invalidate()
        syncTimer = nil
        pendingBuffers = 0
        DDAudioEngineHub.shared.release(owner: ownerID)
    }

    func reset() {
        bindGen &+= 1
        wantPlaying = false
        stopEngineOutput()
        itemStatusObs?.invalidate(); itemStatusObs = nil
        itemTracksObs?.invalidate(); itemTracksObs = nil
        // 交接给引擎的 1x 视频把原生音轨关了：交还播放器前重新打开
        if engagedByHandoff, let it = videoPlayer?.currentItem { DDAudioStream.enableAudioTracks(on: it) }
        engagedByHandoff = false
        handoffAllowed = false
        stream?.cancel()
        stream = nil
        videoPlayer = nil
        mode = .preparing
    }
}
