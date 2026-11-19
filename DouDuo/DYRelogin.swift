import SwiftUI

/// 单个评论接口 code 8 只说明这次写入要求验证，不证明整个账号会话已失效。
struct DYLoginExpired: LocalizedError {
    var errorDescription: String? { "抖音拦下了这次评论（需要验证或暂时受限）；登录和草稿已保留" }
}

@MainActor
enum DYRelogin {
    static func start(_ present: @escaping () -> Void) {
        // 只展示选择，不动共享 cookie、网页存储、账号或草稿。
        present()
    }
}

struct DYReloginSheet: ViewModifier {
    @Binding var isPresented: Bool
    let bridge: DouyinBridge
    /// true 只代表实际读到账号资料，不保证写权限，也不自动重发。
    var onFinish: (Bool) -> Void
    @State private var verified = false

    func body(content: Content) -> some View {
        content.sheet(isPresented: $isPresented, onDismiss: {
            onFinish(verified)
            verified = false
        }) {
            DYCommentRecoveryScreen(bridge: bridge) { verified = $0 }
        }
    }
}

/// 不直接弹登录页：旧 session 仍在时，应先允许用户保留会话完成网页验证。
private struct DYCommentRecoveryScreen: View {
    @Environment(\.dismiss) private var dismiss
    let bridge: DouyinBridge
    var onVerified: (Bool) -> Void
    @State private var showWeb = false
    @State private var showLogin = false
    @State private var confirmCleanup = false
    @State private var busy = false
    /// 本机 sessionid 已经没了（被网页登出 / 过期清掉）：这时不能再说「登录已保留」
    @State private var sessionGone = false
    @State private var message = "抖音拦下了这次评论（要求验证或暂时受限），不等于整个登录已过期。原登录与草稿已保留，不会自动重发。可先打开网页版看看有没有验证提示，或歇几分钟再发。"

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text(message)
                    if sessionGone {
                        Button("重新登录") { showLogin = true }
                    }
                    Button("保留登录，打开网页版检查验证") { showWeb = true }
                    Button("核验当前账号资料") { Task { await verify() } }
                        .disabled(busy)
                } footer: {
                    Text("资料可读取不代表评论权限已恢复；请先检查目标评论，避免重复发送。")
                }
                Section {
                    Button("清理本机登录并重新登录…", role: .destructive) { confirmCleanup = true }
                        .disabled(busy)
                } footer: {
                    Text("仅在你明确确认后清理共享网页登录数据；这会影响其他页面的登录，但不会删除此处草稿。")
                }
            }
            .navigationTitle(sessionGone ? "需要重新登录" : "评论验证与恢复")
            .task {
                if !(await DYLoginState.hasSession()) {
                    sessionGone = true
                    message = "本机的抖音登录已经没了（被退出），评论发不出去。点「重新登录」登录后再发，草稿还在，不会自动重发。"
                    DYLiveModel.log("DDSESSION comment recovery: sessionid gone")
                    return
                }
                // cookie 还在不代表还登录着：11-19 00:48 真机评论 403 后，sessionid 仍在本机，
                // 但抖音已把这次登录作废（读自己资料返回「用户未登录」）。实际问一次服务器再下结论。
                do {
                    _ = try await bridge.selfProfile()
                } catch where Self.saysLoggedOut(error) {
                    sessionGone = true
                    message = "抖音把这次登录作废了：本机还留着登录记录，但抖音那边已是未登录，所以评论发不出去。点「重新登录」登录后再发，草稿还在，不会自动重发。"
                    DYLiveModel.log("DDSESSION comment recovery: server says logged out (cookie present)")
                } catch {
                    DYLiveModel.log("DDSESSION comment recovery: profile check inconclusive")
                }
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("保留草稿并关闭") { dismiss() } }
            }
        }
        .confirmationDialog("确认清理共享网页登录数据并重新登录？", isPresented: $confirmCleanup, titleVisibility: .visible) {
            Button("确认清理并重新登录", role: .destructive) {
                Task { @MainActor in
                    busy = true
                    onVerified(false)
                    await DYAccountStore.shared.signOut()
                    bridge.reload()
                    busy = false
                    showLogin = true
                }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("会清理本机抖音 cookie 和网页存储，影响共享此登录的页面。评论草稿保留。此操作不发送评论。")
        }
        .sheet(isPresented: $showWeb, onDismiss: { Task { await verify() } }) {
            DouyinWebScreen()
        }
        .sheet(isPresented: $showLogin, onDismiss: { Task { await verify() } }) {
            // 此入口已由用户确认清理，避免旧 session 自动跳走与假成功。
            DYAppLoginScreen()
        }

    }

    /// 只认抖音明确说「未登录」；网络错、超时不算，免得误报掉线
    static func saysLoggedOut(_ error: Error) -> Bool {
        let text = error.localizedDescription
        return text.contains("未登录") || text.contains("登录已失效") || text.contains("请先登录")
    }

    @MainActor private func verify() async {
        guard !busy else { return }
        busy = true
        defer { busy = false }
        bridge.reload()
        if let user = try? await bridge.selfProfile() {
            onVerified(true)
            await DYAccountStore.shared.remember(user)
            message = "已实际读取账号资料；这不代表评论权限已恢复。草稿保留，请先检查目标评论，不要连续重发。"
        } else {
            onVerified(false)
            message = "未能核验账号资料；未自动清理登录。可保留会话检查网页验证，或明确选择清理后重新登录。"
        }
    }
}

extension View {
    func dyReloginSheet(isPresented: Binding<Bool>, bridge: DouyinBridge, onFinish: @escaping (Bool) -> Void) -> some View {
        modifier(DYReloginSheet(isPresented: isPresented, bridge: bridge, onFinish: onFinish))
    }
}
