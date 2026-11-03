import Foundation
import UIKit
import WebKit

/**
 * When Waze turns Kite's plain requests away, ask from inside the real live map page instead.
 * Since 2026 Waze guards its feed with Google reCAPTCHA: the live map page runs a check in the
 * background and gets a pass (the "recaptcha-ca-t" cookie), and only requests carrying it get
 * reports. So a web view, tucked out of sight behind the map, opens waze.com/live-map, waits for
 * the pass, and fetches the feed from there, copying any extra headers the page itself sends.
 */
@MainActor
final class WazeWeb: NSObject, WKNavigationDelegate {
    static let shared = WazeWeb()

    private var web: WKWebView?
    private var ready = false
    private var waiting: [CheckedContinuation<Void, Never>] = []
    /** What happened last time, for the screenshot run's status line. */
    private(set) var note = "page: not tried"

    static func install() {
        Waze.fallback = { url in await WazeWeb.shared.fetch(url) }
    }

    /**
     * Watches the page's own requests for the feed: which headers it adds and how Waze answered,
     * so Kite can ask the same way.
     */
    private static let watcher = """
    (function () {
      var k = window.__kite = { seen: 0, status: 0, headers: null };
      var isFeed = function (u) { return String(u || '').indexOf('/api/georss') >= 0; };
      // What the page itself asked for and got, by type, to compare with what Kite gets.
      var note = function (u, text) {
        k.url = String(u || '').split('?')[1] || '';
        try {
          var t = {}, list = (JSON.parse(text).alerts || []);
          list.forEach(function (a) { t[a.type] = (t[a.type] || 0) + 1; });
          k.types = t;
        } catch (e) {}
      };
      var of = window.fetch;
      window.fetch = function (input, init) {
        var u = typeof input === 'string' ? input : (input && input.url);
        var p = of.apply(this, arguments);
        if (isFeed(u) && !(init && init.__kite)) {
          try {
            var h = {}, src = (init && init.headers) || (input && input.headers);
            if (src) { if (src.forEach) { src.forEach(function (v, n) { h[n] = v; }); } else { for (var n in src) { h[n] = src[n]; } } }
            k.headers = h; k.seen++;
          } catch (e) {}
          p.then(function (r) { k.status = r.status; r.clone().text().then(function (t) { note(u, t); }, function () {}); }, function () {});
        }
        return p;
      };
      var X = XMLHttpRequest.prototype, oo = X.open, os = X.setRequestHeader, sd = X.send;
      X.open = function (m, u) { this.__feed = isFeed(u); this.__u = u; this.__h = {}; return oo.apply(this, arguments); };
      X.setRequestHeader = function (n, v) { if (this.__feed) { this.__h[n] = v; } return os.apply(this, arguments); };
      X.send = function () {
        if (this.__feed) {
          var x = this; k.headers = this.__h; k.seen++;
          this.addEventListener('loadend', function () { k.status = x.status; try { note(x.__u, x.responseText); } catch (e) {} });
        }
        return sd.apply(this, arguments);
      };
      // The page asks reCAPTCHA for a one-off token before each request; note the site key and
      // action it uses, so Kite can ask for fresh tokens of its own.
      var wrap = setInterval(function () {
        var e = window.grecaptcha && window.grecaptcha.enterprise;
        if (!e || !e.execute || e.__kite) { return; }
        var ex = e.execute;
        e.execute = function (key, opts) {
          k.key = key; k.action = (opts && opts.action) || k.action;
          return ex.apply(this, arguments);
        };
        e.__kite = true;
        clearInterval(wrap);
      }, 30);
    })();
    """

    func fetch(_ url: URL) async -> Data? {
        await openPage()
        guard let web, ready else { note = "page: didn't load"; return nil }
        let js = """
        var k = window.__kite || {};
        var h = { 'Accept': 'application/json, text/plain, */*' };
        var seen = k.headers || {};
        for (var n in seen) { h[n] = seen[n]; }
        var e = window.grecaptcha && window.grecaptcha.enterprise;
        if (!k.key) {
          // Not seen the page ask yet: the key is in the reCAPTCHA script's address.
          var s = document.querySelector('script[src*="recaptcha"][src*="render="]');
          var m = s && s.src.match(/render=([^&]+)/);
          if (m && m[1] !== 'explicit') { k.key = m[1]; }
        }
        if (e && k.key) {
          var t = await new Promise(function (done) {
            e.ready(function () { e.execute(k.key, { action: k.action || 'livemap' }).then(done, function () { done(null); }); });
            setTimeout(function () { done(null); }, 8000);
          });
          if (t) {
            for (var n in h) { if (n.toLowerCase() === 'x-recaptcha-token') { delete h[n]; } }
            h['X-Recaptcha-Token'] = t;
          }
        }
        var r = await fetch(u, { credentials: 'include', headers: h, __kite: true });
        if (!r.ok) { return 'HTTP ' + r.status; }
        return await r.text();
        """
        // A second try a few seconds on: the page's pass may only just be on its way.
        for attempt in 0..<2 {
            if attempt == 1 { try? await Task.sleep(nanoseconds: 4_000_000_000) }
            do {
                guard let text = try await web.callAsyncJavaScript(js, arguments: ["u": url.absoluteString], contentWorld: .page) as? String else {
                    note = "page: no answer"
                    continue
                }
                if text.hasPrefix("HTTP ") {
                    let state = await pageState()
                    note = "page: fetch \(text) · \(state)"
                    continue
                }
                let own = await pageOwn()
                note = "page: ok, \(text.count) chars · \(own)"
                return Data(text.utf8)
            } catch {
                note = "page: \(error.localizedDescription)"
            }
        }
        // Still turned away: open the page afresh next time, for a new pass.
        reset()
        return nil
    }

