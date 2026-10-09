// MermaidRenderer.swift — rasterizes mermaid source to a bitmap with an offscreen WKWebView running the
// vendored mermaid runtime (Resources/mermaid.min.js, the same build the HTML preview inlines).
//
// Why a bitmap and not SVG: mermaid's SVG leans on <style> blocks and (with htmlLabels) <foreignObject>,
// neither of which CoreSVG/NSImage draws. The web view renders the SVG into a <canvas> and hands back a PNG,
// so what the editor shows is pixel-identical to the browser preview. htmlLabels is turned off so the SVG
// can be drawn onto a canvas at all (foreignObject taints the canvas in WebKit).
// Designed and Architected by: Phillip Escandon
import SwiftUI
import WebKit

#if os(macOS)
typealias PlatformImage = NSImage
#else
typealias PlatformImage = UIImage
#endif

@MainActor
final class MermaidRenderer: NSObject, WKNavigationDelegate {
    struct Result { let image: PlatformImage; let size: CGSize }   // size in points

    private let webView: WKWebView
    private var ready = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    /// `host` must be a view in a window: WebKit does not run navigations for a web view that has no window,
    /// so the renderer is parked inside the editor as a 1×1 point, nearly invisible subview.
    init(host: PlatformView?) {
        let config = WKWebViewConfiguration()
        webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 1, height: 1), configuration: config)
        super.init()
        webView.navigationDelegate = self
        #if os(macOS)
        webView.alphaValue = 0.01
        #else
        webView.alpha = 0.01
        webView.isUserInteractionEnabled = false
        #endif
        host?.addSubview(webView)
        let runtime = Bundle.main.url(forResource: "mermaid.min", withExtension: "js")
            .flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? ""
        webView.loadHTMLString(Self.page(runtime: runtime), baseURL: nil)
    }

    nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        Task { @MainActor in
            ready = true
            waiters.forEach { $0.resume() }
            waiters.removeAll()
        }
    }

    private func waitUntilReady() async {
        if ready { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    /// Renders `source` with mermaid's built-in `theme` at `scale` device pixels per point.
    /// Throws with mermaid's own message on a syntax error so the editor can show it inline.
    func render(_ source: String, theme: String, scale: CGFloat) async throws -> Result {
        await waitUntilReady()
        let value = try await webView.callAsyncJavaScript(
            "return await renderPNG(src, theme, scale)",
            arguments: ["src": source, "theme": theme, "scale": Double(scale)],
            contentWorld: .page)
        guard let dict = value as? [String: Any], let b64 = dict["png"] as? String,
              let w = dict["w"] as? Double, let h = dict["h"] as? Double,
              let data = Data(base64Encoded: b64), let image = PlatformImage(data: data) else {
            throw RenderError.badResult
        }
        return Result(image: image, size: CGSize(width: w, height: h))
    }

    enum RenderError: Error { case badResult }

    private static func page(runtime: String) -> String {
        """
        <!doctype html><html><head><meta charset="utf-8"><style>body{margin:0;background:transparent}</style></head>
        <body><div id="scratch"></div>
        <script>\(runtime)</script>
        <script>
        let n = 0;
        async function renderPNG(src, theme, scale) {
          mermaid.initialize({ startOnLoad: false, theme, securityLevel: 'strict',
                               flowchart: { htmlLabels: false, useMaxWidth: false },
                               sequence: { useMaxWidth: false }, gantt: { useMaxWidth: false },
                               class: { useMaxWidth: false }, state: { useMaxWidth: false }, er: { useMaxWidth: false } });
          const { svg } = await mermaid.render('inkwell' + (++n), src);
          const host = document.getElementById('scratch');
          host.innerHTML = svg;
          const el = host.firstElementChild;
          // Intrinsic size: mermaid sets width:100% + max-width; pin the viewBox size so the bitmap is 1:1.
          const vb = el.viewBox.baseVal;
          let w = vb && vb.width ? vb.width : el.getBoundingClientRect().width;
          let h = vb && vb.height ? vb.height : el.getBoundingClientRect().height;
          w = Math.ceil(w); h = Math.ceil(h);
          el.setAttribute('width', w); el.setAttribute('height', h); el.style.maxWidth = ''; el.style.width = w + 'px';
          const xml = new XMLSerializer().serializeToString(el);
          const img = new Image();
          await new Promise((ok, err) => { img.onload = ok; img.onerror = () => err(new Error('svg decode failed')); 
                                           img.src = 'data:image/svg+xml;charset=utf-8,' + encodeURIComponent(xml); });
          const canvas = document.createElement('canvas');
          canvas.width = Math.ceil(w * scale); canvas.height = Math.ceil(h * scale);
          const ctx = canvas.getContext('2d');
          ctx.scale(scale, scale);
          ctx.drawImage(img, 0, 0, w, h);
          host.innerHTML = '';
          return { png: canvas.toDataURL('image/png').split(',')[1], w, h };
        }
        </script></body></html>
        """
    }
}
