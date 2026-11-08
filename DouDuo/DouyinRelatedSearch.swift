import SwiftUI

extension DouyinBridge {
    /// 网页真实的 related_search 推荐词；接口无词时不展示，不用标题或本地词凑数。
    func relatedSearch(for item: DYAweme) async -> [String] {
        let js = #"""
        const r = await req('GET', '/aweme/v1/web/api/suggest_words/?' + q({
          query: query, business_id: '30125', aid: '6383', app_name: 'douyin_web', pd: 'aweme_general', gid: id
        }));
        const d = parse(r.t);
        const words = r.s === 200 && d && String(d.errno || 0) === '0'
          ? (d.data || []).filter(g => g.type === 'related_search' || g.source === 'related_search')
              .flatMap(g => (g.words || []).map(w => w.word).filter(w => typeof w === 'string' && w.trim())) : [];
        return JSON.stringify([...new Set(words)].slice(0, 6));
        """#
        guard let d = try? await call(js, args: ["query": String(item.desc.prefix(100)), "id": item.id], attempts: 1),
              let words = try? JSONDecoder().decode([String].self, from: d) else { return [] }
        return words
    }
}

struct DYRelatedQuery: Identifiable {
    let word: String
    var id: String { word }
}

/// 复用现有原生搜索、作者主页和网页登录组件。
struct DYRelatedSearchScreen: View {
    let bridge: DouyinBridge
    let word: String
    @State private var author: DYAweme.Author?
    @State private var web: DYWebTarget?

    var body: some View {
        DYSearchScreen(bridge: bridge, onAuthor: { author = $0.author }, initialQuery: word)
            .sheet(item: $author) { a in
                DYAuthorScreen(bridge: bridge, author: a, onWeb: { url in
                    author = nil
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { web = DYWebTarget(url: url) }
                })
            }
            .fullScreenCover(item: $web) { t in DouyinWebScreen(start: t.url) }
    }
}
