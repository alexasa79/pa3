import ApplicationServices
import Foundation

struct SelectedTextResult: Sendable {
    var text: String?
    var message: String
}

enum SelectedText {
    static func substring(_ text: String, range: CFRange) -> String? {
        guard range.location >= 0, range.length > 0, range.location <= text.utf16.count,
              range.length <= text.utf16.count - range.location,
              let range = Range(NSRange(location: range.location, length: range.length), in: text) else { return nil }
        return String(text[range])
    }

    static func read(pid: pid_t) -> SelectedTextResult {
        guard AXIsProcessTrusted() else {
            return SelectedTextResult(message: "Allow PA3 in System Settings → Privacy & Security → Accessibility.")
        }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.15)
        let deadline = Date().addingTimeInterval(2)
        func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
            guard Date() < deadline else { return nil }
            AXUIElementSetMessagingTimeout(element, 0.15)
            var value: CFTypeRef?
            guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
            return value
        }
        func element(_ value: CFTypeRef?) -> AXUIElement? {
            guard let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
            return (value as! AXUIElement)
        }
        func selected(_ item: AXUIElement) -> String? {
            if attribute(item, kAXSubroleAttribute) as? String == kAXSecureTextFieldSubrole { return nil }
            if let text = attribute(item, kAXSelectedTextAttribute) as? String,
               !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return text }
            guard let raw = attribute(item, kAXSelectedTextRangeAttribute), CFGetTypeID(raw) == AXValueGetTypeID() else { return nil }
            let value = raw as! AXValue
            guard AXValueGetType(value) == .cfRange else { return nil }
            var range = CFRange()
            guard AXValueGetValue(value, .cfRange, &range), range.location >= 0, range.length > 0, range.length <= 200_000 else { return nil }
            var text: CFTypeRef?
            AXUIElementSetMessagingTimeout(item, 0.15)
            if Date() < deadline, AXUIElementCopyParameterizedAttributeValue(item, kAXStringForRangeParameterizedAttribute as CFString, value, &text) == .success,
               let text = text as? String { return text }
            if let text = attribute(item, kAXValueAttribute) as? String { return substring(text, range: range) }
            return nil
        }
        func result(_ text: String) -> SelectedTextResult {
            guard text.count <= 100_000 else { return SelectedTextResult(message: "Select less than 100,000 characters.") }
            return SelectedTextResult(text: text, message: "Reading selection")
        }
        let focused = element(attribute(app, kAXFocusedUIElementAttribute))
        if let focused {
            if attribute(focused, kAXSubroleAttribute) as? String == kAXSecureTextFieldSubrole {
                return SelectedTextResult(message: "Secure text fields cannot be narrated.")
            }
            if let text = selected(focused) { return result(text) }
        }
        // Web views may put the selection on a descendant rather than the focused group.
        var pending: [AXUIElement] = [focused, element(attribute(app, kAXFocusedWindowAttribute))].compactMap { $0 }
        var visited: Set<CFHashCode> = []
        var examined = 0
        while !pending.isEmpty, examined < 300, Date() < deadline {
            let current = pending.removeFirst()
            guard visited.insert(CFHash(current)).inserted else { continue }
            examined += 1
            if let text = selected(current) { return result(text) }
            if let children = attribute(current, kAXChildrenAttribute) as? [AXUIElement] {
                pending.append(contentsOf: children.prefix(max(0, 300 - pending.count - examined)))
            }
        }
        return SelectedTextResult(message: "No selected text found. This app may not expose its selection through Accessibility.")
    }
}