    /** "pass yes, page asked 2× (200)": for the status line. */
    private func pageState() async -> String {
        let pass = await hasPass()
        let js = "var k = window.__kite; return k ? 'page asked ' + k.seen + '× (' + k.status + ')' + (k.headers ? ' ' + Object.keys(k.headers).join('+') : '') + (k.key ? ' key ' + String(k.key).slice(0, 6) + ' ' + (k.action || '?') : ' no key') : 'no watcher';"
        let page = (try? await web?.callAsyncJavaScript(js, arguments: [:], contentWorld: .page)) as? String ?? "?"
        return "pass \(pass ? "yes" : "no"), \(page)"
    }

    /** What the live map page last asked for itself and how many of each type it got back. */
    private func pageOwn() async -> String {
        let js = "var k = window.__kite || {}; if (!k.url) { return 'page itself: not asked'; } var t = k.types || {}; return 'page itself (' + k.url.replace(/top=.*?&env=/, 'env=') + '): ' + (Object.keys(t).map(function (n) { return n + ' ' + t[n]; }).join(', ') || 'nothing');"
        return (try? await web?.callAsyncJavaScript(js, arguments: [:], contentWorld: .page)) as? String ?? "?"
    }

    /** The page has asked for reports itself, or reCAPTCHA is ready to hand out tokens. */
    private func pageReady(_ w: WKWebView) async -> Bool {
        let js = "var k = window.__kite; return !!(k && (k.seen > 0 || k.key));"
        return (try? await w.callAsyncJavaScript(js, arguments: [:], contentWorld: .page)) as? Bool ?? false
    }

    private func hasPass() async -> Bool {
        guard let store = web?.configuration.websiteDataStore.httpCookieStore else { return false }
        let cookies = await store.allCookies()
        return cookies.contains { $0.name.hasPrefix("recaptcha-ca") && $0.domain.contains("waze.com") }
    }

    private func reset() {
        web?.removeFromSuperview()
        web = nil
        ready = false
    }

    private func openPage() async {
        if ready { return }
        if web == nil {
            let config = WKWebViewConfiguration()
            // The phone's own browser name, so the page and reCAPTCHA see a real Safari on this iOS
            // (a made-up older iOS version that doesn't match the browser's features looks like a bot).
            let v = ProcessInfo.processInfo.operatingSystemVersion
            config.applicationNameForUserAgent = "Version/\(v.majorVersion).\(v.minorVersion) Mobile/15E148 Safari/604.1"
            config.userContentController.addUserScript(WKUserScript(source: Self.watcher, injectionTime: .atDocumentStart, forMainFrameOnly: true))
            let w = WKWebView(frame: CGRect(x: 0, y: 0, width: 390, height: 844), configuration: config)
            w.navigationDelegate = self
            // In a window, behind everything, so the page runs like a real one (reCAPTCHA's check
            // needs its scripts to keep running) without ever being seen or touched.
            w.isUserInteractionEnabled = false
            w.alpha = 0.01
            if let window = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene })
                .flatMap(\.windows).first(where: \.isKeyWindow) ?? UIApplication.shared.connectedScenes
                .compactMap({ $0 as? UIWindowScene }).flatMap(\.windows).first {
                w.frame = window.bounds
                window.insertSubview(w, at: 0)
            }
            web = w
            w.load(URLRequest(url: Waze.pageURL))
            // Give up waiting after 25 seconds, so a stuck page never holds the map back.
            Task {
                try? await Task.sleep(nanoseconds: 25_000_000_000)
                if !self.ready, self.web === w { self.finish(ok: false) }
            }
        }
        await withCheckedContinuation { waiting.append($0) }
    }

    /** Once the page has loaded, wait (up to 12 seconds) for reCAPTCHA's pass before saying it's ready. */
    private func pageLoaded(_ w: WKWebView) {
        Task {
            for _ in 0..<24 {
                if await hasPass() { break }
                if await pageReady(w) { break }
                try? await Task.sleep(nanoseconds: 500_000_000)
                guard self.web === w else { return }
            }
            if self.web === w { self.finish(ok: true) }
        }
    }

    private func finish(ok: Bool) {
        if ok { ready = true }
        let w = waiting
        waiting = []
        for c in w { c.resume() }
        if !ok && !ready { reset() }
    }

    // WebKit calls these on the main thread; a late call from a page already given up on is ignored.
    nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        MainActor.assumeIsolated { if webView === web, !ready { pageLoaded(webView) } }
    }

    nonisolated func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        MainActor.assumeIsolated { if webView === web { finish(ok: false) } }
    }

    nonisolated func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        MainActor.assumeIsolated { if webView === web { finish(ok: false) } }
    }
}
