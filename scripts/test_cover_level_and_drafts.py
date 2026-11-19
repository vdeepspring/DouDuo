#!/usr/bin/env python3
"""Compile production DDPlayback (cover gate) and DYCommentDraftStore against stubs; no device/account.
Regression for 11-18 ddlog: a video opened from 信息 registered while the messages cover was held,
got paused at t=0 and only started 12-33 s later."""
import os, pathlib, re, subprocess, tempfile
root = pathlib.Path(__file__).resolve().parents[1]
player = (root/'DouDuo/ShortVideoPlayer.swift').read_text()
live = (root/'DouDuo/DouyinLiveRoom.swift').read_text()
pending = (root/'DouDuo/DYCommentPending.swift').read_text().replace('import Foundation', '')
playback = player[player.index('enum DDPlaybackPauseReason'):player.index('/// 抖音视频 CDN')]
m = re.search(r'    static func apply\(appIsActive: Bool, command: DYLiveSceneCommand\) -> Bool \{.*?\n    \}\n', live, re.S)
assert m, 'live gate apply() not found'
apply = m[0]
assert 'coverLevel: coverLevel' in player, 'PlayerPage must register with its cover level'
assert 'DDPlayback.shared.isUncovered(level: coverLevel)' in player, 'foreground resume must honour cover level'
assert '.environment(\\.ddCoverLevel' in (root/'DouDuo/DouyinExtras.swift').read_text(), 'DYListPlayer must publish its level'
swift = r'''
import Foundation
enum UIApplication { enum State { case active, background }; static let shared = Fake(); final class Fake { var applicationState = State.active } }
final class AVAudioSession { static func sharedInstance() -> AVAudioSession { .init() }; enum Category { case playback }; enum Mode { case moviePlayback }
  struct Opt: OptionSet { let rawValue: Int; static let notifyOthersOnDeactivation = Opt(rawValue: 1) }
  func setCategory(_ c: Category, mode: Mode) throws {}; func setActive(_ a: Bool, options: Opt = []) throws {} }
@MainActor final class DDAudioEngineHub { static let shared = DDAudioEngineHub(); func pauseAll() {} }
enum DYLiveSceneCommand { case none, pause, resume }
struct DYImageXUploadResult: Equatable {}
struct DYCommentImageDraft: Equatable {}
struct DYComment {}
enum DYLivePlaybackGate {
''' + apply + '''}
''' + playback + pending + r'''
@main struct T { @MainActor static func main() {
  var fails = 0
  func check(_ b: Bool, _ n: String) { print((b ? "PASS " : "FAIL ") + n); if !b { fails += 1 } }
  let pb = DDPlayback.shared
  var home = 0, msgVideo = 0, homeStarted = 0, msgStarted = 0
  pb.register(UUID(), stop: { home += 1 }, start: { homeStarted += 1 })
  pb.pauseAll(reason: .cover)                      // 打开信息页
  check(home == 1, "home video pauses under the messages cover")
  let level = pb.coverDepth
  let vid = UUID()
  pb.register(vid, stop: { msgVideo += 1 }, start: { msgStarted += 1 }, coverLevel: level)
  check(msgVideo == 0, "video opened from messages is not paused at registration (was the 12-33 s start)")
  pb.pauseAll()                                    // 切后台
  UIApplication.shared.applicationState = .background
  pb.resumeAll()
  UIApplication.shared.applicationState = .active
  check(msgStarted == 1 && homeStarted == 0, "returning from background resumes the top video, not the covered home")
  pb.unregister(vid)
  pb.releaseCover()                                // 关掉信息页
  check(homeStarted == 1, "closing messages resumes home")
  let late = UUID(); var lateStops = 0
  pb.pauseAll(reason: .cover)
  pb.register(late, stop: { lateStops += 1 }, start: {})
  check(lateStops == 1, "a level-0 page registered under a cover is still paused")
  pb.releaseCover()

  let d = UserDefaults(suiteName: "drafts-\(UUID().uuidString)")!
  let k = DYCommentDraftStore.id("a1", top: nil, to: nil), r = DYCommentDraftStore.id("a1", top: "111", to: "222")
  DYCommentDraftStore.save(k, text: "hello", defaults: d); DYCommentDraftStore.save(r, text: "reply", defaults: d)
  check(DYCommentDraftStore.load(k, defaults: d) == "hello" && DYCommentDraftStore.load(r, defaults: d) == "reply", "drafts are kept per video and reply target")
  check(DYCommentDraftStore.load(k, now: Date().addingTimeInterval(4 * 86_400), defaults: d) == nil, "drafts expire after 3 days")
  DYCommentDraftStore.save(k, text: "  ", defaults: d)
  check(DYCommentDraftStore.load(k, defaults: d) == nil, "clearing the input deletes the draft")
  for i in 0..<60 { DYCommentDraftStore.save("v\(i)", text: "t", now: Date().addingTimeInterval(Double(i)), defaults: d) }
  check(DYCommentDraftStore.load("v0", defaults: d) == nil && DYCommentDraftStore.load("v59", now: Date().addingTimeInterval(60), defaults: d) == "t", "capacity keeps the newest 50")
  print("checks failures=\(fails)"); if fails > 0 { exit(1) }
} }
'''
with tempfile.TemporaryDirectory(prefix='cover-level-', dir=os.environ.get('TMPDIR')) as t:
    p = pathlib.Path(t); (p/'main.swift').write_text(swift)
    subprocess.run(['swiftc', '-parse-as-library', str(p/'main.swift'), '-o', str(p/'t')], check=True)
    raise SystemExit(subprocess.run([str(p/'t')]).returncode)
