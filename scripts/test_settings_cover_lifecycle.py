"""Run settings-cover ownership logic with extracted production Swift and platform stubs.

Requires macOS and the installed Xcode Swift compiler. No network, app build,
SwiftUI presentation, AVKit, or audible playback is exercised.
"""
from pathlib import Path
import argparse
import subprocess
import tempfile
import sys

def extract(source, marker):
    start = source.index(marker)
    first = source.index("{", start)
    depth, end = 1, first + 1
    while depth:
        if source[end] == "{":
            depth += 1
        elif source[end] == "}":
            depth -= 1
        end += 1
    return source[start:end]

STUBS = r'''
import Foundation

// External platform boundaries only. DDPlayback and the scene-command gate
// below are copied verbatim from the candidate, without private-access rewrites.
final class UIApplication {
    enum State { case active, inactive, background }
    static let shared = UIApplication()
    var applicationState: State = .active
}
final class UserDefaults {
    static let standard = UserDefaults()
    func bool(forKey key: String) -> Bool { false }
}
final class AVAudioSession {
    enum Category { case playback }
    enum Mode { case moviePlayback }
    struct SetActiveOptions: OptionSet {
        let rawValue: Int
        static let notifyOthersOnDeactivation = Self(rawValue: 1)
    }
    static let shared = AVAudioSession()
    static func sharedInstance() -> AVAudioSession { shared }
    func setActive(_ active: Bool, options: SetActiveOptions = []) throws {}
    func setCategory(_ category: Category, mode: Mode) throws {}
}
@MainActor final class DDAudioEngineHub {
    static let shared = DDAudioEngineHub()
    private(set) var pauses = 0
    func pauseAll() { pauses += 1 }
}
func ddWrite(_ message: String) {}
'''

