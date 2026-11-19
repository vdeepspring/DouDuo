import Foundation

/// Short-video preference; clean-screen mode retains its existing PiP behavior.
enum DYAutoPiP {
    static let storageKey = "douyin_auto_pip_v1"

    static func enabled(in defaults: UserDefaults) -> Bool {
        defaults.bool(forKey: storageKey)
    }

    static func shortVideoWantsAutomaticPiP(preference: Bool, cleanScreen: Bool, isActive: Bool) -> Bool {
        isActive && (cleanScreen || preference)
    }

    /// System PiP controls the AVPlayer audio track, including pause/resume.
    /// 离开 App 那一刻要求声音在 AVPlayer 上（见 bindsNativeAudio：自动画中画平时仍可交给引擎变速）。
    static func requiresNativeAudio(preference: Bool, cleanScreen: Bool) -> Bool {
        cleanScreen || preference
    }

    /// 绑定播放器时是否全程锁原生声音（不允许变速交给独立引擎）。
    /// 只有清屏模式全程锁；自动画中画只在离开 App 时把声音交回原生（老板 2026-11-19 定方案 A），
    /// 前台长按加速照样不断声。
    static func bindsNativeAudio(preference: Bool, cleanScreen: Bool) -> Bool {
        cleanScreen
    }

    static func keepsPiPController(enabled: Bool, active: Bool, starting: Bool) -> Bool {
        enabled || active || starting
    }
}
