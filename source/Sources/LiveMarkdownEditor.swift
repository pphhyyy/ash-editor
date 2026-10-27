import AppKit
import SwiftUI
import WebKit

/// The same Markdown document is edited in place by a bundled, offline Milkdown editor.
struct LiveMarkdownEditor: NSViewRepresentable {
    @Binding var text: String
    var size: Double
    var color: Color
    var isNight: Bool
    var themeName = "紫雾"
    var readOnly = false
    var concealed: Bool
    @Binding var documentTitle: String
    var showsDocumentTitle: Bool
    var fading: Bool
    var fadeInitialOpacity: Double
    var fadeDuration: Double
    var alignment: String
    var pageMargin: Double = 0
    var secondary = false
    var mathDelimiter = "dollar"
    var loadImage: (String) throws -> (Data, String) = { _ in throw NSError(domain: "ASH.Image", code: 1) }
    var isCurrent: () -> Bool = { true }
    var wantsFocus: () -> Bool = { false }
    var onFocus: () -> Void = {}
    var pasteImage: () throws -> String? = { nil }
    var onError: (String) -> Void = { _ in }

    func makeCoordinator() -> Coordinator { Coordinator(text: $text, secondary: secondary, isCurrent: isCurrent, wantsFocus: wantsFocus, onFocus: onFocus, onError: onError, loadImage: loadImage, pasteImage: pasteImage) }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        configuration.userContentController.add(WeakEditorMessageHandler(context.coordinator), name: "ashEditor")
        let imageSchemeHandler = ASHImageSchemeHandler()
        imageSchemeHandler.coordinator = context.coordinator
        configuration.setURLSchemeHandler(imageSchemeHandler, forURLScheme: "ash-image")
        let view = ASHImagePasteWebView(frame: .zero, configuration: configuration)
        view.onPasteImage = { [weak coordinator = context.coordinator] in
            coordinator?.handleClipboardImagePaste() ?? false
        }
        view.setValue(false, forKey: "drawsBackground")
        view.navigationDelegate = context.coordinator
        view.allowsBackForwardNavigationGestures = false
        context.coordinator.webView = view
        LiveMarkdownEditors.register(context.coordinator)
        if let url = Bundle.main.url(forResource: "editor", withExtension: "html", subdirectory: "LiveEditor")
            ?? Bundle.main.url(forResource: "editor", withExtension: "html"),
           let html = try? String(contentsOf: url, encoding: .utf8) {
            view.loadHTMLString(html, baseURL: Bundle.main.resourceURL)
        } else {
            DispatchQueue.main.async { onError("实时编辑器资源缺失，请关闭实时预览后继续编辑。") }
        }
        return view
    }

    func updateNSView(_ view: WKWebView, context: Context) {
        let coordinator = context.coordinator
        coordinator.documentTitle = $documentTitle
        coordinator.text = $text; coordinator.onFocus = onFocus; coordinator.onError = onError
        coordinator.isCurrent = isCurrent
        coordinator.wantsFocus = wantsFocus
        coordinator.loadImage = loadImage
        coordinator.pasteImage = pasteImage
        let ink = NSColor(color).usingColorSpace(.deviceRGB) ?? .labelColor
        coordinator.appearance = ["theme": themeName, "readOnly": readOnly, "fontSize": size, "ink": String(format: "#%02X%02X%02X", Int(ink.redComponent * 255), Int(ink.greenComponent * 255), Int(ink.blueComponent * 255)), "night": isNight, "title": documentTitle, "showTitle": showsDocumentTitle, "fading": fading, "fadeOpacity": fadeInitialOpacity, "fadeDuration": fadeDuration, "concealed": concealed, "alignment": alignment, "pageMargin": pageMargin, "mathDelimiter": mathDelimiter]
        if coordinator.lastMarkdown != text {
            coordinator.epoch += 1
            coordinator.lastMarkdown = text
        }
        coordinator.configure()
    }

    static func dismantleNSView(_ view: WKWebView, coordinator: Coordinator) {
        LiveMarkdownEditors.unregister(coordinator)
        coordinator.isCurrent = { false }
        coordinator.loaded = false
        coordinator.editorReady = false
        view.configuration.userContentController.removeScriptMessageHandler(forName: "ashEditor")
        view.navigationDelegate = nil
        view.stopLoading()
    }

    @MainActor final class Coordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
        let id = UUID()
        let secondary: Bool
        var documentTitle: Binding<String>?
        var text: Binding<String>
        var onFocus: () -> Void
        var onError: (String) -> Void
        var loadImage: (String) throws -> (Data, String)
        var pasteImage: () throws -> String?
        var isCurrent: () -> Bool
        var wantsFocus: () -> Bool
        weak var webView: WKWebView?
        var loaded = false
        var editorReady = false
        var epoch = 0
        var lastMarkdown: String
        var appearance: [String: Any] = [:]
        private var lastConfiguration = ""
        private var configurationInFlight = false

        init(text: Binding<String>, secondary: Bool, isCurrent: @escaping () -> Bool, wantsFocus: @escaping () -> Bool, onFocus: @escaping () -> Void, onError: @escaping (String) -> Void, loadImage: @escaping (String) throws -> (Data, String), pasteImage: @escaping () throws -> String?) {
            self.text = text; self.secondary = secondary; self.onFocus = onFocus; self.onError = onError
            self.loadImage = loadImage; self.pasteImage = pasteImage
            lastMarkdown = text.wrappedValue
            self.isCurrent = isCurrent
            self.wantsFocus = wantsFocus
        }

        func configure() {
            guard isCurrent(), loaded, !configurationInFlight, let webView else { return }
            var config = appearance
            config["epoch"] = epoch; config["markdown"] = lastMarkdown
            guard let data = try? JSONSerialization.data(withJSONObject: config, options: [.sortedKeys]),
                  let json = String(data: data, encoding: .utf8), json != lastConfiguration else { return }
            lastConfiguration = json
            configurationInFlight = true
            webView.evaluateJavaScript("window.ashEditor.configure(\(json)); null") { [weak self] _, error in
                guard let self else { return }
                self.configurationInFlight = false
                if let error, self.isCurrent() { self.onError("实时编辑器：\(error.localizedDescription)") }
                self.configure()
            }
        }

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            guard isCurrent() else { return }
            guard let body = message.body as? [String: Any], let type = body["type"] as? String else { return }
            switch type {
            case "loaded": loaded = true; configure()
            case "ready":
                editorReady = true
                lastConfiguration = ""; configure()
                if wantsFocus(), let webView, webView.window?.isKeyWindow == true,
                   webView.window?.attachedSheet == nil {
                    webView.evaluateJavaScript("window.ashEditor.focus(); null", completionHandler: nil)
                }
            case "titleChange":
                if let value = body["title"] as? String { documentTitle?.wrappedValue = value }
            case "focus": onFocus()
            case "pasteImage":
                _ = handleClipboardImagePaste()
            case "change":
                guard let value = body["markdown"] as? String, let revision = body["epoch"] as? Int, revision == epoch else { return }
                lastMarkdown = value
                if text.wrappedValue != value { text.wrappedValue = value }
            case "error": onError("实时编辑器：\(body["message"] as? String ?? "未知错误")")
            default: break
            }
        }

        @discardableResult
        func handleClipboardImagePaste() -> Bool {
            guard editorReady, isCurrent(), appearance["readOnly"] as? Bool == false,
                  let webView, webView.window?.isKeyWindow == true else { return false }
            do {
                guard let reference = try pasteImage() else { return false }
                let encoded = try JSONSerialization.data(withJSONObject: [reference], options: [])
                guard let json = String(data: encoded, encoding: .utf8), json.count >= 2 else { return true }
                let argument = String(json.dropFirst().dropLast())
                webView.evaluateJavaScript("window.ashEditor.insertImage(\(argument)); null", completionHandler: nil)
                return true
            } catch {
                onError("粘贴图片失败：\(error.localizedDescription)")
                return true
            }
        }

        func flush(_ completion: @escaping () -> Void) {
            guard loaded, let webView else { completion(); return }
            let revision = epoch
            let completionOnce = FlushCompletionOnce(completion)
            // WebKit can occasionally fail to deliver evaluateJavaScript's callback
            // while a window is closing. Do not let save or app termination wait forever.
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                completionOnce.call()
            }
            webView.evaluateJavaScript("({markdown:window.ashEditor.flush(),epoch:window.ashEditor.inspect().epoch})") { [weak self] result, _ in
                if let self, self.isCurrent(), revision == self.epoch, let snapshot = result as? [String: Any],
                   snapshot["epoch"] as? Int == revision, let value = snapshot["markdown"] as? String {
                    self.lastMarkdown = value
                    if self.text.wrappedValue != value { self.text.wrappedValue = value }
                }
                completionOnce.call()
            }
        }

        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            // Links and pasted HTML cannot navigate away or run an external page in the document editor.
            let url = navigationAction.request.url
            decisionHandler(navigationAction.navigationType == .other && (url?.scheme == "about" || url?.isFileURL == true) ? .allow : .cancel)
        }

        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
            guard isCurrent() else { return }
            editorReady = false
            onError("实时编辑器进程已停止。正文已同步的内容仍在，请关闭实时预览继续编辑。")
        }
    }
}