TESTS = r'''
final class Probe { var starts = 0; var stops = 0 }
@MainActor func fixture() -> (DDPlayback, Probe) {
    UIApplication.shared.applicationState = .active
    let playback = DDPlayback(), probe = Probe()
    playback.register(UUID(), stop: { probe.stops += 1 }, start: { probe.starts += 1 })
    return (playback, probe)
}
func legacyCount(_ playback: DDPlayback) -> Int {
    Mirror(reflecting: playback).children.first { $0.label == "coverCount" }!.value as! Int
}
@MainActor func check(_ condition: @autoclosure () -> Bool, _ message: String,
                      file: StaticString = #filePath, line: UInt = #line) {
    precondition(condition(), message, file: file, line: line)
}

@main struct CoverLifecycleRegression {
    @MainActor static func main() {
        check(Thread.isMainThread, "Source DDPlayback main-thread audio branch must execute")

        // 1. Idempotent ownership: duplicate appearance and all stale cleanup
        // events must not acquire or release an extra anonymous cover.
        do {
            let (p, probe) = fixture(); let owner = UUID()
            p.beginSettingsCover(owner)
            check(p.coverHold && !p.appIsActive && probe.stops == 1, "first settings acquisition pauses")
            check(legacyCount(p) == 0, "settings acquisition never touches legacy counter")
            p.beginSettingsCover(owner)
            check(probe.stops == 1 && p.coverHold, "duplicate acquire is a no-op")
            p.endSettingsCover(owner)
            check(!p.coverHold && p.appIsActive && probe.starts == 1, "last owner resumes exactly once")
            p.endSettingsCover(owner); p.endSettingsCover(owner)
            check(!p.coverHold && probe.starts == 1, "repeated cleanup cannot resume again")
            print("PASS 1 duplicate begin/end and repeated cleanup")
        }

        // 2. Root A and B overlap while DDPlayback is already inactive. The
        // second token must remain owned even though the old pause gate rejects
        // an additional pause. A foreground signal while held must not start.
        do {
            let (p, probe) = fixture(); let a = UUID(), b = UUID()
            p.beginSettingsCover(a); p.beginSettingsCover(b)
            check(!p.appIsActive && p.coverHold && probe.stops == 1, "inactive overlapping owner is retained without extra stop")
            check(legacyCount(p) == 0, "overlap does not create anonymous ownership")
            p.endSettingsCover(a)
            check(p.coverHold && probe.starts == 0, "A cleanup cannot release B")
            p.resumeAll()
            check(p.appIsActive && p.coverHold && probe.starts == 0, "foreground while B held cannot resume")
            p.endSettingsCover(b)
            check(!p.coverHold && probe.starts == 1, "B cleanup resumes even if appIsActive was already true")
            p.resumeAll(); p.endSettingsCover(a)
            check(probe.starts == 1, "duplicate foreground/stale A cannot resume again")
            print("PASS 2 overlapping roots while inactive and foreground-before-release")
        }

        // 3. Preserve legacy semantics while preventing anonymous cleanup from
        // stealing an owned settings cover. Existing accepted legacy owners can
        // close in either order. A *rejected* nested legacy pause is not claimed
        // as an accepted owner; that pre-existing behavior remains unchanged.
        do {
            let (p, probe) = fixture(); let owner = UUID()
            p.pauseAll(reason: .cover); p.beginSettingsCover(owner)
            check(legacyCount(p) == 1 && p.coverHold, "accepted legacy plus owned settings coexist")
            p.releaseCover()
            check(legacyCount(p) == 0 && p.coverHold && probe.starts == 0, "legacy release cannot steal settings owner")
            p.releaseCover()
            check(p.coverHold && probe.starts == 0, "extra legacy cleanup cannot steal settings owner")
            p.endSettingsCover(owner)
            check(!p.coverHold && probe.starts == 1, "last settings owner resumes after legacy closes")
        }
        do {
            let (p, probe) = fixture(); let owner = UUID()
            p.pauseAll(reason: .cover); p.beginSettingsCover(owner)
            p.endSettingsCover(owner)
            check(p.coverHold && legacyCount(p) == 1 && probe.starts == 0, "settings closing first preserves legacy")
            p.releaseCover()
            check(!p.coverHold && probe.starts == 1, "legacy closing last resumes")
        }
        do {
            let (p, probe) = fixture(); let owner = UUID()
            p.beginSettingsCover(owner); p.pauseAll(reason: .cover)
            check(legacyCount(p) == 0 && p.coverHold, "pre-existing rejected nested legacy pause rolls count back")
            p.releaseCover()
            check(p.coverHold && probe.starts == 0, "rejected legacy cleanup cannot release token")
            p.endSettingsCover(owner)
            check(!p.coverHold && probe.starts == 1, "owned settings still releases normally")
            print("PASS 3 legacy mixing in both accepted-owner orders; rejection semantics preserved")
        }

        // 4. Unknown and stale identities cannot clear another presentation.
        do {
            let (p, probe) = fixture(); let current = UUID(), unknown = UUID()
            p.endSettingsCover(unknown)
            check(!p.coverHold && probe.starts == 0, "unknown cleanup while uncovered is a no-op")
            p.beginSettingsCover(current); p.endSettingsCover(unknown)
            check(p.coverHold && probe.starts == 0, "unknown cleanup preserves current owner")
            p.endSettingsCover(current); p.beginSettingsCover(unknown)
            p.endSettingsCover(current)
            check(p.coverHold && probe.starts == 1, "stale current token cannot release new presentation")
            p.endSettingsCover(unknown)
            check(!p.coverHold && probe.starts == 2, "new owner can close independently")
            print("PASS 4 unknown/stale owner cleanup")
        }

        // 5. Background callbacks must still run while owned cover is the only
        // cover. Releasing in background must not start; actual foreground then
        // starts once. Separate case covers foreground *before* token cleanup.
        do {
            let (p, probe) = fixture(); let owner = UUID()
            p.beginSettingsCover(owner)
            UIApplication.shared.applicationState = .background
            p.pauseAll(reason: .background)
            check(probe.stops == 2 && p.pauseReason == .background && p.coverHold,
                  "backgroundWhileCover recognizes token-only ownership")
            p.endSettingsCover(owner)
            check(!p.coverHold && !p.appIsActive && probe.starts == 0, "background release cannot start")
            UIApplication.shared.applicationState = .active
            p.resumeAll()
            check(p.appIsActive && probe.starts == 1, "foreground after background release starts once")
            p.resumeAll(); p.endSettingsCover(owner)
            check(probe.starts == 1, "duplicate lifecycle callbacks remain idempotent")
        }
        do {
            let (p, probe) = fixture(); let owner = UUID()
            p.beginSettingsCover(owner)
            UIApplication.shared.applicationState = .background; p.pauseAll()
            UIApplication.shared.applicationState = .active; p.resumeAll()
            check(p.appIsActive && p.coverHold && probe.starts == 0, "foreground cannot override still-owned settings")
            p.endSettingsCover(owner)
            check(probe.starts == 1 && !p.coverHold, "final foreground token release starts despite appIsActive true")
            print("PASS 5 background release and foreground ordering")
        }

        // 6. Execute production cleanup API in the missing-onDismiss order
        // observed during a mode root replacement. Actual SwiftUI event delivery
        // and media playback are outside this host logic check.
        do {
            let (p, probe) = fixture(); let oldRoot = UUID(), newRoot = UUID()
            p.beginSettingsCover(oldRoot)
            p.endSettingsCover(oldRoot) // root-disappear fallback, no sheet onDismiss
            check(!p.coverHold && probe.starts == 1, "root destruction alone releases orphaned settings ownership")
            p.beginSettingsCover(newRoot)
            p.endSettingsCover(oldRoot) // delayed old sheet onDismiss
            check(p.coverHold && probe.starts == 1, "late old onDismiss cannot release new root")
            p.endSettingsCover(newRoot) // ordinary new settings closure
            p.endSettingsCover(newRoot) // duplicate root cleanup
            check(!p.coverHold && p.appIsActive && probe.starts == 2,
                  "replacement root closes without cross-root poisoning or duplicate starts")
            print("PASS 6 missing onDismiss with root cleanup and delayed old callback")
        }
        // 7. Existing offline library owns a separate presentation marker,
        // not an anonymous cover. Closing it must not override the settings
        // token, even after a foreground signal has set appIsActive true.
        do {
            let (p, probe) = fixture(); let settings = UUID(), library = UUID()
            p.beginSettingsCover(settings)
            p.resumeAll()
            check(p.appIsActive && p.coverHold && probe.starts == 0, "settings remains held after foreground")
            p.beginOfflineLibrary(library)
            check(p.offlineLibraryPresented && p.coverHold && probe.stops == 2,
                  "offline library suspends underlying players without acquiring legacy cover")
            check(legacyCount(p) == 0, "offline library does not create anonymous ownership")
            let offlinePlayer = UUID(), offline = Probe()
            p.register(offlinePlayer, stop: { offline.stops += 1 }, start: { offline.starts += 1 }, playsInsideCover: true)
            check(offline.stops == 0, "offline foreground player retains existing playsInsideCover registration exception")
            p.unregister(offlinePlayer)
            p.endOfflineLibrary(library)
            check(!p.offlineLibraryPresented && p.coverHold && probe.starts == 0,
                  "offline closing cannot start feed beneath owned settings")
            p.endOfflineLibrary(library)
            check(probe.starts == 0, "duplicate offline cleanup cannot resume")
            p.endSettingsCover(settings)
            check(!p.coverHold && probe.starts == 1, "settings final close restores normal feed after offline dismissal")
            print("PASS 7 settings ownership preserves existing offline-library gates")
        }

        // 8. Preserve upstream's level-aware permissions with total ownership depth.
        // A settings owner counts exactly like an accepted legacy cover for depth,
        // while stale cleanup can never expose a lower player prematurely.
        do {
            let (p, home) = fixture(); let owner = UUID(), lower = Probe(), top = Probe()
            p.pauseAll(reason: .cover)
            p.beginSettingsCover(owner)
            check(legacyCount(p) == 1 && p.coverDepth == 2, "mixed covers contribute total depth")
            check(!p.isUncovered(level: 0) && !p.isUncovered(level: 1) && p.isUncovered(level: 2),
                  "only the current top level is uncovered")
            p.register(UUID(), stop: { lower.stops += 1 }, start: { lower.starts += 1 }, coverLevel: 1)
            p.register(UUID(), stop: { top.stops += 1 }, start: { top.starts += 1 }, coverLevel: p.coverDepth)
            check(lower.stops == 1 && top.stops == 0, "registration compares level against total cover depth")
            p.resumeAll()
            check(home.starts == 0 && lower.starts == 0 && top.starts == 1,
                  "foreground with covers starts only players at the top")
            p.endSettingsCover(owner)
            check(p.coverDepth == 1 && !p.isUncovered(level: 0) && p.isUncovered(level: 1),
                  "settings release preserves accepted legacy depth")
            check(home.starts == 0 && lower.starts == 1 && top.starts == 2,
                  "one remaining cover resumes only players on its level")
            p.endSettingsCover(owner)
            check(lower.starts == 1 && top.starts == 2, "repeated token cleanup cannot restart top players")
            p.releaseCover()
            check(p.coverDepth == 0 && p.isUncovered(level: 0) && home.starts == 1,
                  "last legacy release exposes home and resumes all normally")
        }
        do {
            let (p, home) = fixture(); let a = UUID(), b = UUID(), upstairs = Probe()
            p.beginSettingsCover(a)
            check(p.coverDepth == 1, "first settings token contributes one level")
            p.register(UUID(), stop: { upstairs.stops += 1 }, start: { upstairs.starts += 1 }, coverLevel: 1)
            p.resumeAll()
            check(upstairs.starts == 1 && home.starts == 0, "upstairs player can resume while home remains covered")
            p.beginSettingsCover(b)
            check(p.coverDepth == 2 && !p.isUncovered(level: 1) && upstairs.stops == 1,
                  "new accepted cover hides and stops the upstairs player")
            p.endSettingsCover(b)
            check(p.coverDepth == 1 && upstairs.starts == 2 && home.starts == 0,
                  "closing nested settings restores upstairs without exposing home")
            p.releaseCover()
            check(p.coverDepth == 1 && upstairs.starts == 2, "legacy cleanup cannot consume a remaining settings level")
            UIApplication.shared.applicationState = .background
            p.pauseAll(reason: .background)
            let late = Probe()
            p.register(UUID(), stop: { late.stops += 1 }, start: { late.starts += 1 }, coverLevel: p.coverDepth)
            check(late.stops == 1, "cover-level exception never permits background registration")
            p.endSettingsCover(a)
            check(p.coverDepth == 0 && home.starts == 0, "last settings release in background cannot resume home")
            UIApplication.shared.applicationState = .active
            p.resumeAll()
            check(home.starts == 1 && late.starts == 1, "foreground after final release restores normal registration")
            print("PASS 8 mixed ownership depth and level-aware registration/resume")
        }
        print("PASS 8 ownership groups using extracted production DDPlayback methods")
    }
}
'''


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source-root", type=Path, default=Path(__file__).resolve().parents[1])
    args = parser.parse_args()
    app = args.source_root / "DouDuo"
    source = (app / "ShortVideoPlayer.swift").read_text()
    live = (app / "DouyinLiveRoom.swift").read_text()
    playback = extract(source, "final class DDPlayback {")
    reason = extract(source, "enum DDPlaybackPauseReason: Equatable {")
    command = extract(live, "enum DYLiveSceneCommand: Equatable {")
    apply = extract(live, "    static func apply(appIsActive: Bool, command: DYLiveSceneCommand) -> Bool {")
    swift = (STUBS + "\n" + reason + "\n" + command + "\nstruct DYLivePlaybackGate {\n"
             + apply + "\n}\n" + playback + "\n" + TESTS)
    with tempfile.TemporaryDirectory(prefix="settings-cover-regression-") as temporary:
        scratch = Path(temporary)
        generated = scratch / "main.swift"
        binary = scratch / "check"
        generated.write_text(swift)
        compiled = subprocess.run(
            ["xcrun", "swiftc", "-swift-version", "5", "-D", "DEBUG", "-parse-as-library",
             "-module-cache-path", str(scratch / "module-cache"), str(generated), "-o", str(binary)],
            text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
        if compiled.returncode:
            print(compiled.stdout, end="")
            return compiled.returncode
        executed = subprocess.run([str(binary)], text=True,
                                  stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
        print(executed.stdout, end="")
        return executed.returncode


if __name__ == "__main__":
    sys.exit(main())
