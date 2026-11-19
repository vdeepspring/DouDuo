// 版本更新内容：
// 1. 检查到新版本时，提示里直接显示新版写了什么（不用先跳 GitHub 看）；
// 2. 装上新版后第一次打开，显示一次「本次更新内容」；
// 3. 设置 →「关于」随时能再看当前版本的更新内容。
// 内容就是发版用的 docs/releases/v<版本>.md（GitHub 读不到时用 Gitee 镜像）。
import SwiftUI

enum DDReleaseNotes {
    /// 上次已经展示过「本次更新内容」的版本
    static let seenKey = "douduo_whatsnew_seen_v1"

    static func sources(_ tag: String) -> [URL] {
        ["https://raw.githubusercontent.com/\(DDUpdateChecker.repo)/main/docs/releases/\(tag).md",
         "https://gitee.com/remon8/douduo/raw/main/docs/releases/\(tag).md"].compactMap(URL.init(string:))
    }

    /// 读某个版本的更新说明（Markdown 原文）；都读不到返回 nil
    static func fetch(version: String) async -> String? {
        let tag = version.hasPrefix("v") ? version : "v\(version)"
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 10
        cfg.httpShouldSetCookies = false
        let session = URLSession(configuration: cfg)
        for url in sources(tag) {
            var req = URLRequest(url: url, timeoutInterval: 10)
            req.setValue("DouDuo-iOS", forHTTPHeaderField: "User-Agent")
            guard let (d, r) = try? await session.data(for: req),
                  (r as? HTTPURLResponse)?.statusCode == 200,
                  let s = String(data: d, encoding: .utf8),
                  s.hasPrefix("#") else { continue }
            return s
        }
        return nil
    }

    /// 刚升级到新版本、还没展示过 → 返回当前版本号；第一次安装不打扰
    static func pendingWhatsNew() -> String? {
        let cur = DDUpdateChecker.currentVersion
        let d = UserDefaults.standard
        #if DEBUG
        // 调试：DOUDUO_WHATSNEW_FROM=1.6.0 假装刚从这个版本升级上来
        if let from = ProcessInfo.processInfo.environment["DOUDUO_WHATSNEW_FROM"], !from.isEmpty { d.set(from, forKey: seenKey) }
        #endif
        guard let seen = d.string(forKey: seenKey) else {
            d.set(cur, forKey: seenKey)
            return nil
        }
        return seen == cur ? nil : cur
    }

    static func markSeen(_ version: String) { UserDefaults.standard.set(version, forKey: seenKey) }

    // MARK: 把发版说明的 Markdown 拆成段落

    enum Block: Hashable {
        case title(String), heading(String), sub(String), bullet(String), text(String)
    }

