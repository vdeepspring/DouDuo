#if DEBUG
import Foundation
import UIKit

@MainActor
enum DDFeatureProbe {
    static func run(_ bridge: DouyinBridge, live: DYLiveModel) async {
        func log(_ s: String) { DYLiveModel.log("DDVERIFY " + s) }
        try? await Task.sleep(nanoseconds: 3_000_000_000)
        for _ in 0..<40 {
            if !live.loading && !live.rooms.isEmpty { break }
            try? await Task.sleep(nanoseconds: 1_000_000_000)
        }
        log("initial rooms=\(live.rooms.count)")
        var drawable: ObjectIdentifier?
        for (i, room) in Array(live.rooms.prefix(3)).enumerated() {
            live.currentID = room.id
            live.play(room)
            let start = Date()
            for _ in 0..<200 {
                if live.vlc.mediaPlayer.hasVideoOut && live.vlc.current > 0.2 { break }
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
            let view = live.vlc.mediaPlayer.drawable as? UIView
            let identity = view.map(ObjectIdentifier.init)
            log("live round=\(i) elapsed=\(String(format: "%.2f", Date().timeIntervalSince(start))) time=\(live.vlc.current) videoOut=\(live.vlc.mediaPlayer.hasVideoOut) size=\(live.vlc.videoSize) drawable=\(view != nil) stable=\(drawable == nil || drawable == identity)")
            drawable = identity
            try? await Task.sleep(nanoseconds: 2_000_000_000)
        }
        if let zone = DYLiveZone.all.first(where: { $0.name == "英雄联盟" }) {
            live.select(zone, bridge)
            for _ in 0..<35 {
                if !live.loading && !live.rooms.isEmpty { break }
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
            log("zone=\(live.zone?.name ?? "-") rooms=\(live.rooms.count) error=\(live.error ?? "-")")
        }
        do { log("followLive count=\(try await bridge.fetchFollowLive().count)") }
        catch { log("followLive error=\(error.localizedDescription)") }
        if let saved = DYFeedSession.load(), let a = saved.items.first(where: { $0.id == saved.currentID }) {
            let words = await bridge.relatedSearch(for: a)
            log("related count=\(words.count)")
        }
        log("finished")
    }
}
#endif
