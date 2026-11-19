import Foundation
import WebKit

/// 登录凭证密钥一致性探针（老板 2026-11-19：评论 403 后被强制退出）。
///
/// 抖音网页登录后，安全 SDK 在本页 localStorage 存一套密钥（security-sdk/s_sdk_crypt_sdk 等），
/// 写接口（评论）用它签名；服务器认定签名与登录不匹配时 403 并作废登录。
/// DouDuo 有好几个后台网页共用同一份登录（签名页、网页评论框、私信页、直播评论、转发页），
/// 这里在每个页面开页后记一次：密钥有没有、短哈希、UA 是不是同一个，用来比对是不是同一套。
/// 只记有无与 8 位哈希，不记密钥、cookie、令牌原文。日志前缀 DDKEYS。
enum DYKeyStateProbe {
    static let handlerName = "ddKeyState"
    /// App 启动时接到 ddlog（DYLiveModel.log）；单元测试目标里没有 DYLiveModel，默认丢弃
    nonisolated(unsafe) static var log: (String) -> Void = { _ in }

    static func script(tag: String) -> String {
        #"""
        (() => {
          if (window.__ddKeyProbe) return; window.__ddKeyProbe = 1;
          const tag = "\#(tag)";
          const h8 = v => { if (v == null || v === '') return '-'; v = String(v); let h = 0x811c9dc5; for (let i = 0; i < v.length; i++) { h ^= v.charCodeAt(i); h = Math.imul(h, 16777619) >>> 0; } return ('0000000' + h.toString(16)).slice(-8); };
          const snap = when => { try {
            let ls = null; try { ls = window.localStorage; } catch (e) {}
            const g = k => { try { return ls ? ls.getItem(k) : null; } catch (e) { return null; } };
            const ck = n => { const m = (document.cookie || '').match(new RegExp('(?:^|;\\s*)' + n + '=([^;]*)')); return m ? m[1] : null; };
            const crypt = g('security-sdk/s_sdk_crypt_sdk'), cert = g('security-sdk/s_sdk_cert_key'), sign = g('security-sdk/s_sdk_sign_data_key/web_protect');
            const n = ls ? Object.keys(ls).filter(k => k.startsWith('security-sdk/')).length : -1;
            const s = 'tag=' + tag + ' when=' + when + ' host=' + location.host + ' path=' + location.pathname.replace(/\d{6,}/g, '#').slice(0, 40)
              + ' keys=' + (crypt ? 1 : 0) + (cert ? 1 : 0) + (sign ? 1 : 0) + ' sdkN=' + n + ' kh=' + h8(crypt) + ' certh=' + h8(cert) + ' signh=' + h8(sign)
              + ' ch=' + h8(ck('bd_ticket_guard_client_data')) + ' wd=' + (ck('bd_ticket_guard_client_web_domain') ? 1 : 0)
              + ' ua=' + h8(navigator.userAgent) + ' sess=' + (/(?:^|;\s*)sessionid_ss=/.test(document.cookie || '') ? 1 : 0);
            window.webkit.messageHandlers.ddKeyState.postMessage(s);
          } catch (e) {} };
          const go = () => { setTimeout(() => snap('t3'), 3000); setTimeout(() => snap('t15'), 15000); };
          if (document.readyState === 'complete') go(); else window.addEventListener('load', go, { once: true });
        })();
        """#
    }

    /// 只在 DEBUG 包挂。同一个 userContentController 只挂一次处理器。
    @MainActor static func install(in cfg: WKWebViewConfiguration, tag: String) {
        #if DEBUG
        cfg.userContentController.addUserScript(WKUserScript(source: script(tag: tag), injectionTime: .atDocumentEnd, forMainFrameOnly: true))
        cfg.userContentController.add(Handler(), name: handlerName)
        #endif
    }

    final class Handler: NSObject, WKScriptMessageHandler {
        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            guard let s = message.body as? String, s.count < 600, s.hasPrefix("tag=") else { return }
            DYKeyStateProbe.log("DDKEYS " + s)
        }
    }
}
