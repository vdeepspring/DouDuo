// 「真人方式」发评论：在后台打开这条视频的抖音网页，往它自己的评论框里输入，再点它自己的「发送」。
// 请求由抖音网页自己发出（签名、风控参数、页面行为都与真人一致），我们只在旁边看它的回执。
// 老板 11-19：直接调评论接口时偶发 403 + 服务器作废登录，改成这种方式降低风控概率。
import Foundation
import WebKit

@MainActor
final class DYWebComposer: NSObject, WKNavigationDelegate {
    static let shared = DYWebComposer()

    private var web: WKWebView?
    private var loadedAweme: String?
    private var loadWaiters: [CheckedContinuation<Void, Never>] = []
    private var loading = false

    /// 是否走「真人方式」。默认开；设置里可关（关掉回到直接调接口）。
    static let enabledKey = "douduo_comment_via_web_ui_v1"
    static var enabled: Bool {
        // 11-19：网页评论框发送 403 后抖音同时作废登录（真机 12:11），查清前默认关，走原接口
        get { UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? false }
        set { UserDefaults.standard.set(newValue, forKey: enabledKey) }
    }

    struct Outcome: Decodable {
        let state: String            // sent / rejected / unconfirmed / 各种未发出原因
        let stage: String?           // 停在哪一步（只记步骤名，不记内容）
        let status: Int?
        let code: Int?
        let msg: String?
        let comment: DYComment?
        let diagnostic: String?
    }

    private func makeWeb(host: UIView?) -> WKWebView {
        if let web { return web }
        let cfg = WKWebViewConfiguration()
        cfg.websiteDataStore = .default()
        cfg.mediaTypesRequiringUserActionForPlayback = .all
        cfg.allowsInlineMediaPlayback = true
        cfg.allowsPictureInPictureMediaPlayback = false
        cfg.userContentController.addUserScript(WKUserScript(source: DouyinBridge.composerNoMediaJS, injectionTime: .atDocumentStart, forMainFrameOnly: false))
        DYTrustLogin.install(in: cfg)
        DYLogoutBlock.install(in: cfg)
        DYKeyStateProbe.install(in: cfg, tag: "composer")
        // 桌面宽度：抖音视频详情页在宽屏下评论区常驻右侧，评论框一直在
        let w = WKWebView(frame: CGRect(x: 0, y: 0, width: 1280, height: 860), configuration: cfg)
        w.customUserAgent = DouyinWeb.userAgent
        w.navigationDelegate = self
        w.alpha = 0.01
        w.isUserInteractionEnabled = false
        #if DEBUG
        w.isInspectable = true
        #endif
        host?.addSubview(w)
        web = w
        return w
    }

    /// 打开（或复用）这条视频的网页，等评论区出来
    private func open(_ awemeID: String, host: UIView?) async -> WKWebView {
        let w = makeWeb(host: host)
        if w.superview == nil, let host { host.addSubview(w) }
        if loadedAweme == awemeID, !loading { return w }
        loadedAweme = awemeID
        loading = true
        w.load(URLRequest(url: URL(string: "https://www.douyin.com/video/\(awemeID)")!))
        await withCheckedContinuation { loadWaiters.append($0) }
        return w
    }

    nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        Task { @MainActor in self.finishLoad() }
    }
    nonisolated func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        Task { @MainActor in self.finishLoad() }
    }
    nonisolated func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        Task { @MainActor in self.loadedAweme = nil; self.finishLoad() }
    }

    private func finishLoad() {
        loading = false
        loadWaiters.forEach { $0.resume() }
        loadWaiters.removeAll()
    }

    /// 发一条评论 / 回复。replyTo = 要回复的那条评论（一级或楼中楼）的 cid；top = 它所在的一级评论 cid。
    func publish(awemeID: String, text: String, top: String?, replyTo: String?, host: UIView?) async throws -> Outcome {
        idleTask?.cancel()
        defer { scheduleIdleUnload() }
        let w = await open(awemeID, host: host)
        let args: [String: Any] = ["text": text, "top": top ?? "", "target": replyTo ?? ""]
        let r = try await w.callAsyncJavaScript(Self.sendJS, arguments: args, contentWorld: .page)
        guard let s = r as? String, let d = s.data(using: .utf8) else { throw DYError.bad("网页评论框没有返回结果") }
        return try JSONDecoder().decode(Outcome.self, from: d)
    }

    private var idleTask: Task<Void, Never>?
    /// 闲 90 秒就卸掉网页，不占内存
    func scheduleIdleUnload() {
        idleTask?.cancel()
        idleTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 90_000_000_000)
            guard let self, !Task.isCancelled else { return }
            self.web?.removeFromSuperview()
            self.web?.navigationDelegate = nil
            self.web = nil
            self.loadedAweme = nil
        }
    }

    /// 只读：看评论框和发送按钮的结构，不输入、不点击（调试用）
    func probe(awemeID: String, host: UIView?) async -> String {
        let w = await open(awemeID, host: host)
        let r = try? await w.callAsyncJavaScript(Self.probeJS, arguments: [:], contentWorld: .page)
        return (r as? String) ?? "nil"
    }

    static let probeJS = #"""
    const sleep = ms => new Promise(r => setTimeout(r, ms));
    for (let i = 0; i < 40 && !document.querySelector('[data-e2e="comment-list"]'); i++) await sleep(250);
    await sleep(1500);
    const desc = e => e ? (e.tagName + '.' + String(e.className).split(' ').slice(0, 2).join('.') + (e.getAttribute && e.getAttribute('data-e2e') ? '[' + e.getAttribute('data-e2e') + ']' : '') + (e.getAttribute && e.getAttribute('contenteditable') ? '{ce=' + e.getAttribute('contenteditable') + '}' : '')) : '-';
    const chain = e => { const s = []; for (let i = 0; i < 6 && e; i++, e = e.parentElement) s.push(desc(e)); return s.join(' < '); };
    const vis2 = e => { const r = e.getBoundingClientRect(); return r.width > 0 && r.height > 0; };
    const eds = [...document.querySelectorAll('[contenteditable="true"],textarea,[role="textbox"],[data-slate-editor]')].map(e => ({ el: chain(e), ph: (e.getAttribute('placeholder') || e.getAttribute('data-placeholder') || '').slice(0, 20), slate: e.getAttribute('data-slate-editor'), w: Math.round(e.getBoundingClientRect().width) }));
    const sends = [...document.querySelectorAll('div,span,button')].filter(e => e.children.length === 0 && /^(发送|发布)$/.test((e.innerText || '').trim())).map(e => chain(e));
    const ph = [...document.querySelectorAll('div,span')].filter(e => e.children.length === 0 && /留下你的精彩评论|说点什么|善语结善缘|回复 ?@|发条评论/.test(e.innerText || '')).map(e => ({ t: (e.innerText || '').slice(0, 14), el: chain(e) }));
    // 点一下占位文字让编辑器出来（只聚焦，不输入、不发送），再看一次
    const holder = document.querySelector('.comment-input-inner-container');
    if (holder) { holder.click(); (holder.querySelector('span') || holder).click(); }
    await sleep(1200);
    const eds2 = [...document.querySelectorAll('[contenteditable="true"],textarea,[role="textbox"],[data-slate-editor]')].map(e => ({ el: chain(e), slate: e.getAttribute('data-slate-editor'), draft: !!e.closest('.DraftEditor-root'), w: Math.round(e.getBoundingClientRect().width) }));
    const near = holder ? [...(holder.closest('[class]').parentElement || holder).querySelectorAll('*')].filter(e => e.children.length === 0 && (e.innerText || '').trim()).map(e => (e.innerText || '').trim().slice(0, 8) + '@' + desc(e)).slice(0, 12) : [];
    const sends2 = [...document.querySelectorAll('div,span,button')].filter(e => e.children.length === 0 && /^(发送|发布)$/.test((e.innerText || '').trim()) && !e.closest('.danmakuInputContainer')).map(e => chain(e));
    const reply = [...document.querySelectorAll('[data-e2e="comment-item"] span')].filter(e => (e.innerText || '').trim() === '回复').slice(0, 1).map(e => chain(e));
    const fk = (() => { const it = document.querySelector('[data-e2e="comment-item"]'); const k = it && Object.keys(it).find(k => k.startsWith('__reactFiber')); let f = k && it[k]; for (let d = 0; f && d < 10; d++, f = f.return) { const c = (f.memoizedProps || {}).commentInfo; if (c) return 'cid@' + d + ' keys=' + Object.keys(c).length; } return 'none'; })();
    // 只输入不发送：选中全部再插入（应当是替换而不是追加），看「发送」按钮，然后 Draft 的方式清空
    const editorOf = () => document.querySelector('.comment-input-inner-container .public-DraftEditor-content');
    const selectAll = ed => { ed.focus(); const r = document.createRange(); r.selectNodeContents(ed); const sl = getSelection(); sl.removeAllRanges(); sl.addRange(r); };
    const draftText = ed => { const root = ed.closest('.DraftEditor-root'); const k = root && Object.keys(root).find(k => k.startsWith('__reactFiber')); let f = k && root[k]; for (let d = 0; f && d < 12; d++, f = f.return) { const es = (f.memoizedProps || {}).editorState; if (es) return es.getCurrentContent().getPlainText(); } return '?'; };
    let before = null, typed = null, typedDraft = null, sends3 = [], cleared = null, replyEd = null, icons = [];
    // 只用 Draft 自己的 API：设内容 → 看发送按钮 → 清空；每步读它自己的状态和 DOM
    const draftHandle = ed => { const root = ed.closest('.DraftEditor-root'); const k = Object.keys(root).find(k => k.startsWith('__reactFiber')); let f = root[k]; for (let d = 0; f && d < 12; d++, f = f.return) { const pr = f.memoizedProps || {}; if (pr.editorState && typeof pr.onChange === 'function') return pr; } return null; };
    const setDraft = (ed, t) => { const pr = draftHandle(ed); if (!pr) return false; const es = pr.editorState, ES = es.constructor, CS = es.getCurrentContent().constructor; pr.onChange(ES.moveFocusToEnd(ES.push(es, CS.createFromText(t), 'insert-characters'))); return true; };
    const rightIcons = ed => { const r = ed.closest('.comment-input-inner-container').parentElement.querySelector('.commentInput-right-ct'); return r ? [...r.children].map(c => String(c.className).split(' ')[0] + '/' + [...c.querySelectorAll('span')].map(x => String(x.className).split(' ').join('.')).join(',')).join(' ; ') : '-'; };
    const steps = [];
    let ed = editorOf();
    if (ed) {
      ed.focus(); await sleep(200);
      steps.push('start=' + JSON.stringify(draftText(ed)) + ' icons=' + rightIcons(ed));
      setDraft(ed, '探针'); await sleep(800); ed = editorOf();
      steps.push('set=' + JSON.stringify(draftText(ed)) + ' dom=' + JSON.stringify((ed.innerText || '').trim()) + ' icons=' + rightIcons(ed));
      const ic = ed.closest('.comment-input-inner-container').parentElement.querySelector('.commentInput-right-ct .wchsYBpK');
      const fkey = ic && Object.keys(ic).find(k => k.startsWith('__reactProps'));
      const handlers = []; let g = ic; for (let d = 0; g && d < 4; d++, g = g.parentElement) { const pk = Object.keys(g).find(k => k.startsWith('__reactProps')); const pp = pk ? g[pk] : {}; handlers.push(d + ':' + Object.keys(pp).filter(k => /^on/.test(k)).join('/') + ':' + String(g.className).split(' ').join('.')); }
      const svgPath = ic ? (ic.querySelector('path')?.getAttribute('d') || '').slice(0, 40) : '-';
      steps.push('sendIcon=' + (ic ? 'yes' : 'no') + ' handlers=' + handlers.join(' ; ') + ' path=' + svgPath + ' title=' + (ic && (ic.getAttribute('title') || ic.getAttribute('aria-label') || '')));
      // Draft 自己状态读 0 但 DOM 有字：看 onChange 后真正 state 在不在更上层
      const root = ed.closest('.DraftEditor-root'); const rk = Object.keys(root).find(k => k.startsWith('__reactFiber')); let rf = root[rk]; const states = [];
      for (let d = 0; rf && d < 16; d++, rf = rf.return) { const pr = rf.memoizedProps || {}; const st = rf.memoizedState; if (pr.editorState) states.push('p' + d + '=' + JSON.stringify(pr.editorState.getCurrentContent().getPlainText())); if (pr.value !== undefined && typeof pr.value === 'string') states.push('v' + d + '=' + JSON.stringify(pr.value.slice(0, 10))); }
      steps.push('states=' + states.join(','));
      sends3 = [...document.querySelectorAll('div,span,button')].filter(e => e.children.length === 0 && /^(发送|发布)$/.test((e.innerText || '').trim()) && !e.closest('.danmakuInputContainer')).map(e => chain(e));
      setDraft(ed, ''); await sleep(600); ed = editorOf();
      steps.push('clear=' + JSON.stringify(draftText(ed)) + ' dom=' + JSON.stringify((ed.innerText || '').trim()) + ' icons=' + rightIcons(ed));
    }
    typed = steps.join(' || ');
    // 点第一条评论的「回复」，看回复框在哪（不输入）
    const firstItem = document.querySelector('[data-e2e="comment-item"]');
    const rb = firstItem && [...firstItem.querySelectorAll('span,div')].find(e => e.children.length === 0 && (e.innerText || '').trim() === '回复');
    if (rb) {
      rb.click(); await sleep(1200);
      replyEd = [...document.querySelectorAll('.public-DraftEditor-content')].map(e => ({ inItem: !!e.closest('[data-e2e="comment-item"]'), sameItem: firstItem.contains(e), el: chain(e), ph: (e.closest('.DraftEditor-root')?.querySelector('.public-DraftEditorPlaceholder-inner')?.innerText || '').slice(0, 14) }));
    }
    if (document.activeElement && document.activeElement.blur) document.activeElement.blur();
    return JSON.stringify({ path: location.pathname, items: document.querySelectorAll('[data-e2e="comment-item"]').length, items0: 0, before, typed, typedDraft, sends3, icons, cleared, replyEd, rb: !!rb });
    """#

    /// 网页里：（回复时先点那条评论的「回复」）→ 用抖音编辑器自己的接口填字 → 点它自己的发送图标 → 等抖音回执。
    /// 11-19 真机只读探测：评论框是 Draft.js（.comment-input-inner-container .public-DraftEditor-content），
    /// execCommand 会让 Draft 重复插字，必须走它的 editorState/onChange；有字后右侧 .commentInput-right-ct 里的
    /// 发送图标多出一个激活 class 且带 onClick；点「回复」会在那条评论里另起一个「回复@xx」编辑器。
    static let sendJS = #"""
    const sleep = ms => new Promise(r => setTimeout(r, ms));
    const out = (state, stage, extra) => JSON.stringify(Object.assign({ state, stage, status: null, code: null, msg: null, comment: null, diagnostic: null }, extra || {}));
    if (window.__ddComposing) return out('busy', 'busy', { msg: '上一条评论还在发送' });
    window.__ddComposing = true;
    const vis = e => { if (!e) return false; const r = e.getBoundingClientRect(); return r.width > 0 && r.height > 0; };
    const fibers = e => { const k = e && Object.keys(e).find(k => k.startsWith('__reactFiber')); let f = k && e[k]; const l = []; for (let d = 0; f && d < 25; d++, f = f.return) l.push(f.memoizedProps || {}); return l; };
    const cidOf = item => { for (const p of fibers(item)) { const c = p.commentInfo || p.comment; if (c && (c.cid || c.comment_id)) return String(c.cid || c.comment_id); } return ''; };
    const items = () => [...document.querySelectorAll('[data-e2e="comment-item"]')];
    const findItem = cid => items().find(e => cidOf(e) === cid);
    const leaf = (root, re) => [...root.querySelectorAll('span,div,button,p')].find(e => e.children.length === 0 && re.test((e.innerText || '').trim()) && vis(e));
    const draft = ed => { for (const p of fibers(ed.closest('.DraftEditor-root'))) if (p.editorState && typeof p.onChange === 'function') return p; return null; };
    const setText = (ed, t) => { const p = draft(ed); if (!p) return false; const es = p.editorState, ES = es.constructor, CS = es.getCurrentContent().constructor; p.onChange(ES.moveFocusToEnd(ES.push(es, CS.createFromText(t), 'insert-characters'))); return true; };
    const domText = ed => (ed.innerText || '').replace(/\u200b/g, '').trim();
    let resolveAck, started = false, done = false;
    const ack = new Promise(r => { resolveAck = r; });
    const isPublish = u => { try { return /\/aweme\/v1\/web\/comment\/publish/.test(new URL(u, location.href).pathname); } catch (e) { return false; } };
    // 只记「有没有」这几个响应头，不记值：官方网页版靠它们决定要不要弹验证（滑块/短信）再重发
    const hdrFlags = names => { const h = ' ' + String(names || '').toLowerCase() + ' ';
      const has = n => h.includes(' ' + n + ':') || h.includes(' ' + n + ' ') || h.includes('\n' + n + ':');
      return 'vp=' + (has('x-tt-verify-passport-decision') ? 1 : 0) + ' bt=' + (has('bdturing-verify') ? 1 : 0)
        + ' vc=' + (has('x-vc-bdturing-parameters') ? 1 : 0) + ' tg=' + (has('bd-ticket-guard-result') ? 1 : 0)
        + ' tgs=' + (has('bd-ticket-guard-server-data') ? 1 : 0); };
    // 抖音登录凭证校验的结论码（bd-ticket-guard-result / sec-result）：只收短数字，别的记 x
    const code = (raw, name) => { const m = String(raw || '').match(new RegExp('(?:^|\\n)' + name + ':\\s*([^\\r\\n]*)', 'i')); if (!m) return '-'; const v = m[1].trim(); return /^-?\d{1,6}$/.test(v) ? v : 'x'; };
    const capture = (u, http, body, hdr) => { if (!isPublish(u) || done) return; let d = null; try { d = JSON.parse(body); } catch (e) {} done = true;
      resolveAck({ http, d, raw: (body || '').length, hdr: hdrFlags(hdr) + ' tgr=' + code(hdr, 'bd-ticket-guard-result') + ' tgsr=' + code(hdr, 'bd-ticket-guard-sec-result'),
        shark: !!(d && d.data && d.data.shark_decision_conf), signed: /[?&]a_bogus=/.test(String(u || '')) }); };
    // 发出去的评论请求带了哪些头：只记名字（登录凭证签名那几个头 + 常规头），不记值
    let reqHdrs = new Set();
    const noteHdr = n => { n = String(n || '').toLowerCase(); if (/^(bd-ticket-guard-[a-z-]+|x-secsdk-[a-z-]+|x-tt-[a-z-]+|content-type)$/.test(n)) reqHdrs.add(n.replace('bd-ticket-guard-', 'tg:')); };
    const hdrNames = () => [...reqHdrs].sort().join(',') || 'none';
    // 本页的登录凭证密钥状态（只记有没有 + 短哈希，用来比对各后台页是不是同一套）
    const h8 = v => { if (v == null || v === '') return '-'; v = String(v); let h = 0x811c9dc5; for (let i = 0; i < v.length; i++) { h ^= v.charCodeAt(i); h = Math.imul(h, 16777619) >>> 0; } return ('0000000' + h.toString(16)).slice(-8); };
    const keyState = () => { let ls = {}; try { ls = window.localStorage || {}; } catch (e) {}
      const g = k => { try { return ls.getItem ? ls.getItem(k) : null; } catch (e) { return null; } };
      const ck = n => { const m = (document.cookie || '').match(new RegExp('(?:^|;\\s*)' + n + '=([^;]*)')); return m ? m[1] : null; };
      const crypt = g('security-sdk/s_sdk_crypt_sdk'), cert = g('security-sdk/s_sdk_cert_key'), sign = g('security-sdk/s_sdk_sign_data_key/web_protect');
      return 'keys=' + (crypt ? 1 : 0) + (cert ? 1 : 0) + (sign ? 1 : 0) + ' kh=' + h8(crypt) + ' ch=' + h8(ck('bd_ticket_guard_client_data')) + ' wd=' + (ck('bd_ticket_guard_client_web_domain') ? 1 : 0); };
    // 页面上有没有弹出验证框（只看有没有，不读内容）
    const captchaShown = () => !!document.querySelector('iframe[src*="verify"], [id*="captcha"], [class*="captcha"], [class*="second-verify"], [class*="verify-bar"], [id*="verify-bar"]');
    const P = XMLHttpRequest.prototype, oldOpen = P.open, oldSend = P.send, oldSetHdr = P.setRequestHeader, oldFetch = window.fetch;
    function wOpen(m, u, ...a) { this.__ddUrl = u; return oldOpen.call(this, m, u, ...a); }
    function wSetHdr(n, v) { if (isPublish(this.__ddUrl)) noteHdr(n); return oldSetHdr.call(this, n, v); }
    function wSend(...a) { if (isPublish(this.__ddUrl)) { started = true; this.addEventListener('loadend', () => { let body = ''; try { body = (this.responseType === '' || this.responseType === 'text') ? this.responseText : (this.responseType === 'json' ? JSON.stringify(this.response) : ''); } catch (e) {} let names = ''; try { names = '\n' + (this.getAllResponseHeaders() || ''); } catch (e) {} capture(this.responseURL || this.__ddUrl, this.status, body, names); }, { once: true }); } return oldSend.apply(this, a); }
    async function wFetch(input, ...a) { const u = typeof input === 'string' ? input : (input && input.url); if (isPublish(u)) { started = true;
      try { const hs = [input && input.headers, a[0] && a[0].headers]; for (const h of hs) { if (!h) continue; if (typeof h.forEach === 'function' && !Array.isArray(h)) h.forEach((v, k) => noteHdr(k)); else if (Array.isArray(h)) h.forEach(p => noteHdr(p[0])); else Object.keys(h).forEach(noteHdr); } } catch (e) {} } const r = await oldFetch.call(this, input, ...a); if (isPublish(u)) { try { let names = ''; try { r.headers.forEach((v, k) => { names += '\n' + k + ':' + (/^bd-ticket-guard-(sec-)?result$/i.test(k) ? ' ' + v : ''); }); } catch (e) {} capture(u, r.status, await r.clone().text(), names); } catch (e) {} } return r; }
    let ed = null;
    try {
      // 1. 评论区
      for (let i = 0; i < 60 && !document.querySelector('[data-e2e="comment-list"]'); i++) await sleep(250);
      if (!document.querySelector('[data-e2e="comment-list"]')) return out('not-ready', 'comment-list', { msg: '网页评论区没加载出来' });
      if (leaf(document, /^登录后即可参与互动讨论$/)) return out('logged-out', 'login-cover', { msg: '网页显示未登录' });
      // 2. 回复：在评论区找到那条，点它的「回复」，用它下面新出来的编辑器
      if (target) {
        const expand = async () => { const head = top && top !== target && findItem(top); const more = head && leaf(head, /^展开\d+条回复$|^展开更多$/); if (more) { more.click(); for (let i = 0; i < 12 && !findItem(target); i++) await sleep(250); } };
        let item = findItem(target);
        if (!item) await expand();
        for (let n = 0; !(item = findItem(target)) && n < 8; n++) {
          const last = items().pop();
          if (last) last.scrollIntoView({ block: 'end' });
          await sleep(800);
          if (!findItem(target)) await expand();
        }
        if (!item) return out('not-found', 'reply-target', { msg: '网页评论区里没找到要回复的那条' });
        item.scrollIntoView({ block: 'center' });
        // 「回复」那格里有图标（children 不为 0），并且只在鼠标悬停时才显出来；取最里层、本条自己的（不是楼中楼的）
        const own = e => e.closest('[data-e2e="comment-item"]') === item;
        const cands = [...item.querySelectorAll('span,div,button,p')].filter(e => own(e) && (e.innerText || e.textContent || '').trim() === '回复');
        const btn = cands.find(e => ![...e.querySelectorAll('span,div,button,p')].some(c => (c.innerText || c.textContent || '').trim() === '回复')) || null;
        if (!btn) return out('not-found', 'reply-button', { msg: '那条评论没有「回复」' });
        btn.click();
        for (let i = 0; i < 16 && !ed; i++) { await sleep(200); ed = [...item.querySelectorAll('.public-DraftEditor-content')].find(e => e.closest('[data-e2e="comment-item"]') === item || vis(e)) || null; }
      } else {
        const holder = document.querySelector('.comment-input-inner-container');
        if (holder && !holder.closest('[data-e2e="comment-item"]')) holder.click();
        for (let i = 0; i < 16 && !ed; i++) { await sleep(200); ed = [...document.querySelectorAll('.comment-input-inner-container .public-DraftEditor-content')].find(e => vis(e) && !e.closest('[data-e2e="comment-item"]')) || null; }
      }
      if (!ed) return out('not-ready', 'editor', { msg: '网页评论框没找到' });
      // 3. 填字（Draft 自己的接口），核对 DOM 里确实是这段字
      ed.focus();
      if (!setText(ed, text)) return out('compose-error', 'draft', { msg: '网页评论框不接受输入' });
      await sleep(500);
      if (domText(ed) !== text.trim()) { setText(ed, ''); return out('compose-error', 'verify-text', { msg: '网页评论框里的字和要发的不一致' }); }
      // 4. 它自己的发送图标：编辑器所在输入条右侧，有 onClick 的那个
      const bar = ed.closest('.comment-input-inner-container');
      const right = bar && (bar.querySelector('.commentInput-right-ct') || bar.parentElement.querySelector('.commentInput-right-ct'));
      const clickable = e => { const k = Object.keys(e).find(k => k.startsWith('__reactProps')); return !!(k && e[k] && typeof e[k].onClick === 'function'); };
      const icons = right ? [...right.querySelectorAll('span,div')].filter(e => vis(e) && clickable(e)) : [];
      const send = icons.length ? icons[icons.length - 1] : null;
      if (!send) { setText(ed, ''); return out('not-ready', 'send-button', { msg: '网页上没找到发送按钮' }); }
      const ks0 = keyState();
      P.open = wOpen; P.send = wSend; P.setRequestHeader = wSetHdr; window.fetch = wFetch;
      const t0 = Date.now();
      send.click();
      const r = await Promise.race([ack, sleep(12000).then(() => null)]);
      if (!r) {
        if (!started) { setText(ed, ''); return out('not-sent', 'no-request', { msg: '点了网页发送但没有发出请求', diagnostic: 'icons=' + icons.length }); }
        return out('unconfirmed', 'ack-timeout', { msg: '已点发送，但没等到抖音回执；可能已发出，先刷新评论区核对' });
      }
      const d = r.d || {}, c = d.comment;
      // 空回执时多等一下，看页面有没有自己弹出验证框
      let cap = captchaShown();
      if (!cap && !c) { await sleep(1500); cap = captchaShown(); }
      const ks1 = keyState();
      const diag = 'via=web-ui ms=' + (Date.now() - t0) + ' http=' + r.http + ' chars=' + r.raw + ' ' + r.hdr + ' shark=' + (r.shark ? 1 : 0) + ' cap=' + (cap ? 1 : 0)
        + ' signed=' + (r.signed ? 1 : 0) + ' reqHdrs=' + hdrNames() + ' ' + ks0 + (ks1 !== ks0 ? ' after:' + ks1.replace(/ /g, '/') : '')
        + ' code=' + String(d.status_code ?? '-') + ' got=' + (c ? String(c.reply_id ?? '-') + '/' + String(c.reply_to_reply_id ?? '-') + ' st=' + String(c.status ?? '-') : '-');
      const id = c ? (typeof c.cid === 'string' ? c.cid : (c.cid_str || (Number.isSafeInteger(c.cid) ? String(c.cid) : ''))) : '';
      const comment = c && id ? { id, text: c.text || text, name: (c.user && c.user.nickname) || '', avatar: null, sec: (c.user && c.user.sec_uid) || null,
        digg: 0, time: c.create_time || Math.floor(Date.now() / 1000), replies: 0, ip: c.ip_label || null,
        parent: c.reply_id && String(c.reply_id) !== '0' ? String(c.reply_id) : null,
        replyTo: c.reply_to_reply_id && String(c.reply_to_reply_id) !== '0' ? String(c.reply_to_reply_id) : null } : null;
      if (r.http === 200 && d.status_code === 0 && comment) return out('sent', 'ack', { status: 200, code: 0, comment, diagnostic: diag });
      return out(r.http === 403 ? 'blocked' : (typeof d.status_code === 'number' ? 'rejected' : 'unconfirmed'), 'ack', { status: r.http, code: d.status_code ?? null, msg: d.status_msg || null, diagnostic: diag });
    } catch (e) {
      return out(started ? 'unconfirmed' : 'compose-error', 'exception', { msg: started ? '已点发送，结果未知' : '网页评论框出错', diagnostic: String(e && e.name) });
    } finally {
      if (P.open === wOpen) P.open = oldOpen;
      if (P.send === wSend) P.send = oldSend;
      if (P.setRequestHeader === wSetHdr) P.setRequestHeader = oldSetHdr;
      if (window.fetch === wFetch) window.fetch = oldFetch;
      window.__ddComposing = false;
    }
    """#
}
