import SwiftUI
import Combine
import AVFoundation

struct DYLiveStream: Hashable {
    let url: URL
    let quality: String
    let isFLV: Bool
    var cacheMS: Int32 { isFLV ? 800 : 1500 }
}

extension DYLiveRoom {
    /// 优先连续 HTTP-FLV，避免 HLS 播放列表/分片等待；同画质 HLS 保留为兜底。
    var liveStreams: [DYLiveStream] {
        let flv = flv ?? [:]
        let keys = ["HD1", def ?? "", "FULL_HD1", "SD1", "SD2"] + Array(Set(hls.keys).union(flv.keys)).sorted()
        var seen = Set<URL>()
        var result: [DYLiveStream] = []
        #if DEBUG
        let hlsOnly = ProcessInfo.processInfo.environment["DOUDUO_LIVE_HLS"] == "1"
        #else
        let hlsOnly = false
        #endif
        for key in keys where !key.isEmpty {
            for isFLV in [true, false] where !(hlsOnly && isFLV) {
                guard let value = (isFLV ? flv : hls)[key], let url = URL(string: value),
                      ["http", "https"].contains(url.scheme?.lowercased() ?? ""), seen.insert(url).inserted else { continue }
                result.append(DYLiveStream(url: url, quality: key, isFLV: isFLV))
            }
        }
        return result
    }
}

@MainActor
final class DYLiveModel: ObservableObject {
    @Published var rooms: [DYLiveRoom] = []
    @Published var currentID: String?
    @Published var error: String?
    @Published var playbackError: String?
    @Published var loading = false
    private(set) var fetchedAt = Date.distantPast
    @Published var ready = false
    @Published var zone: DYLiveZone?
    @Published var clean = false
    @Published var entered = false
    @Published var muted = false { didSet { vlc.mediaPlayer.audio?.isMuted = muted } }
    let vlc = VLCPlayerController()
    private var requestGeneration = UUID()
    private var loadedRoom: String?
    private var roomRef: DYLiveRoom?
    private var sources: [DYLiveStream] = []
    private var retryTask: Task<Void, Never>?
    private var startedAt = ProcessInfo.processInfo.systemUptime
    private var streamGeneration = UUID()
    private let lifecycleID = UUID()
    private var visible = false

    func activate() {
        visible = true
        DDPlayback.shared.register(lifecycleID, stop: { [weak self] in self?.stop() }, start: { [weak self] in
            guard let self, self.visible else { return }
            self.play(self.roomRef)
        })
        play(roomRef)
    }
    func deactivate() {
        visible = false
        DDPlayback.shared.unregister(lifecycleID)
        stop()
    }

    /// 后台串行队列写（DDLogWriter）：不在主线程开关文件、不每条新建 DateFormatter；超 2MB 截半
    nonisolated static func log(_ s: String) {
        let now = Date()
        DDLogWriter.queue.async { DDLogWriter.write(now, s) }
    }

    init() {
        vlc.onProgress = { [weak self] time in
            guard let self, !self.ready, self.loadedRoom != nil, time > 0,
                  self.vlc.mediaPlayer.hasVideoOut else { return }
            self.ready = true
            self.retryTask?.cancel()
            Self.log("DDLIVE_READY room=\(self.loadedRoom ?? "-") elapsed=\(String(format: "%.3f", ProcessInfo.processInfo.systemUptime - self.startedAt)) videoOut=true")
        }
        vlc.onError = { [weak self] in self?.tryNextSource(reason: "decoder/network error") }
        vlc.onEnd = { [weak self] in self?.playbackError = "直播已结束或连接中断，可重试或上滑换台" }
    }

    func load(_ bridge: DouyinBridge, reset: Bool = false) async {
        guard !loading else { return }
        let generation = requestGeneration, requestedZone = zone
        let start = ProcessInfo.processInfo.systemUptime
        loading = true
        defer { if requestGeneration == generation { loading = false } }
        do {
            let r = try await bridge.fetchLive(reset: reset, zone: requestedZone)
            guard requestGeneration == generation, zone == requestedZone else { return }
            if reset { rooms = [] }
            var seen = Set(rooms.map(\.id))
            rooms.append(contentsOf: r.filter { seen.insert($0.id).inserted })
            if !rooms.contains(where: { $0.id == currentID }) { currentID = rooms.first?.id }
            fetchedAt = Date()
            error = rooms.isEmpty ? (zone == nil ? "暂时没有直播" : "这个分类暂时没有直播") : nil
            Self.log("DDLIVE_FEED count=\(r.count) elapsed=\(String(format: "%.3f", ProcessInfo.processInfo.systemUptime - start))")
        } catch {
            guard requestGeneration == generation else { return }
            if rooms.isEmpty { self.error = error.localizedDescription }
        }
    }

