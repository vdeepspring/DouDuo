import Foundation
import Security
import SwiftUI
import WebKit

/// 多账号（老板 2026-11-17）：每个账号存一份抖音网页的登录 cookie，切换 = 换 cookie + 重载签名页。
/// - cookie 是登录凭据：整份存 Keychain（仅本机、解锁后可读、不进 iCloud 备份），App 文件里只放昵称头像等展示信息
/// - 「退出登录」只清本机登录态（删 cookie），不调抖音的登出接口——调了会让抖音作废这份凭据，存着的账号就切不回来了
/// - 「移除账号」才把存着的凭据一起删掉
struct DYSavedAccount: Codable, Identifiable, Equatable {
    var id: String          // 抖音 uid
    var name: String
    var avatar: String?
    var secUid: String
    var savedAt: Date
}

@MainActor
final class DYAccountStore: ObservableObject {
    static let shared = DYAccountStore()
    @Published private(set) var accounts: [DYSavedAccount] = []
    /// 当前登录的账号 uid（只是记录，真实登录态以 cookie 为准）
    @Published private(set) var currentID: String?

    private static let listKey = "douduo_accounts_v1"
    private static let currentKey = "douduo_account_current_v1"
    private static let service = "me.rrmm.douduo.accounts"

    init() {
        if let d = UserDefaults.standard.data(forKey: Self.listKey),
           let a = try? JSONDecoder().decode([DYSavedAccount].self, from: d) { accounts = a }
        currentID = UserDefaults.standard.string(forKey: Self.currentKey)
    }

    #if DEBUG
    private var seeded = false
    /// UI 测试：DOUDUO_FAKE_ACCOUNTS=1 放两个假账号（假 cookie，只验证切换/退出/移除流程）
    func seedFakeAccountsIfNeeded() {
        guard ProcessInfo.processInfo.environment["DOUDUO_FAKE_ACCOUNTS"] == "1", !seeded else { return }
        seeded = true
        accounts.removeAll { $0.id == "1001" || $0.id == "1002" }   // 每次启动都放回两个干净的假账号
        for (uid, name) in [("1001", "测试账号甲"), ("1002", "测试账号乙")] {
            let c: [[String: Any]] = [["name": "sessionid", "value": "fake-\(uid)", "domain": ".douyin.com", "path": "/",
                                       "secure": true, "httpOnly": true, "expires": Date().addingTimeInterval(86400).timeIntervalSince1970]]
            if let d = try? JSONSerialization.data(withJSONObject: c) { Self.keychainSet(d, account: uid) }
            accounts.append(DYSavedAccount(id: uid, name: name, avatar: nil, secUid: "sec\(uid)", savedAt: Date()))
        }
        persist()
    }
    /// 测试核对：当前 cookie 里的 sessionid
    static func debugSessionValue() async -> String? {
        await douyinCookies().first { $0.name == "sessionid" }?.value
    }
    #endif

    // MARK: 登录后记账号

    /// 当前登录的人：把这份登录 cookie 存起来（同一个 uid 覆盖）
    func remember(_ user: DYUser) async {
        guard !user.uid.isEmpty else { return }
        let cookies = await Self.douyinCookies()
        guard cookies.contains(where: { $0.name == "sessionid" && !$0.value.isEmpty }) else { return }
        guard let blob = Self.encode(cookies) else { return }
        Self.keychainSet(blob, account: user.uid)
        let entry = DYSavedAccount(id: user.uid, name: user.name, avatar: user.avatar, secUid: user.secUid, savedAt: Date())
        if let i = accounts.firstIndex(where: { $0.id == user.uid }) { accounts[i] = entry } else { accounts.append(entry) }
        currentID = user.uid
        persist()
        DYLiveModel.log("DDACCOUNT remember uid=…\(user.uid.suffix(4)) n=\(accounts.count) cookies=\(cookies.count)")
    }

    // MARK: 切换 / 退出 / 移除

    /// 切到存着的账号：清掉当前抖音 cookie，写回那个账号的 cookie
    func switchTo(_ account: DYSavedAccount) async -> Bool {
        guard let blob = Self.keychainGet(account: account.id), let cookies = Self.decode(blob), !cookies.isEmpty else {
            DYLiveModel.log("DDACCOUNT switch missing uid=…\(account.id.suffix(4))")
            return false
        }
        // 先把当前账号的最新 cookie 存一下（抖音会续期 cookie，别拿旧的覆盖）
        await refreshCurrentSnapshot()
        await Self.clearDouyinSession()
        let store = WKWebsiteDataStore.default().httpCookieStore
        for c in cookies { await store.setCookie(c) }
        currentID = account.id
        persist()
        Self.clearAccountCaches()
        DYLiveModel.log("DDACCOUNT switch uid=…\(account.id.suffix(4)) cookies=\(cookies.count)")
        #if DEBUG
        DYLiveModel.log("DDACCOUNT now sessionid=\(await Self.debugSessionValue() ?? "none")")
        #endif
        return true
    }

