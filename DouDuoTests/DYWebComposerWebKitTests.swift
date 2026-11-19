import XCTest
import WebKit

/// 在模拟器真 WebKit 里跑 App 的网页评论脚本（DYWebComposer.sendJS 原文），
/// 评论接口由本地 scheme handler 应答：真 XHR / 真 fetch / 真响应头，不连抖音。
@MainActor
final class DYWebComposerWebKitTests: XCTestCase {
    final class Handler: NSObject, WKURLSchemeHandler {
        var status = 200, body = "", headers: [String: String] = [:], hits = 0
        func webView(_ webView: WKWebView, start task: WKURLSchemeTask) {
            let url = task.request.url!
            if url.path.hasPrefix("/aweme/v1/web/comment/publish") {
                hits += 1
                var h = headers; h["Content-Type"] = "application/json"; h["Access-Control-Expose-Headers"] = "*"
                task.didReceive(HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: h)!)
                task.didReceive(Data(body.utf8))
            } else {
                task.didReceive(HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "text/html; charset=utf-8"])!)
                task.didReceive(Data(Self.page.utf8))
            }
            task.didFinish()
        }
        func webView(_ webView: WKWebView, stop task: WKURLSchemeTask) {}

        /// 仿抖音网页评论区：Draft 编辑器 + 右侧发送图标；发送图标点下去用 XHR 或 fetch 调评论接口
        static let page = """
        <!doctype html><meta charset=utf-8><body><div data-e2e="comment-list"></div><script>
        const d = document, el = (t, c, x) => { const e = d.createElement(t); if (c) e.className = c; if (x != null) e.textContent = x; return e; };
        const bar = el('div', 'comment-input-inner-container'), root = el('div', 'DraftEditor-root'), ed = el('div', 'public-DraftEditor-content');
        ed.setAttribute('contenteditable', 'true'); root.appendChild(ed); bar.appendChild(root);
        class CS { constructor(t) { this.t = t; } getPlainText() { return this.t; } static createFromText(t) { return new CS(t); } }
        class ES { constructor(c) { this.c = c; } getCurrentContent() { return this.c; } static push(es, c) { return new ES(c); } static moveFocusToEnd(es) { return es; } }
        const props = { editorState: new ES(new CS('')), onChange(n) { props.editorState = n; ed.textContent = n.getCurrentContent().getPlainText(); } };
        root.__reactFiberT = { memoizedProps: props, return: null };
        const right = el('div', 'commentInput-right-ct');
        for (const n of ['at', 'emoji', 'send']) { const s = el('span', n, n === 'send' ? '发' : '·'); s.__reactPropsT = { onClick() {} };
          s.addEventListener('click', () => { if (n !== 'send') return; const u = '/aweme/v1/web/comment/publish?app_name=aweme';
            if (window.__ddViaXHR) { const x = new XMLHttpRequest(); x.open('POST', u); x.setRequestHeader('Content-Type', 'application/x-www-form-urlencoded'); x.send('aweme_id=1&text=x'); }
            else fetch(u, { method: 'POST', body: 'aweme_id=1&text=x' });
            if (window.__ddCaptcha) setTimeout(() => d.body.appendChild(el('div', 'captcha_verify_container', '验证')), 200); });
          right.appendChild(s); }
        bar.appendChild(right); d.body.appendChild(bar);
        </script>
        """
    }

    static let sendJS: String = {
        let src = try! String(contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("DouDuo/DYWebComposer.swift"), encoding: .utf8)
        let start = src.range(of: "static let sendJS = #\"\"\"\n")!.upperBound
        let end = src.range(of: "\n    \"\"\"#", range: start..<src.endIndex)!.lowerBound
        return String(src[start..<end])
    }()

    private func run(xhr: Bool, captcha: Bool = false, status: Int = 200, body: String = "", headers: [String: String] = [:]) async throws -> (out: [String: Any], hits: Int) {
        let h = Handler(); h.status = status; h.body = body; h.headers = headers
        let cfg = WKWebViewConfiguration(); cfg.setURLSchemeHandler(h, forURLScheme: "ddtest")
        let w = WKWebView(frame: CGRect(x: 0, y: 0, width: 800, height: 600), configuration: cfg)
        let win = UIWindow(frame: w.frame); win.addSubview(w); win.isHidden = false
        w.load(URLRequest(url: URL(string: "ddtest://www.douyin.com/video/1")!))
        for _ in 0..<100 { if (try? await w.evaluateJavaScript("!!document.querySelector('.commentInput-right-ct')")) as? Bool == true { break }; try await Task.sleep(nanoseconds: 50_000_000) }
        _ = try await w.evaluateJavaScript("window.__ddViaXHR = \(xhr); window.__ddCaptcha = \(captcha); 1")
        let r = try await w.callAsyncJavaScript(Self.sendJS, arguments: ["text": "模拟器测试", "top": "", "target": ""], contentWorld: .page)
        let s = try XCTUnwrap(r as? String)
        let restored = try await w.evaluateJavaScript("XMLHttpRequest.prototype.send.toString().includes('native code') && fetch.toString().includes('native code')") as? Bool
        XCTAssertEqual(restored, true, "发完要把 XHR / fetch 还原")
        return (try XCTUnwrap(JSONSerialization.jsonObject(with: Data(s.utf8)) as? [String: Any]), h.hits)
    }

    func testXHRVerifyHeaderLoggedAsFlagOnly() async throws {
        let r = try await run(xhr: true, headers: ["x-tt-verify-passport-decision": "{\"k\":\"LEAK_ME\"}", "x-tt-logid": "L1"])
        let diag = try XCTUnwrap(r.out["diagnostic"] as? String); print("SIMPROBE xhr-vp", r.out["state"]!, diag)
        XCTAssertEqual(r.hits, 1); XCTAssertNotEqual(r.out["state"] as? String, "sent")
        XCTAssertTrue(diag.contains("vp=1 bt=0 vc=0"), diag); XCTAssertTrue(diag.contains("chars=0"), diag); XCTAssertFalse(diag.contains("LEAK_ME"))
    }

    func testFetchBdturingHeaderLogged() async throws {
        let r = try await run(xhr: false, headers: ["bdturing-verify": "VAL_LEAK"])
        let diag = try XCTUnwrap(r.out["diagnostic"] as? String); print("SIMPROBE fetch-bt", r.out["state"]!, diag)
        XCTAssertEqual(r.hits, 1); XCTAssertNotEqual(r.out["state"] as? String, "sent")
        XCTAssertTrue(diag.contains("vp=0 bt=1"), diag); XCTAssertFalse(diag.contains("VAL_LEAK"))
    }

    func testCaptchaBoxDetected() async throws {
        let r = try await run(xhr: true, captcha: true)
        let diag = try XCTUnwrap(r.out["diagnostic"] as? String); print("SIMPROBE captcha", r.out["state"]!, diag)
        XCTAssertTrue(diag.contains("cap=1"), diag); XCTAssertNotEqual(r.out["state"] as? String, "sent")
    }

    func testTicketGuardHeadersAndSuccessStatus() async throws {
        let ok = #"{"status_code":0,"comment":{"cid":"c9","text":"x","status":7,"reply_id":"0","reply_to_reply_id":"0"}}"#
        let r = try await run(xhr: true, body: ok, headers: ["bd-ticket-guard-result": "0", "bd-ticket-guard-server-data": "SRV_LEAK"])
        let diag = try XCTUnwrap(r.out["diagnostic"] as? String); print("SIMPROBE ok-tg", r.out["state"]!, diag)
        XCTAssertEqual(r.out["state"] as? String, "sent")
        XCTAssertTrue(diag.contains("vp=0 bt=0 vc=0 tg=1 tgs=1 tgr=0 tgsr=- shark=0 cap=0"), diag); XCTAssertTrue(diag.contains("code=0 got=0/0 st=7"), diag); XCTAssertFalse(diag.contains("SRV_LEAK"))
    }

    func test403TicketGuardCodeAndSignedHeaderNames() async throws {
        let r = try await run(xhr: true, status: 403, headers: ["bd-ticket-guard-result": "1003", "bd-ticket-guard-sec-result": "SEC_LEAK"])
        let diag = try XCTUnwrap(r.out["diagnostic"] as? String); print("SIMPROBE 403-tg", r.out["state"]!, diag)
        XCTAssertEqual(r.out["state"] as? String, "blocked")
        XCTAssertTrue(diag.contains("tg=1 tgs=0 tgr=1003 tgsr=x"), diag); XCTAssertFalse(diag.contains("SEC_LEAK"))
        XCTAssertTrue(diag.contains("reqHdrs=content-type"), diag)
    }

    func testFetch403TicketGuardCode() async throws {
        let r = try await run(xhr: false, status: 403, headers: ["bd-ticket-guard-result": "1003"])
        let diag = try XCTUnwrap(r.out["diagnostic"] as? String); print("SIMPROBE fetch-403", r.out["state"]!, diag)
        XCTAssertTrue(diag.contains("tgr=1003"), diag)
    }

    func testKeyStateProbeHashesOnly() async throws {
        let h = Handler()
        let cfg = WKWebViewConfiguration(); cfg.setURLSchemeHandler(h, forURLScheme: "ddtest")
        final class Sink: NSObject, WKScriptMessageHandler { var got: [String] = []
            func userContentController(_ u: WKUserContentController, didReceive m: WKScriptMessage) { if let s = m.body as? String { got.append(s) } } }
        let sink = Sink()
        cfg.userContentController.addUserScript(WKUserScript(source: "localStorage.setItem('security-sdk/s_sdk_crypt_sdk','PRIV_MATERIAL');localStorage.setItem('security-sdk/s_sdk_cert_key','CERT_MATERIAL');",
                                                             injectionTime: .atDocumentStart, forMainFrameOnly: true))
        cfg.userContentController.addUserScript(WKUserScript(source: DYKeyStateProbe.script(tag: "unit"), injectionTime: .atDocumentEnd, forMainFrameOnly: true))
        cfg.userContentController.add(sink, name: DYKeyStateProbe.handlerName)
        let w = WKWebView(frame: CGRect(x: 0, y: 0, width: 400, height: 300), configuration: cfg)
        let win = UIWindow(frame: w.frame); win.addSubview(w); win.isHidden = false
        w.load(URLRequest(url: URL(string: "ddtest://www.douyin.com/video/1")!))
        for _ in 0..<120 where sink.got.isEmpty { try await Task.sleep(nanoseconds: 50_000_000) }
        let s = try XCTUnwrap(sink.got.first); print("SIMPROBE keys", s)
        XCTAssertTrue(s.hasPrefix("tag=unit when=t3 host=www.douyin.com"), s)
        XCTAssertTrue(s.contains("keys=110 sdkN=2"), s)
        XCTAssertNotNil(s.range(of: #"kh=[0-9a-f]{8} certh=[0-9a-f]{8} signh=-"#, options: .regularExpression), s)
        XCTAssertFalse(s.contains("MATERIAL"))
    }

    func testPlainSuccessAllZero() async throws {
        let ok = #"{"status_code":0,"comment":{"cid":"c1","text":"x","status":1,"reply_id":"0","reply_to_reply_id":"0"}}"#
        let r = try await run(xhr: false, body: ok)
        let diag = try XCTUnwrap(r.out["diagnostic"] as? String); print("SIMPROBE ok", r.out["state"]!, diag)
        XCTAssertEqual(r.out["state"] as? String, "sent")
        XCTAssertTrue(diag.contains("vp=0 bt=0 vc=0 tg=0 tgs=0 tgr=- tgsr=- shark=0 cap=0"), diag)
    }
}