    func play(_ room: DYLiveRoom?) {
        guard let room else { return }
        if loadedRoom == room.id, vlc.mediaPlayer.media != nil { return }
        roomRef = room
        guard visible, DDPlayback.shared.appIsActive else { return }
        loadedRoom = room.id
        sources = room.liveStreams
        startCurrentSource()
    }

    private func startCurrentSource() {
        retryTask?.cancel()
        streamGeneration = UUID()
        let generation = streamGeneration
        ready = false; playbackError = nil
        vlc.stop()
        guard let source = sources.first else {
            playbackError = "没有可用直播线路，请重试或换一个直播间"; return
        }
        startedAt = ProcessInfo.processInfo.systemUptime
        vlc.play(url: source.url, headers: DYMedia.liveHeaders, cachingMs: source.cacheMS)
        vlc.mediaPlayer.audio?.isMuted = muted
        Self.log("DDLIVEPLAY room=\(loadedRoom ?? "-") protocol=\(source.isFLV ? "FLV" : "HLS") q=\(source.quality) cache=\(source.cacheMS) drawable=\(vlc.mediaPlayer.drawable != nil)")
        retryTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(source.isFLV ? 6 : 10)) } catch { return }
            guard let self, self.streamGeneration == generation, !self.ready else { return }
            self.tryNextSource(reason: "startup timeout")
        }
    }

    private func tryNextSource(reason: String) {
        guard loadedRoom != nil else { return }
        retryTask?.cancel()
        Self.log("DDLIVE_FALLBACK reason=\(reason) remaining=\(sources.count)")
        if !sources.isEmpty { sources.removeFirst() }
        guard !sources.isEmpty else {
            playbackError = "直播连接失败，请重试或上滑换台"; vlc.stop(); return
        }
        startCurrentSource()
    }

    func retry() {
        guard let room = roomRef else { return }
        loadedRoom = nil; play(room)
    }
    func enterRoom() {
        entered = true; clean = false
        Self.log("DDLIVE_ENTER room=\(currentID ?? "-") reused=true")
    }
    func leaveRoom() {
        entered = false; clean = false
        Self.log("DDLIVE_LEAVE room=\(currentID ?? "-") reused=true")
    }
    func stop() {
        retryTask?.cancel(); streamGeneration = UUID()
        loadedRoom = nil; vlc.stop(); ready = false
    }
    func reset() {
        requestGeneration = UUID(); loading = false
        stop(); rooms = []; currentID = nil; error = nil; playbackError = nil
        entered = false; clean = false
    }
    func select(_ z: DYLiveZone?, _ bridge: DouyinBridge) {
        guard z != zone else { return }
        zone = z; reset()
        Task { await load(bridge, reset: true) }
    }
    func open(_ room: DYLiveRoom) {
        zone = nil; reset(); rooms = [room]; currentID = room.id; entered = true; fetchedAt = Date()
    }
}

/// 预览和直播间共用同一个 drawable / VLC，不用网页开第二套播放器。
struct DYLiveFeed: View {
    @Environment(\.appTheme) private var theme
    @Environment(\.colorScheme) private var scheme
    @Environment(\.horizontalSizeClass) private var hSize
    let bridge: DouyinBridge
    @ObservedObject var model: DYLiveModel
    let onWeb: (URL) -> Void
    var active = true
    /// ⚠️ 不直接 @StateObject DYLiveChat：热门直播间每秒都有新弹幕，会让整页（ScrollView + VLC 渲染层）跟着重算 → 卡。
    /// 包一层不发通知的盒子，只让聊天浮层自己订阅
    @StateObject private var chatBox = DYLiveChatBox()
    private var chat: DYLiveChat { chatBox.chat }
    @State private var draft = ""
    @State private var sending = false
    @State private var sendError: String?
    @State private var showCategories = false
    @State private var scrollID: String?
    @State private var userScrolling = false
    @State private var gestureStartID: String?
    @State private var scrollEndTask: Task<Void, Never>?
    @FocusState private var inputFocused: Bool
    @AppStorage("douyin_danmaku_v1") private var danmakuOn = true
    #if DEBUG
    @State private var tick = 0   // 只给调试锚点刷新用；Release 每 0.5s 整页重算会卡
    #endif
    private var foreground: Color { theme.media.onMedia.color(for: scheme) }
    private var currentRoom: DYLiveRoom? { model.rooms.first { $0.id == model.currentID } }
    private var chatRoom: String? { model.entered && model.ready && danmakuOn ? currentRoom?.webRid : nil }