    /// 退出登录：清掉本机登录态（账号仍保存在列表里，可以再切回来）
    func signOut() async {
        await refreshCurrentSnapshot()
        await Self.clearDouyinSession()
        currentID = nil
        persist()
        Self.clearAccountCaches()
        DYLiveModel.log("DDACCOUNT sign-out n=\(accounts.count)")
        #if DEBUG
        DYLiveModel.log("DDACCOUNT now sessionid=\(await Self.debugSessionValue() ?? "none")")
        #endif
    }

    /// 从列表里移除（连同存着的登录凭据）
    func remove(_ account: DYSavedAccount) {
        Self.keychainDelete(account: account.id)
        accounts.removeAll { $0.id == account.id }
        persist()
        DYLiveModel.log("DDACCOUNT remove uid=…\(account.id.suffix(4)) n=\(accounts.count)")
    }

    /// 当前账号的 cookie 刷新一份进 Keychain（只有当前 sessionid 属于记录的那个账号才存）
    private func refreshCurrentSnapshot() async {
        guard let id = currentID, accounts.contains(where: { $0.id == id }) else { return }
        let cookies = await Self.douyinCookies()
        guard cookies.contains(where: { $0.name == "sessionid" && !$0.value.isEmpty }), let blob = Self.encode(cookies) else { return }
        Self.keychainSet(blob, account: id)
    }

    private func persist() {
        if let d = try? JSONEncoder().encode(accounts) { UserDefaults.standard.set(d, forKey: Self.listKey) }
        UserDefaults.standard.set(currentID, forKey: Self.currentKey)
    }

    // MARK: cookie

    static func douyinCookies() async -> [HTTPCookie] {
        await WKWebsiteDataStore.default().httpCookieStore.allCookies().filter { isDouyin($0.domain) }
    }

    private static func isDouyin(_ domain: String) -> Bool {
        let d = domain.trimmingCharacters(in: CharacterSet(charactersIn: "."))
        return ["douyin.com", "iesdouyin.com", "amemv.com", "snssdk.com"].contains { d == $0 || d.hasSuffix("." + $0) }
    }

    /// 删掉抖音相关 cookie（登录态）。localStorage 等网站数据也一起清，免得上一个账号的页面状态串过来
    static func clearDouyinSession() async {
        // App 自己清的（退出 / 切换）：登录守护不弹「登录已失效」；cookie 变化通知是异步到的，多留 2 秒
        DYSessionWatch.shared.suppressed += 1
        defer { Task { @MainActor in try? await Task.sleep(for: .seconds(2)); DYSessionWatch.shared.suppressed -= 1 } }
        let store = WKWebsiteDataStore.default()
        for c in await store.httpCookieStore.allCookies() where isDouyin(c.domain) {
            await store.httpCookieStore.deleteCookie(c)
        }
        let types: Set<String> = [WKWebsiteDataTypeLocalStorage, WKWebsiteDataTypeSessionStorage, WKWebsiteDataTypeIndexedDBDatabases]
        let records = await store.dataRecords(ofTypes: types).filter { isDouyin($0.displayName) }
        await store.removeData(ofTypes: types, for: records)
    }

    /// 换账号时清掉跟账号绑定的本地画面缓存（消息/联系人缓存按 uid 分目录，会自己换）
    static func clearAccountCaches() {
        DYChatSnapshotCache.shared.clearAll()
        sessionDidChange()
    }

    /// 登录态变了（App 内登录成功 / 切换 / 退出）：立刻重新核对账号。
    /// 信息页的账号核对有 5 分钟缓存，以前登录后还拿着「未登录时打开的聊天网页」，信息一直加载不出来（老板 11-17）。
    /// prepare() 发现账号变了会丢掉旧聊天网页，后台下一轮按新账号重开 /chat。
    static func sessionDidChange() {
        DYMessageCache.shared.invalidateScope()
        Task { @MainActor in
            await DYMessageCache.shared.prepare()
            DYLiveModel.log("DDACCOUNT session changed → message scope rechecked")
        }
    }

    private static func encode(_ cookies: [HTTPCookie]) -> Data? {
        let arr: [[String: Any]] = cookies.map { c in
            var p: [String: Any] = ["name": c.name, "value": c.value, "domain": c.domain, "path": c.path,
                                    "secure": c.isSecure, "httpOnly": c.isHTTPOnly]
            if let e = c.expiresDate { p["expires"] = e.timeIntervalSince1970 }
            if let s = c.sameSitePolicy?.rawValue { p["sameSite"] = s }
            return p
        }
        return try? JSONSerialization.data(withJSONObject: arr)
    }