/// WebKit does not expose every macOS image pasteboard representation to DOM
/// ClipboardEvent.items. Catch the standard paste shortcut natively, then leave
/// text and other pasteboard contents to WebKit.
private final class ASHImagePasteWebView: WKWebView {
    var onPasteImage: (() -> Bool)?

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if ownsFirstResponder, isStandardPasteShortcut(event), onPasteImage?() == true { return true }
        return super.performKeyEquivalent(with: event)
    }

    override func keyDown(with event: NSEvent) {
        if ownsFirstResponder, isStandardPasteShortcut(event), onPasteImage?() == true { return }
        super.keyDown(with: event)
    }

    private var ownsFirstResponder: Bool {
        guard let window else { return false }
        var responder: NSResponder? = window.firstResponder
        while let view = responder as? NSView {
            if view === self { return true }
            responder = view.superview
        }
        return window.firstResponder === self
    }

    private func isStandardPasteShortcut(_ event: NSEvent) -> Bool {
        guard event.charactersIgnoringModifiers?.lowercased() == "v" else { return false }
        let modifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])
        return modifiers == .command
    }
}

private final class ASHImageSchemeHandler: NSObject, WKURLSchemeHandler {
    weak var coordinator: LiveMarkdownEditor.Coordinator?

    func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
        guard let requestURL = urlSchemeTask.request.url,
              let source = URLComponents(url: requestURL, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "src" })?.value else {
            urlSchemeTask.didFailWithError(NSError(domain: "ASH.Image", code: 2, userInfo: [NSLocalizedDescriptionKey: "图片地址无效。"]))
            return
        }
        DispatchQueue.main.async { [weak self, weak urlSchemeTask] in
            guard let self, let urlSchemeTask, let coordinator = self.coordinator else { return }
            do {
                let (data, mimeType) = try coordinator.loadImage(source)
                guard let url = urlSchemeTask.request.url else { throw CocoaError(.fileReadUnknown) }
                let response = URLResponse(url: url, mimeType: mimeType, expectedContentLength: data.count, textEncodingName: nil)
                urlSchemeTask.didReceive(response)
                urlSchemeTask.didReceive(data)
                urlSchemeTask.didFinish()
            } catch {
                urlSchemeTask.didFailWithError(error)
            }
        }
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {}
}