    var body: some View {
        GeometryReader { geo in
            ZStack {
                VLCPlayerSurface(controller: model.vlc, fillWidth: currentRoom?.portrait == true && geo.size.height > geo.size.width * 1.2)
                    .frame(width: geo.size.width, height: geo.size.height)
                    .allowsHitTesting(false)
                if model.rooms.isEmpty { emptyState }
                else { pages }
                if !model.entered {
                    VStack {
                        HStack { categoryButton; Spacer() }
                        Spacer()
                    }
                    .padding(.horizontal, 18)
                    .padding(.top, hSize == .compact ? 46 : 74)
                }
                #if DEBUG
                VStack {
                    Text(model.currentID ?? "-").accessibilityIdentifier("live.currentID")
                    Text(String(format: "%.1f", model.vlc.current)).accessibilityIdentifier("live.time")
                    Text(model.ready ? "1" : "0").accessibilityIdentifier("live.status")
                }.font(.caption2).opacity(0.01).allowsHitTesting(false)
                #endif
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .clipped()
        }
        // 分页与 drawable 使用同一整屏视口，不能只让 ScrollView 越过底部安全区。
        .ignoresSafeArea(.container, edges: .bottom)
        .background(DYLiveChatHost(chat: chat).frame(width: 1, height: 1).allowsHitTesting(false))
        .onAppear { if active { model.activate() } }
        .onChange(of: active) { _, value in
            if value { model.activate() } else { model.deactivate() }
        }
        .task {
            if model.rooms.isEmpty || Date().timeIntervalSince(model.fetchedAt) > 60 {
                await model.load(bridge, reset: true)
            }
            scrollID = model.currentID
            model.play(currentRoom)
        }
        .onChange(of: model.currentID) { _, id in
            if let id, scrollID != id { scrollID = id }
            draft = ""; sendError = nil; inputFocused = false
            model.play(currentRoom)
            if let id, let i = model.rooms.firstIndex(where: { $0.id == id }), i >= model.rooms.count - 3 {
                Task { await model.load(bridge) }
            }
        }
        .task(id: chatRoom) {
            chat.close()
            guard let id = chatRoom else { return }
            // 首帧后再接评论网页，避免它的 JS/资源请求抢首播带宽和主线程。
            do { try await Task.sleep(for: .milliseconds(500)) } catch { return }
            guard !Task.isCancelled, id == chatRoom else { return }
            chat.open(id)
        }
        .onChange(of: model.entered) { _, entered in
            if !entered { inputFocused = false; draft = ""; sendError = nil }
        }
        .onDisappear { scrollEndTask?.cancel(); model.deactivate(); chat.close() }
        #if DEBUG
        .onReceive(Timer.publish(every: 0.5, on: .main, in: .common).autoconnect()) { _ in tick += 1 }
        #endif
        .sheet(isPresented: $showCategories) {
            DYLiveCategories(selection: model.zone) { z in
                showCategories = false; model.select(z, bridge)
            }
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
        }
    }

    private var categoryButton: some View {
        Button { showCategories = true } label: {
            Label(model.zone?.name ?? "分类", systemImage: "line.3.horizontal.decrease")
                .font(.subheadline.weight(.medium))
                .padding(.horizontal, 14).frame(height: 40).ddGlassCapsule()
        }
        .foregroundStyle(foreground).buttonStyle(.plain)
        .accessibilityIdentifier("live.categories")
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            if let error = model.error {
                Text(error).font(.footnote)
                Button("重试") { Task { await model.load(bridge, reset: true) } }
                Button("网页版 / 登录") { onWeb(URL(string: "https://live.douyin.com/")!) }
            } else {
                ProgressView().tint(foreground)
                Text("连接直播…").font(.footnote)
            }
        }.foregroundStyle(foreground).frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var pages: some View {
        ScrollView(.vertical) {
            LazyVStack(spacing: 0) {
                ForEach(model.rooms) { room in
                    DYLiveRoomPage(room: room, model: model, isCurrent: model.currentID == room.id,
                                   chat: model.currentID == room.id ? chat : nil,
                                   input: AnyView(commentInput), onWeb: onWeb)
                        .containerRelativeFrame([.horizontal, .vertical])
                        .contentShape(Rectangle())
                        .accessibilityHidden(model.currentID != room.id)
                        .id(room.id)
                }
            }.scrollTargetLayout()
        }
        .scrollTargetBehavior(.paging)
        .scrollPosition(id: $scrollID)
        .scrollIndicators(.hidden)
        .scrollDismissesKeyboard(.interactively)
        .ignoresSafeArea(.container, edges: .bottom)
        .simultaneousGesture(DragGesture(minimumDistance: 12)
            .onChanged { value in
                guard abs(value.translation.height) > abs(value.translation.width) else { return }
                if !userScrolling { gestureStartID = model.currentID }
                scrollEndTask?.cancel(); userScrolling = true
            }
            .onEnded { value in
                if abs(value.translation.width) > 80 && abs(value.translation.width) > abs(value.translation.height) && model.entered {
                    withAnimation(.easeInOut(duration: 0.2)) { model.clean = value.translation.width > 0 }
                }
                scrollEndTask = Task {
                    try? await Task.sleep(for: .milliseconds(600))
                    guard !Task.isCancelled else { return }
                    userScrolling = false; gestureStartID = nil
                }
            })
        .onChange(of: scrollID) { _, id in
            guard let id, id != model.currentID else { return }
            // 仅接受真实竖滑引起的相邻页变化，布局/追加列表不得偷偷切台。
            let start = gestureStartID ?? model.currentID
            if userScrolling, let a = model.rooms.firstIndex(where: { $0.id == id }),
               let b = model.rooms.firstIndex(where: { $0.id == start }), abs(a - b) <= 1 {
                model.currentID = id
            } else { scrollID = model.currentID }
        }
    }

    private var commentInput: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let sendError { Text(sendError).font(.caption).foregroundStyle(theme.status.warning.color(for: scheme)) }
            HStack(spacing: 8) {
                TextField("说点什么…", text: $draft)
                    .font(.subheadline).foregroundStyle(foreground).focused($inputFocused)
                    .submitLabel(.send).onSubmit(sendComment)
                    .padding(.horizontal, 14).frame(height: 40).ddGlassCapsule()
                    .accessibilityIdentifier("live.chat.input")
                if !draft.isEmpty {
                    Button(action: sendComment) {
                        if sending { ProgressView() } else { Text("发送").font(.subheadline.weight(.semibold)) }
                    }.disabled(sending).accessibilityIdentifier("live.chat.send")
                }
            }
        }
    }

    private func sendComment() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !sending else { return }
        guard chatRoom != nil else { sendError = "评论区连接中，稍后再试"; return }
        sending = true
        Task {
            if let error = await chat.send(text) { sendError = error }
            else { draft = ""; sendError = nil; inputFocused = false }
            sending = false
        }
    }
}

