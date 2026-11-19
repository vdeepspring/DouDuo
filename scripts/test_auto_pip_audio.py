#!/usr/bin/env python3
"""自动画中画的声音口径（老板 2026-11-19 定方案 A）：
前台变速照样交给独立引擎（不断声），只在离开 App、要进系统画中画时把声音交回 AVPlayer 原生。"""
import re, sys
from pathlib import Path
root = Path(__file__).resolve().parent.parent
pip = (root / "DouDuo/DYAutoPiP.swift").read_text()
player = (root / "DouDuo/ShortVideoPlayer.swift").read_text()
seam = (root / "DouDuo/SeamlessAudioPlayer.swift").read_text()
fail = 0
def check(ok, msg):
    global fail
    print(("PASS " if ok else "FAIL ") + msg); fail += 0 if ok else 1

body = re.search(r"static func bindsNativeAudio\(preference: Bool, cleanScreen: Bool\) -> Bool \{\s*([^}]*)\}", pip)
check(body is not None and body.group(1).strip() == "cleanScreen", "绑定时只有清屏全程锁原生声音，自动画中画不锁")
check("DYAutoPiP.bindsNativeAudio(preference: autoPiP, cleanScreen: cleanScreen)" in player, "PlayerPage 绑定声音用 bindsNativeAudio")
check("DYAutoPiP.requiresNativeAudio(preference: autoPiP, cleanScreen: cleanScreen)" not in player.split("private func bindSeamlessAudio")[1].split("private func setup")[0],
      "绑定处不再用 requiresNativeAudio（那会让前台加速断声）")
pb = player.split("private func pauseForBackground()")[1].split("private func pauseInlineForBackground")[0]
i_keep = pb.find("pictureInPicture.keepsPlaybackOnExit")
i_back = pb.find('seamAudio.returnToNativeAudio(reason: "pip-exit")')
check(i_keep >= 0 and i_back > i_keep, "保留播放进画中画的分支里先把声音交回原生")
check("func returnToNativeAudio(reason: String) -> Bool" in seam, "SeamlessController 有就地交回原生的接口")
rb = seam.split("func returnToNativeAudio(reason: String) -> Bool")[1].split("private func beginEngineHandoff")[0]
check("enableAudioTracks" in rb and "stopEngineOutput()" in rb and "cancelHandoff()" in rb, "交回时停引擎、作废进行中的交接、重新打开原生音轨")
print(f"checks failed={fail}")
sys.exit(1 if fail else 0)