private final class FlushCompletionOnce {
    private let lock = NSLock()
    private var completion: (() -> Void)?

    init(_ completion: @escaping () -> Void) {
        self.completion = completion
    }

    func call() {
        lock.lock()
        let callback = completion
        completion = nil
        lock.unlock()
        callback?()
    }
}

private final class WeakEditorMessageHandler: NSObject, WKScriptMessageHandler {
    weak var target: LiveMarkdownEditor.Coordinator?
    init(_ target: LiveMarkdownEditor.Coordinator) { self.target = target }
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        target?.userContentController(userContentController, didReceive: message)
    }
}

/// Flush before saving, changing modes or replacing documents; no debounced text can be lost.
@MainActor enum LiveMarkdownEditors {
    private final class WeakEditor {
        weak var value: LiveMarkdownEditor.Coordinator?
        init(_ value: LiveMarkdownEditor.Coordinator) { self.value = value }
    }
    private static var editors: [UUID: WeakEditor] = [:]
    static func register(_ editor: LiveMarkdownEditor.Coordinator) { editors[editor.id] = WeakEditor(editor) }
    static func unregister(_ editor: LiveMarkdownEditor.Coordinator) { editors.removeValue(forKey: editor.id) }
    static func flush(secondary: Bool? = nil, completion: @escaping () -> Void) {
        let targets = editors.values.compactMap(\.value).filter { (secondary == nil || $0.secondary == secondary) && $0.webView?.window?.isVisible == true }
        func next(_ index: Int) {
            guard index < targets.count else { completion(); return }
            targets[index].flush { next(index + 1) }
        }
        next(0)
    }
}
