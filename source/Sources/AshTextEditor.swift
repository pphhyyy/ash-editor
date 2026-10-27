import AppKit
import SwiftUI

/// Plain-text editor that hides glyphs but keeps the original insertion point and editing position.
struct AshTextEditor: NSViewRepresentable {
    @Binding var text: String
    var size: Double
    var color: Color
    var concealed: Bool
    var focusMode: Bool
    var alignment: String
    var documentTitle: Binding<String>? = nil
    var showsDocumentTitle = false
    var fading = false
    var fadeInitialOpacity = 0.35
    var fadeDuration = 4.0
    var isCurrent: () -> Bool = { true }
    var wantsFocus: () -> Bool = { true }
    var onFocus: () -> Void = {}
    var liveMarkdown: Bool = false
    var focusToken: Int = 0
    var showsScrollIndicators = true
    var startAtEnd = false
    var onCancel: (() -> Void)? = nil

    func makeCoordinator() -> Coordinator { Coordinator(text: $text, isCurrent: isCurrent, onFocus: onFocus) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = showsScrollIndicators
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        let editor = AshInputTextView()
        editor.delegate = context.coordinator
        editor.onEditorFocus = { [weak coordinator = context.coordinator] in
            guard let coordinator, coordinator.isCurrent() else { return }
            coordinator.onFocus()
        }
        editor.isRichText = false
        editor.isEditable = true
        editor.isSelectable = true
        editor.allowsUndo = true
        editor.drawsBackground = false
        editor.backgroundColor = .clear
        editor.insertionPointColor = .systemPurple
        editor.textContainerInset = NSSize(width: 5, height: 7)
        editor.isVerticallyResizable = true
        editor.isHorizontallyResizable = false
        editor.autoresizingMask = [.width]
        editor.textContainer?.widthTracksTextView = true
        editor.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        editor.minSize = NSSize(width: 0, height: 0)
        editor.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        let heading = NSTextField(string: "")
        heading.isBordered = false; heading.drawsBackground = false
        heading.font = .systemFont(ofSize: 30, weight: .semibold)
        heading.placeholderString = "无标题笔记"
        heading.frame = NSRect(x: 5, y: 7, width: 300, height: 42)
        heading.autoresizingMask = [.width]
        heading.delegate = context.coordinator
        editor.addSubview(heading)
        context.coordinator.heading = heading
        scroll.documentView = editor
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let editor = scroll.documentView as? NSTextView else { return }
        context.coordinator.text = $text
        context.coordinator.isCurrent = isCurrent
        context.coordinator.wantsFocus = wantsFocus
        guard isCurrent() else { return }
        context.coordinator.onFocus = onFocus
        context.coordinator.onCancel = onCancel
        context.coordinator.liveMarkdown = liveMarkdown
        let focusRequested = focusToken > 0 && context.coordinator.lastFocusToken != focusToken
        context.coordinator.lastFocusToken = focusToken
        // Re-styling textStorage while an input method owns a marked range disrupts
        // its candidate window. Leave the composing text and input context untouched.
        if editor.hasMarkedText() { return }
        let replacedText = editor.string != text
        if replacedText {
            let selection = editor.selectedRange()
            editor.string = text
            let location = startAtEnd && !context.coordinator.initialized ? (text as NSString).length : min(selection.location, (text as NSString).length)
            editor.setSelectedRange(NSRange(location: location, length: 0))
        }
        context.coordinator.initialized = true
        let ink = NSColor(color)
        context.coordinator.documentTitle = documentTitle
        if let heading = context.coordinator.heading {
            heading.isHidden = !showsDocumentTitle || concealed || fading
            if heading.currentEditor() == nil { heading.stringValue = documentTitle?.wrappedValue ?? "" }
            heading.textColor = concealed || fading ? .clear : ink
        }
        // Status/count updates arrive on every keystroke in standard mode.
        // Do not invalidate the entire text layout for an unchanged appearance.
        let style = "\(size)|\(ink)|\(alignment)|\(concealed)|\(fading)|\(showsDocumentTitle)|\(liveMarkdown)"
        let needsStyling = replacedText || context.coordinator.appliedStyle != style
        context.coordinator.configureFade(editor, active: fading, opacity: fadeInitialOpacity, duration: fadeDuration, ink: ink)
        if needsStyling {
            context.coordinator.appliedStyle = style
            let inset = NSSize(width: 5, height: showsDocumentTitle ? 62 : 7)
            if editor.textContainerInset != inset { editor.textContainerInset = inset }
            editor.textColor = (concealed || fading) ? .clear : ink
            editor.selectedTextAttributes = [.foregroundColor: (concealed || fading) ? NSColor.clear : NSColor.selectedTextColor,
                                             .backgroundColor: (concealed || fading) ? NSColor.clear : NSColor.selectedTextBackgroundColor]
            editor.markedTextAttributes = [.foregroundColor: (concealed || fading) ? NSColor.clear : ink,
                                           .underlineStyle: (concealed || fading) ? 0 : NSUnderlineStyle.single.rawValue]
            editor.insertionPointColor = .systemPurple
            editor.font = NSFont(name: "NewYork-Regular", size: size) ?? NSFont.systemFont(ofSize: size)
            editor.alignment = alignment == "center" ? .center : .left
            let paragraph = NSMutableParagraphStyle()
            paragraph.alignment = alignment == "center" ? .center : .left
            editor.typingAttributes = [
                .font: editor.font!,
                .foregroundColor: (concealed || fading) ? NSColor.clear : ink,
                .paragraphStyle: paragraph
            ]
            if let storage = editor.textStorage, storage.length > 0 {
                storage.addAttribute(.foregroundColor, value: (concealed || fading) ? NSColor.clear : ink,
                                     range: NSRange(location: 0, length: storage.length))
                storage.addAttribute(.paragraphStyle, value: paragraph,
                                     range: NSRange(location: 0, length: storage.length))
                if liveMarkdown && !concealed && !fading {
                    Coordinator.applyMarkdownStyling(storage, baseFont: editor.font!, color: ink,
                                                    cursorLocation: editor.selectedRange().location)
                }
            }
        }
        if context.coordinator.lastConcealed != concealed || context.coordinator.lastFocusMode != focusMode || focusRequested {
            context.coordinator.lastConcealed = concealed
            context.coordinator.lastFocusMode = focusMode
            DispatchQueue.main.async {
                guard context.coordinator.isCurrent(), context.coordinator.wantsFocus(), let window = editor.window,
                      window.isVisible, window.isKeyWindow, window.attachedSheet == nil else { return }
                window.makeKeyAndOrderFront(nil)
                _ = window.makeFirstResponder(editor)
                editor.scrollRangeToVisible(editor.selectedRange())
            }
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate, NSTextFieldDelegate {
        var text: Binding<String>
        var isCurrent: () -> Bool
        var wantsFocus: () -> Bool = { true }
        var onFocus: () -> Void
        var onCancel: (() -> Void)?
        weak var heading: NSTextField?
        var documentTitle: Binding<String>?
        private var fadeActive = false
        private var fadeOpacity = 0.35
        private var fadeSeconds = 4.0
        private var fadeInk = NSColor.labelColor
        private var fadeText = ""
        private var pendingFadeEdit: (range: NSRange, length: Int)?
        private var fadeSpans: [(range: NSRange, born: TimeInterval)] = []
        private var fadeTimer: Timer?

        func controlTextDidChange(_ notification: Notification) {
            guard isCurrent(), let field = notification.object as? NSTextField else { return }
            documentTitle?.wrappedValue = field.stringValue
        }

        func configureFade(_ editor: NSTextView, active: Bool, opacity: Double, duration: Double, ink: NSColor) {
            if active != fadeActive {
                fadeSpans = []; fadeText = editor.string
                fadeTimer?.invalidate(); fadeTimer = nil
                if active {
                    let timer = Timer(timeInterval: 0.06, repeats: true) { [weak self, weak editor] _ in
                        guard let self, let editor, !self.fadeSpans.isEmpty else { return }
                        self.paintFade(editor)
                    }
                    RunLoop.main.add(timer, forMode: .common)
                    fadeTimer = timer
                } else if let manager = editor.layoutManager {
                    manager.removeTemporaryAttribute(.foregroundColor, forCharacterRange: NSRange(location: 0, length: (editor.string as NSString).length))
                }
            }
            fadeActive = active; fadeOpacity = opacity; fadeSeconds = duration; fadeInk = ink
            if active { paintFade(editor) }
        }

        func textView(_ textView: NSTextView, shouldChangeTextIn affectedCharRange: NSRange, replacementString: String?) -> Bool {
            pendingFadeEdit = (affectedCharRange, (replacementString as NSString?)?.length ?? 0)
            return true
        }

        private func trackFadeEdit(_ editor: NSTextView) {
            guard fadeActive else { fadeText = editor.string; return }
            let old = Array(fadeText.utf16), new = Array(editor.string.utf16)
            var prefix = 0
            while prefix < min(old.count,new.count) && old[prefix] == new[prefix] { prefix += 1 }
            var suffix = 0
            while suffix < min(old.count,new.count)-prefix && old[old.count-suffix-1] == new[new.count-suffix-1] { suffix += 1 }
            if let change = pendingFadeEdit, NSMaxRange(change.range) <= old.count,
               new.count == old.count-change.range.length+change.length {
                prefix = change.range.location
                suffix = old.count-NSMaxRange(change.range)
            }
            pendingFadeEdit = nil
            let oldEnd = old.count-suffix, inserted = new.count-prefix-suffix
            let delta = new.count-old.count
            var mapped: [(range: NSRange, born: TimeInterval)] = []
            for span in fadeSpans {
                let start = span.range.location, end = NSMaxRange(span.range)
                if end <= prefix { mapped.append(span) }
                else if start >= oldEnd { mapped.append((NSRange(location: start+delta, length: span.range.length),span.born)) }
                else {
                    if start < prefix { mapped.append((NSRange(location:start,length:prefix-start),span.born)) }
                    if end > oldEnd { mapped.append((NSRange(location:prefix+inserted,length:end-oldEnd),span.born)) }
                }
            }
            if inserted > 0 { mapped.append((NSRange(location:prefix,length:inserted),Date.timeIntervalSinceReferenceDate)) }
            fadeSpans = mapped; fadeText = editor.string
            paintFade(editor)
        }

        private func paintFade(_ editor: NSTextView) {
            guard fadeActive, !editor.hasMarkedText(), let manager = editor.layoutManager else { return }
            let count = (editor.string as NSString).length
            guard count > 0 else { fadeSpans = []; return }
            let now = Date.timeIntervalSinceReferenceDate
            manager.addTemporaryAttribute(.foregroundColor, value: NSColor.clear, forCharacterRange: NSRange(location:0,length:count))
            fadeSpans.removeAll { now-$0.born >= fadeSeconds || NSMaxRange($0.range) > count }
            for span in fadeSpans where span.range.length > 0 {
                let alpha = fadeOpacity * max(0,1-(now-span.born)/fadeSeconds)
                manager.addTemporaryAttribute(.foregroundColor, value: fadeInk.withAlphaComponent(alpha), forCharacterRange: span.range)
            }
        }

        deinit { fadeTimer?.invalidate() }
        var appliedStyle: String?
        var initialized = false
        var liveMarkdown = false
        var lastConcealed = false
        var lastFocusMode = false
        var lastFocusToken = 0
        init(text: Binding<String>, isCurrent: @escaping () -> Bool, onFocus: @escaping () -> Void) {
            self.text = text; self.isCurrent = isCurrent; self.onFocus = onFocus
        }
        func textDidBeginEditing(_ notification: Notification) { if isCurrent() { onFocus() } }
        func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            if commandSelector == #selector(NSResponder.cancelOperation(_:)), let onCancel {
                onCancel(); return true
            }
            return false
        }
        func textDidChange(_ notification: Notification) {
            guard isCurrent(), let editor = notification.object as? NSTextView else { return }
            trackFadeEdit(editor)
            text.wrappedValue = editor.string
            guard liveMarkdown, let storage = editor.textStorage else { return }
            let selectedRange = editor.selectedRange()
            Self.applyMarkdownStyling(storage, baseFont: editor.font ?? .systemFont(ofSize: 18),
                                      color: editor.textColor ?? .labelColor,
                                      cursorLocation: selectedRange.location)
            editor.setSelectedRange(NSRange(location: min(selectedRange.location, storage.length), length: 0))
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard liveMarkdown, let editor = notification.object as? NSTextView,
                  let storage = editor.textStorage else { return }
            let selection = editor.selectedRange()
            // Reapplying Markdown attributes changes text layout. During a drag
            // selection that can move the scroll view while the user is selecting.
            // Refresh the active-line styling only after the selection collapses.
            guard selection.length == 0 else { return }
            let location = selection.location
            let lineStart = (storage.string as NSString).paragraphRange(for: NSRange(location: min(location, storage.length), length: 0)).location
            guard lineStart != lastStyledLineStart else { return }
            lastStyledLineStart = lineStart
            Self.applyMarkdownStyling(storage, baseFont: editor.font ?? .systemFont(ofSize: 18),
                                      color: editor.textColor ?? .labelColor,
                                      cursorLocation: location)
        }

        var lastStyledLineStart: Int?

        static func applyMarkdownStyling(_ storage: NSTextStorage, baseFont: NSFont, color: NSColor,
                                         cursorLocation: Int) {
            let source = storage.string as NSString
            guard source.length > 0 else { return }
            let all = NSRange(location: 0, length: source.length)
            storage.beginEditing()
            storage.addAttributes([.font: baseFont, .foregroundColor: color], range: all)
            storage.removeAttribute(.backgroundColor, range: all)

            let activeLine = source.paragraphRange(for: NSRange(location: min(cursorLocation, source.length), length: 0))
            var concealedRanges: [NSRange] = []
            func hide(_ range: NSRange) { if range.location != NSNotFound && range.length > 0 { concealedRanges.append(range) } }

            func setFont(_ range: NSRange, size: CGFloat, weight: NSFont.Weight = .regular) {
                guard range.location != NSNotFound, range.length > 0 else { return }
                let font = NSFont.systemFont(ofSize: size, weight: weight)
                storage.addAttribute(.font, value: font, range: range)
            }
            let lines = source.components(separatedBy: "\n") as [String]
            var offset = 0
            for line in lines {
                let lineRange = NSRange(location: offset, length: (line as NSString).length)
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("#") {
                    let depth = min(6, trimmed.prefix(while: { $0 == "#" }).count)
                    setFont(lineRange, size: max(baseFont.pointSize, baseFont.pointSize + CGFloat(7 - depth) * 3), weight: .bold)
                    storage.addAttribute(.foregroundColor, value: color, range: lineRange)
                    if let marker = try? NSRegularExpression(pattern: #"^\s{0,3}#{1,6}\s+"#)
                        .firstMatch(in: line, range: NSRange(location: 0, length: (line as NSString).length)) {
                        hide(NSRange(location: offset + marker.range.location, length: marker.range.length))
                    }
                } else if trimmed.hasPrefix(">") {
                    setFont(lineRange, size: baseFont.pointSize, weight: .medium)
                    storage.addAttribute(.foregroundColor, value: color.withAlphaComponent(0.78), range: lineRange)
                    if let marker = try? NSRegularExpression(pattern: #"^\s*>\s?"#)
                        .firstMatch(in: line, range: NSRange(location: 0, length: (line as NSString).length)) {
                        hide(NSRange(location: offset + marker.range.location, length: marker.range.length))
                    }
                } else if trimmed.hasPrefix("```") {
                    setFont(lineRange, size: baseFont.pointSize, weight: .medium)
                    storage.addAttribute(.backgroundColor, value: NSColor.quaternaryLabelColor.withAlphaComponent(0.18), range: lineRange)
                    hide(lineRange)
                } else if trimmed.hasPrefix("|"), trimmed.contains("|") {
                    setFont(lineRange, size: baseFont.pointSize, weight: .regular)
                    storage.addAttribute(.backgroundColor, value: NSColor.quaternaryLabelColor.withAlphaComponent(0.10), range: lineRange)
                    if trimmed.range(of: #"^\|?[\s:|-]+\|?$"#, options: .regularExpression) != nil { hide(lineRange) }
                    else {
                        let pipes = try? NSRegularExpression(pattern: #"\|"#)
                        pipes?.matches(in: line, range: NSRange(location: 0, length: (line as NSString).length)).forEach { hide(NSRange(location: offset + $0.range.location, length: $0.range.length)) }
                    }
                } else if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") || trimmed.hasPrefix("+ ") || trimmed.range(of: #"^\d+\.\s"#, options: .regularExpression) != nil {
                    setFont(lineRange, size: baseFont.pointSize, weight: .medium)
                    if let marker = try? NSRegularExpression(pattern: #"^\s*(?:[-*+]|\d+[.)])\s+"#)
                        .firstMatch(in: line, range: NSRange(location: 0, length: (line as NSString).length)) {
                        hide(NSRange(location: offset + marker.range.location, length: marker.range.length))
                    }
                }
                offset += lineRange.length + 1
            }

            let patterns: [(String, Int, NSFont.Weight)] = [
                (#"\*\*(.+?)\*\*|__(.+?)__"#, 1, .bold),
                (#"(?<!\*)\*([^*]+)\*(?!\*)|(?<!_)_([^_]+)_(?!_)"#, 1, .regular),
                (#"`([^`]+)`"#, 0, .regular)
            ]
            for (pattern, _, weight) in patterns {
                guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
                for match in regex.matches(in: source as String, range: all) {
                    let target = match.range(at: 0)
                    if pattern.hasPrefix("`") {
                        storage.addAttribute(.font, value: NSFont.monospacedSystemFont(ofSize: baseFont.pointSize, weight: .regular), range: target)
                        storage.addAttribute(.backgroundColor, value: NSColor.quaternaryLabelColor.withAlphaComponent(0.18), range: target)
                        hide(NSRange(location: target.location, length: 1))
                        hide(NSRange(location: NSMaxRange(target) - 1, length: 1))
                    } else {
                        storage.addAttribute(.font, value: NSFont.systemFont(ofSize: baseFont.pointSize, weight: weight), range: target)
                        let delimiters = try? NSRegularExpression(pattern: #"\*\*|__|~~|(?<!\*)\*(?!\*)|(?<!_)_(?!_)"#)
                        delimiters?.matches(in: source.substring(with: target), range: NSRange(location: 0, length: target.length)).forEach {
                            hide(NSRange(location: target.location + $0.range.location, length: $0.range.length))
                        }
                    }
                }
            }
            for range in concealedRanges where NSIntersectionRange(range, activeLine).length == 0 {
                storage.addAttribute(.foregroundColor, value: NSColor.clear, range: range)
            }
            storage.endEditing()
        }
    }
}

/// Tell the system IME the actual client level, and allow a nonactivating panel
/// to obtain keyboard focus when the user clicks its writing surface.
private final class AshInputTextView: NSTextView {
    var onEditorFocus: (() -> Void)?
    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted { onEditorFocus?() }
        return accepted
    }
    override var needsPanelToBecomeKey: Bool { true }
    override func windowLevel() -> Int {
        window?.level.rawValue ?? NSWindow.Level.normal.rawValue
    }
}