private struct DYLiveRoomPage: View {
    @Environment(\.appTheme) private var theme
    @Environment(\.colorScheme) private var scheme
    @Environment(\.horizontalSizeClass) private var hSize
    let room: DYLiveRoom
    @ObservedObject var model: DYLiveModel
    let isCurrent: Bool
    /// 只有当前房间传；浮层自己订阅新消息，不让整页重算
    let chat: DYLiveChat?
    let input: AnyView
    let onWeb: (URL) -> Void
    private var foreground: Color { theme.media.onMedia.color(for: scheme) }

    var body: some View {
        GeometryReader { geo in
            ZStack {
                if !isCurrent || !model.ready, let cover = room.cover, let url = URL(string: cover) {
                    CachedAsyncImage(url: url) { $0.resizable().aspectRatio(contentMode: room.portrait ? .fill : .fit) }
                        placeholder: { Color.clear }
                        .frame(width: geo.size.width, height: geo.size.height).clipped()
                }
                if isCurrent && !model.entered {
                    Color.clear.contentShape(Rectangle()).onTapGesture { model.enterRoom() }
                }
                if isCurrent, !model.ready || model.playbackError != nil {
                    VStack(spacing: 10) {
                        if let error = model.playbackError {
                            Text(error).font(.footnote).multilineTextAlignment(.center)
                            Button("重试", action: model.retry).buttonStyle(.bordered)
                        } else {
                            ProgressView().tint(foreground)
                            Text("连接直播…").font(.caption)
                        }
                    }.foregroundStyle(foreground).frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                if !isCurrent {
                    Color.clear.allowsHitTesting(false)
                } else if model.clean {
                    VStack { HStack { Spacer(); circle("arrow.uturn.backward", id: "live.room.restore") { model.clean = false } }; Spacer() }
                        .contentShape(Rectangle())
                        .onTapGesture { model.clean = false }
                        .padding(.leading, 18).padding(.trailing, hSize == .compact ? 82 : 18).padding(.top, hSize == .compact ? 64 : 70)
                } else if model.entered {
                    VStack {
                        header
                        Spacer(minLength: 12)
                        VStack(alignment: .leading, spacing: 12) {
                            if let chat { DYLiveChatLiveOverlay(chat: chat, bottomPadding: 0) }
                            HStack(spacing: 12) {
                                input
                                Menu {
                                    Button("清屏", systemImage: "rectangle") { model.clean = true }
                                    Toggle("静音", systemImage: "speaker.slash", isOn: $model.muted)
                                    Button("重新连接", systemImage: "arrow.clockwise", action: model.retry)
                                    Button("官网互动（礼物）", systemImage: "safari") { onWeb(room.webURL) }
                                } label: { Image(systemName: "ellipsis").font(.title2).frame(width: 44, height: 44).ddGlassCircle() }
                                .accessibilityIdentifier("live.room.more")
                            }
                        }
                        .frame(maxWidth: 420, alignment: .leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(.leading, 18)
                    .padding(.trailing, hSize == .compact ? 82 : 18)
                    .padding(.top, hSize == .compact ? 64 : 70)
                    .padding(.bottom, max(geo.safeAreaInsets.bottom, 12) + 12)
                } else {
                    VStack(alignment: .leading, spacing: 12) {
                        Spacer()
                        HStack(spacing: 10) {
                            avatar
                            VStack(alignment: .leading, spacing: 2) {
                                Text(room.owner).font(.headline).lineLimit(1)
                                Text("直播中 · \(room.viewers) 在看").font(.caption)
                            }
                        }
                        Text(room.title).font(.subheadline).lineLimit(2)
                        Button(action: model.enterRoom) {
                            Text("进入直播间").font(.subheadline.weight(.semibold))
                                .padding(.horizontal, 22).frame(height: 44).ddGlassCapsule()
                        }.buttonStyle(.plain).accessibilityIdentifier("live.room.enter")
                        Text("上滑切换直播间").font(.caption).foregroundStyle(theme.media.onMediaSecondary.color(for: scheme))
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 20)
                    .padding(.bottom, max(geo.safeAreaInsets.bottom, 12) + 24)
                }
            }
            .foregroundStyle(foreground)
        }
        #if DEBUG
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("live.page.\(room.id)")
        #endif
    }

    private var avatar: some View {
        CachedAsyncImage(url: room.avatar.flatMap(URL.init(string:))) { $0.resizable().scaledToFill() }
            placeholder: { theme.media.chromeFill.color(for: scheme) }
            .frame(width: 36, height: 36).clipShape(Circle())
    }
    private var header: some View {
        HStack(spacing: 10) {
            HStack(spacing: 8) {
                avatar
                VStack(alignment: .leading, spacing: 2) {
                    Text(room.owner).font(.subheadline.weight(.semibold)).lineLimit(1)
                    Text("\(room.viewers) 在看").font(.caption2)
                }
            }.padding(.trailing, 12).padding(.leading, 4).padding(.vertical, 4).ddGlassCapsule()
            Spacer(minLength: 8)
            circle("xmark", id: "live.room.close", action: model.leaveRoom)
        }
    }
    private func circle(_ name: String, id: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: name).font(.headline).frame(width: 44, height: 44).ddGlassCircle() }
            .buttonStyle(.plain).accessibilityIdentifier(id)
    }
}

private struct DYLiveCategories: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.appTheme) private var theme
    @Environment(\.colorScheme) private var scheme
    let selection: DYLiveZone?
    let onSelect: (DYLiveZone?) -> Void
    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 130))], spacing: 14) {
                    ForEach([nil] + DYLiveZone.all.map(Optional.some), id: \.self) { zone in
                        Button { onSelect(zone) } label: {
                            HStack {
                                Text(zone?.name ?? "推荐直播").font(.subheadline)
                                if selection == zone { Image(systemName: "checkmark").font(.caption) }
                            }
                            .frame(maxWidth: .infinity).frame(height: 46)
                            .foregroundStyle(theme.media.onMedia.color(for: scheme))
                            .ddGlassCapsule()
                        }.buttonStyle(.plain)
                    }
                }.padding(20)
            }
            .navigationTitle("直播分类").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") { dismiss() }.accessibilityIdentifier("live.categories.close")
                }
            }
        }
    }
}
