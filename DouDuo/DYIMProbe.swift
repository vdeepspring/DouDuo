import Foundation
import WebKit

/// 私信网页只读诊断（仅 DEBUG 包）：观察官方网页私信的数据从哪来、消息带不带 ID 和发送状态。
///
/// 只观察，不改网页行为、不调用任何写接口、不点任何按钮：
/// - WebSocket：包一层构造函数只挂监听，记录地址（去掉查询串）、开关/错误码、收发帧数与字节数。
/// - HTTP：只读 PerformanceObserver 的资源条目，记录路径（去查询串、长数字打码）、耗时与状态。
/// - 消息：从聊天气泡的 React props 读 message 对象的字段名、字段类型、状态值，ID 只记长度和哈希。
/// 不记录正文、昵称、头像、cookie、token、完整 URL 或原始 ID；日志写 ddlog.txt，前缀 DDIMPROBE。
enum DYIMProbe {
    static let handlerName = "ddIMDiag"
    static let maxBody = 1800

    static var enabled: Bool {
        #if DEBUG
        return true
        #else
        return false
        #endif
    }

    static func install(in cfg: WKWebViewConfiguration) {
        guard enabled else { return }
        cfg.userContentController.addUserScript(
            WKUserScript(source: script, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        cfg.userContentController.add(Handler(), name: handlerName)
    }

    final class Handler: NSObject, WKScriptMessageHandler {
        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            guard let body = message.body as? String, !body.isEmpty else { return }
            // 只接受短 JSON；超长直接丢，不在设备上做切片（emoji 边界会断言崩溃）
            guard body.utf8.count <= DYIMProbe.maxBody, body.hasPrefix("{") else { return }
            DYLiveModel.log("DDIMPROBE " + body)
        }
    }

    static let script = #"""
(() => {
  if (window.__ddIMProbe) return; window.__ddIMProbe = 1;
  // 单条上限 1600 字符：超长就只报字段名清单的截断版，原生侧另有 1800 上限兜底
  const post = o => { try {
    let s = JSON.stringify(o);
    if (s.length > 1600) s = JSON.stringify({ k: o.k, truncated: s.length, head: Object.keys(o.fields || o.st || o.to || o).slice(0, 40).join(',').slice(0, 900) });
    window.webkit.messageHandlers.ddIMDiag.postMessage(s);
  } catch (e) {} };
  const onChat = () => /^\/chat\/?$/.test(location.pathname);
  const hash = s => { s = String(s); let h = 0x811c9dc5; for (let i = 0; i < s.length; i++) { h ^= s.charCodeAt(i); h = Math.imul(h, 16777619) >>> 0; } return h.toString(16).padStart(8, '0').slice(0, 6); };
  const cleanPath = u => { try { const x = new URL(u, location.href); return x.host + x.pathname.replace(/\d{6,}/g, '#').slice(0, 90); } catch (e) { return 'bad-url'; } };
  const t0 = Date.now(), ms = () => Date.now() - t0;
  post({ k: 'boot', path: location.pathname, ua: /Macintosh/.test(navigator.userAgent) ? 'mac' : 'other' });

  // ---- WebSocket：只挂监听，不改收发 ----
  const NativeWS = window.WebSocket;
  const sockets = [];
  if (typeof NativeWS === 'function') {
    const Wrapped = function (url, protocols) {
      // 保留子类化（class X extends WebSocket）语义：按调用方的 new.target 构造原生实例
      const ws = Reflect.construct(NativeWS, protocols === undefined ? [url] : [url, protocols], new.target && new.target !== Wrapped ? new.target : NativeWS);
      const rec = { n: sockets.length + 1, path: cleanPath(url), inN: 0, inB: 0, outN: 0, outB: 0, bin: 0, txt: 0, keys: {}, opened: 0, logged: '' };
      sockets.push(rec);
      post({ k: 'ws-new', n: rec.n, path: rec.path, t: ms() });
      const size = d => typeof d === 'string' ? d.length : d && (d.byteLength || d.size) || 0;
      ws.addEventListener('open', () => { rec.opened = ms(); post({ k: 'ws-open', n: rec.n, t: ms(), proto: ws.protocol || '', type: ws.binaryType }); });
      ws.addEventListener('close', ev => post({ k: 'ws-close', n: rec.n, t: ms(), code: ev.code, clean: ev.wasClean ? 1 : 0, reasonLen: (ev.reason || '').length, life: rec.opened ? ms() - rec.opened : -1, inN: rec.inN, outN: rec.outN }));
      ws.addEventListener('error', () => post({ k: 'ws-error', n: rec.n, t: ms(), state: ws.readyState }));
      ws.addEventListener('message', ev => {
        rec.inN++; rec.inB += size(ev.data);
        if (typeof ev.data === 'string') {
          rec.txt++;
          try { const j = JSON.parse(ev.data); if (j && typeof j === 'object') Object.keys(j).slice(0, 12).forEach(k => rec.keys[k] = 1); } catch (e) {}
        } else rec.bin++;
      });
      const send = ws.send;
      ws.send = function (d) { rec.outN++; rec.outB += size(d); return send.apply(this, arguments); };
      return ws;
    };
    Wrapped.prototype = NativeWS.prototype;
    for (const k of ['CONNECTING', 'OPEN', 'CLOSING', 'CLOSED']) Wrapped[k] = NativeWS[k];
    try { window.WebSocket = Wrapped; } catch (e) { post({ k: 'ws-wrap-fail' }); }
  }

  // ---- HTTP：只读 Performance 条目 ----
  const httpSeen = new Map();
  const skip = /\.(js|css|png|jpe?g|webp|gif|svg|woff2?|ttf|mp4|m3u8|ico|heic|avif)(\?|$)/i;
  try {
    new PerformanceObserver(list => {
      for (const e of list.getEntries()) {
        if (!/^(xmlhttprequest|fetch|beacon|other)$/.test(e.initiatorType) || skip.test(e.name)) continue;
        const p = cleanPath(e.name);
        const r = httpSeen.get(p) || { n: 0, bad: 0, maxMs: 0, bytes: 0 };
        r.n++; r.maxMs = Math.max(r.maxMs, Math.round(e.duration)); r.bytes += e.transferSize || 0;
        const st = typeof e.responseStatus === 'number' ? e.responseStatus : -1;
        if (st >= 400 || st === 0) r.bad++;
        const first = !httpSeen.has(p);
        httpSeen.set(p, r);
        if (first || st >= 400) post({ k: 'http', path: p, init: e.initiatorType, st, ms: Math.round(e.duration), size: e.transferSize || 0, t: ms() });
      }
    }).observe({ type: 'resource', buffered: true });
  } catch (e) { post({ k: 'perf-fail', err: String(e && e.message).slice(0, 80) }); }

  // ---- 消息对象形状：读 React props，只记字段名/类型/状态值 ----
  const kind = v => v === null ? 'null' : Array.isArray(v) ? 'arr' : typeof v;
  const messageOf = el => {
    const seen = new Set();
    for (let n = el, d = 0; n && d < 8; n = n.parentElement, d++) {
      for (const k of Object.keys(n)) {
        if (k.startsWith('__reactProps') && n[k] && n[k].message && typeof n[k].message === 'object') return n[k].message;
        if (!k.startsWith('__reactFiber')) continue;
        for (let f = n[k], depth = 0; f && depth < 24 && !seen.has(f); f = f.return, depth++) {
          seen.add(f);
          const m = f.memoizedProps && f.memoizedProps.message;
          if (m && typeof m === 'object') return m;
        }
      }
    }
    return null;
  };
  const statusKeys = k => /status|state|sending|fail|ack|read|recall|deliver/i.test(k);
  const idKeys = k => /(^id$|Id$|_id$|ID$|index|order|seq|cursor)/.test(k);
  const timeKeys = k => /time|At$|date|stamp/i.test(k);
  const prevState = new Map();
  let shapeLogged = false, lastConv = '', snapN = 0, convSnaps = 0;
  const snapshot = () => {
    if (!onChat() || document.visibilityState !== 'visible') return;
    const bubbles = [...document.querySelectorAll('[data-e2e="msg-item-content"]')];
    if (!bubbles.length) return;
    const msgs = [];
    for (const b of bubbles.slice(-40)) { const m = messageOf(b); if (m) msgs.push(m); }
    snapN++;
    const conv = msgs.length && (msgs[0].conversationId || msgs[0].conversationShortId) ? hash(msgs[0].conversationId || msgs[0].conversationShortId) : '-';
    if (!shapeLogged && msgs.length) {
      shapeLogged = true;
      const keyCount = {};
      msgs.forEach(m => Object.keys(m).forEach(k => keyCount[k] = (keyCount[k] || 0) + 1));
      const keys = Object.keys(keyCount).sort();
      post({ k: 'msg-keys', bubbles: bubbles.length, found: msgs.length, keys: keys.slice(0, 90).join(',') });
      const m = msgs[msgs.length - 1];
      const typed = {};
      for (const k of keys) {
        if (Object.keys(typed).length >= 30) break;
        if (!(idKeys(k) || statusKeys(k) || timeKeys(k) || /sender|from|self|conversation|type|ext/i.test(k))) continue;
        const v = m[k];
        typed[k] = kind(v) + (typeof v === 'string' ? ':len' + v.length + (/^\d+$/.test(v) ? ':num' : '') : '')
          + ((typeof v === 'number' || typeof v === 'boolean') && (statusKeys(k) || /type/i.test(k)) ? ':=' + v : '');
      }
      post({ k: 'msg-fields', fields: typed });
      if (m.ext && typeof m.ext === 'object') post({ k: 'msg-ext-keys', keys: Object.keys(m.ext).slice(0, 60).join(',') });
    }
    if (conv !== lastConv) { lastConv = conv; convSnaps = 0; post({ k: 'conv', conv, found: msgs.length, bubbles: bubbles.length, snap: snapN }); }
    convSnaps++;
    // 发送状态跟踪：每条消息的 (稳定ID, 状态字段) 变化才记
    for (const m of msgs) {
      // 本地 clientId 在发送前就有、确认后不变；serverId 确认后才出现。按 clientId 优先做稳定键
      const idv = m.clientId || m.uuid || m.id || m.serverId;
      const key = idv ? hash(idv) : '';
      if (!key) continue;
      const st = {};
      for (const k of Object.keys(m)) {
        if (Object.keys(st).length >= 12) break;
        const v = m[k];
        if (statusKeys(k) && (typeof v === 'number' || typeof v === 'boolean' || (typeof v === 'string' && v.length < 16))) st[k] = v;
      }
      st.hasServer = m.serverId ? 1 : 0;
      st.hasClient = m.clientId ? 1 : 0;
      const sig = JSON.stringify(st);
      const old = prevState.get(key);
      if (old !== sig) {
        prevState.set(key, sig);
        if (old !== undefined) post({ k: 'msg-change', id: key, from: JSON.parse(old), to: st, t: ms() });
        else if (convSnaps > 2) post({ k: 'msg-new', id: key, st, mine: m.isFromMe === true || m.fromMe === true ? 1 : 0, t: ms() });
      }
    }
  };
  setInterval(() => { try { snapshot(); } catch (e) { post({ k: 'snap-err', err: String(e && e.message).slice(0, 120) }); } }, 1000);

  // ---- 周期摘要：每 30 秒一次，有变化才发 ----
  // 拆成多条短消息，避免单条超过原生侧长度上限被丢弃
  const lastSummary = new Map();
  const postIfChanged = (key, o) => { const s = JSON.stringify(o); if (lastSummary.get(key) !== s) { lastSummary.set(key, s); post(o); } };
  setInterval(() => {
    for (const r of sockets.slice(-6)) postIfChanged('ws' + r.n, { k: 'sum-ws', n: r.n, path: r.path, inN: r.inN, inB: r.inB, outN: r.outN, outB: r.outB, bin: r.bin, txt: r.txt, keys: Object.keys(r.keys).slice(0, 12).join(',') });
    const http = [...httpSeen.entries()].sort((a, b) => b[1].n - a[1].n).slice(0, 10).map(([p, r]) => p.slice(0, 80) + ' n' + r.n + ' bad' + r.bad + ' max' + r.maxMs);
    postIfChanged('http', { k: 'sum-http', vis: document.visibilityState, path: location.pathname, http });
  }, 30000);
  document.addEventListener('visibilitychange', () => post({ k: 'vis', v: document.visibilityState, t: ms() }));
  window.addEventListener('online', () => post({ k: 'net', v: 'online', t: ms() }));
  window.addEventListener('offline', () => post({ k: 'net', v: 'offline', t: ms() }));
})();
"""#
}