    static func parse(_ md: String) -> [Block] {
        var out: [Block] = []
        var para: [String] = []
        func flush() { if !para.isEmpty { out.append(.text(para.joined(separator: " "))); para.removeAll() } }
        for raw in md.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { flush(); continue }
            if line.hasPrefix("### ") { flush(); out.append(.sub(String(line.dropFirst(4)))) }
            else if line.hasPrefix("## ") { flush(); out.append(.heading(String(line.dropFirst(3)))) }
            else if line.hasPrefix("# ") { flush(); out.append(.title(String(line.dropFirst(2)))) }
            else if line.hasPrefix("- ") || line.hasPrefix("* ") { flush(); out.append(.bullet(String(line.dropFirst(2)))) }
            else if line.hasPrefix("!["), line.hasSuffix(")") { continue }   // 截图不在 App 里显示
            else { para.append(line) }
        }
        flush()
        return out
    }

    static func inline(_ s: String) -> AttributedString {
        (try? AttributedString(markdown: s, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(s)
    }
}

/// 更新内容页：新版本提示 / 升级后首次打开 / 设置里查看，共用
struct DDReleaseNotesSheet: View {
    enum Mode: Equatable { case update(DDUpdate), whatsNew(String) }
    let mode: Mode
    var onUpdate: (() -> Void)? = nil
    @Environment(\.dismiss) private var dismiss
    @State private var text: String?
    @State private var failed = false

    private var version: String {
        switch mode { case .update(let u): u.version; case .whatsNew(let v): v }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    if case .update = mode {
                        Text("新版本 \(version)（当前 \(DDUpdateChecker.currentVersion)）。去 GitHub 下载新版，重新签名安装即可，登录态会保留。")
                            .font(.subheadline).foregroundStyle(.secondary)
                            .padding(.bottom, 4)
                    }
                    if let text {
                        ForEach(Array(DDReleaseNotes.parse(text).enumerated()), id: \.offset) { _, b in
                            block(b)
                        }
                    } else if failed {
                        Text("更新说明暂时读不到，可以去 GitHub 的发布页查看。")
                            .foregroundStyle(.secondary)
                    } else {
                        HStack { Spacer(); ProgressView(); Spacer() }.padding(.top, 40)
                    }
                }
                .padding(.horizontal, 20).padding(.vertical, 16)
                .frame(maxWidth: 640, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
            .background(Color.ddBackground)
            .navigationTitle(mode == .whatsNew(version) ? "本次更新内容" : "有新版本")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }.accessibilityIdentifier("whatsnew.close")
                }
                if case .update = mode {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("去 GitHub 更新") { onUpdate?(); dismiss() }.accessibilityIdentifier("whatsnew.update")
                    }
                }
            }
        }
        .task {
            if text != nil { return }
            if let s = await DDReleaseNotes.fetch(version: version) { text = s } else { failed = true }
        }
    }

    @ViewBuilder private func block(_ b: DDReleaseNotes.Block) -> some View {
        switch b {
        case .title(let s):
            Text(DDReleaseNotes.inline(s)).font(.title3.weight(.bold)).padding(.bottom, 2)
        case .heading(let s):
            Text(DDReleaseNotes.inline(s)).font(.headline).padding(.top, 10)
        case .sub(let s):
            Text(DDReleaseNotes.inline(s)).font(.subheadline.weight(.semibold)).padding(.top, 4)
        case .bullet(let s):
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("•").foregroundStyle(.secondary)
                Text(DDReleaseNotes.inline(s)).font(.body)
            }
        case .text(let s):
            Text(DDReleaseNotes.inline(s)).font(.body)
        }
    }
}

/// 挂在首页根视图上：启动查新版本（弹更新内容），或刚升级完显示一次本次更新内容
struct DDReleaseNotesModifier: ViewModifier {
    @State private var sheet: DDReleaseNotesSheet.Mode?

    func body(content: Content) -> some View {
        content
            .task {
                if let v = DDReleaseNotes.pendingWhatsNew() {
                    // 先确认读得到说明再弹；读不到下次启动再试
                    let ok = await DDReleaseNotes.fetch(version: v) != nil
                    DYLiveModel.log("DDWHATSNEW v=\(v) notes=\(ok ? 1 : 0)")
                    if ok { sheet = .whatsNew(v) }
                    return
                }
                if let u = await DDUpdateChecker.check() { sheet = .update(u) }
            }
            .sheet(item: Binding(get: { sheet.map(DDSheetBox.init) }, set: { if $0 == nil { closed() } })) { box in
                DDReleaseNotesSheet(mode: box.mode, onUpdate: {
                    if case .update(let u) = box.mode { DDUpdateChecker.open(u) }
                })
            }
    }

    private func closed() {
        switch sheet {
        case .update(let u)?: DDUpdateChecker.dismiss(u)
        case .whatsNew(let v)?: DDReleaseNotes.markSeen(v)
        case nil: break
        }
        sheet = nil
    }
}

private struct DDSheetBox: Identifiable {
    let mode: DDReleaseNotesSheet.Mode
    var id: String {
        switch mode { case .update(let u): "u" + u.version; case .whatsNew(let v): "w" + v }
    }
}