    private static func decode(_ d: Data) -> [HTTPCookie]? {
        guard let arr = try? JSONSerialization.jsonObject(with: d) as? [[String: Any]] else { return nil }
        return arr.compactMap { p in
            var props: [HTTPCookiePropertyKey: Any] = [.name: p["name"] ?? "", .value: p["value"] ?? "",
                                                      .domain: p["domain"] ?? "", .path: p["path"] ?? "/"]
            if (p["secure"] as? Bool) == true { props[.secure] = "TRUE" }
            if (p["httpOnly"] as? Bool) == true { props[HTTPCookiePropertyKey("HttpOnly")] = "TRUE" }
            if let e = p["expires"] as? Double { props[.expires] = Date(timeIntervalSince1970: e) }
            if let s = p["sameSite"] as? String { props[.sameSitePolicy] = s }
            return HTTPCookie(properties: props)
        }
    }

    // MARK: Keychain

    private static func baseQuery(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
    }

    private static func keychainSet(_ data: Data, account: String) {
        let q = baseQuery(account)
        let attrs: [String: Any] = [kSecValueData as String: data,
                                    kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        var st = SecItemUpdate(q as CFDictionary, attrs as CFDictionary)
        if st == errSecItemNotFound { st = SecItemAdd(q.merging(attrs) { $1 } as CFDictionary, nil) }
        if st != errSecSuccess { DYLiveModel.log("DDACCOUNT keychain set status=\(st)") }
    }

    private static func keychainGet(account: String) -> Data? {
        var q = baseQuery(account)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        let st = SecItemCopyMatching(q as CFDictionary, &out)
        if st != errSecSuccess { DYLiveModel.log("DDACCOUNT keychain get status=\(st)") }
        return st == errSecSuccess ? out as? Data : nil
    }

    private static func keychainDelete(account: String) {
        SecItemDelete(baseQuery(account) as CFDictionary)
    }
}

extension Notification.Name {
    /// 信息页右侧栏「账号」→ 让嵌在里面的「我的」弹账号页
    static let dyOpenAccounts = Notification.Name("douduo.openAccounts")
}

/// 「我的」→ 账号：列出存着的账号，切换 / 添加 / 退出 / 移除
struct DYAccountsScreen: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var store = DYAccountStore.shared
    /// 切换 / 退出完成后让外层重载（签名页 + 推荐流 + 我的）
    let onChanged: () -> Void
    /// 添加账号：外层先退出当前登录态再弹登录页
    let onAddAccount: () -> Void
    @State private var working: String?
    @State private var failed: String?
    @State private var confirmSignOut = false
    @State private var removing: DYSavedAccount?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(store.accounts) { a in
                        Button {
                            guard a.id != store.currentID, working == nil else { return }
                            working = a.id
                            Task {
                                let ok = await store.switchTo(a)
                                working = nil
                                if ok { onChanged(); dismiss() }
                                else { failed = "「\(a.name)」的登录已失效，请移除后重新添加" }
                            }
                        } label: { row(a) }
                        .accessibilityIdentifier("douyin.account.\(a.id)")
                        .swipeActions {
                            Button("移除", role: .destructive) { removing = a }
                        }
                    }
                } header: { Text("已保存的账号") } footer: {
                    Text("登录过的账号会存在这台手机上，点一下直接切换，不用重新输验证码。抖音那边登录失效后需要重新添加。")
                }
                Section {
                    Button("添加账号", systemImage: "person.badge.plus") { onAddAccount(); dismiss() }
                        .accessibilityIdentifier("douyin.account.add")
                    if store.currentID != nil {
                        Button("退出当前账号", systemImage: "rectangle.portrait.and.arrow.right", role: .destructive) { confirmSignOut = true }
                            .accessibilityIdentifier("douyin.account.signout")
                    }
                }
                if let failed { Section { Text(failed).foregroundStyle(.red).font(.footnote) } }
            }
            #if DEBUG
            .onAppear { store.seedFakeAccountsIfNeeded() }
            #endif
            .navigationTitle("账号")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("关闭", systemImage: "xmark") { dismiss() } } }
            .confirmationDialog("退出当前账号？", isPresented: $confirmSignOut, titleVisibility: .visible) {
                Button("退出", role: .destructive) {
                    Task { await store.signOut(); onChanged(); dismiss() }
                }
            } message: { Text("账号仍保存在列表里，之后可以直接切回来。") }
            .confirmationDialog("移除「\(removing?.name ?? "")」？", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }),
                                titleVisibility: .visible) {
                Button("移除", role: .destructive) { if let r = removing { store.remove(r) }; removing = nil }
            } message: { Text("会删掉这台手机上存的登录信息，下次要重新登录。") }
        }
    }

    private func row(_ a: DYSavedAccount) -> some View {
        HStack(spacing: 12) {
            CachedAsyncImage(url: a.avatar.flatMap(URL.init(string:))) { img in img.resizable().scaledToFill() }
                placeholder: { Color.primary.opacity(0.1) }
                .frame(width: 40, height: 40).clipShape(Circle())
            Text(a.name).foregroundStyle(.primary)
            Spacer()
            if working == a.id { ProgressView() }
            else if a.id == store.currentID { Image(systemName: "checkmark").foregroundStyle(.tint) }
        }
    }
}
