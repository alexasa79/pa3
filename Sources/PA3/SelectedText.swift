import ApplicationServices
import Foundation

struct SelectedTextResult: Sendable {
    var text: String?
    var message: String
}

enum SelectedText {
    enum ReadFailure: Error {
        case incomplete, tooLarge
    }

    static func substring(_ text: String, range: CFRange) -> String? {
        guard range.location >= 0, range.length > 0, range.location <= text.utf16.count,
              range.length <= text.utf16.count - range.location,
              let range = Range(NSRange(location: range.location, length: range.length), in: text) else { return nil }
        return String(text[range])
    }

    // AX children are in reading order. A parent's selection covers its subtree;
    // visiting those children again would repeat text. Equal text in distinct
    // elements, however, may be intentionally repeated paragraphs.
    static func collect<Node>(from root: Node, nodeLimit: Int = 300,
                              isSame: (Node, Node) -> Bool,
                              inspect: (Node) throws -> (text: String?, children: [Node])) throws -> String? {
        var pending = [root], visited: [Node] = []
        var parts: [String] = []
        var characterCount = 0
        while let current = pending.popLast() {
            guard !visited.contains(where: { isSame($0, current) }) else { continue }
            guard visited.count < nodeLimit else { throw ReadFailure.incomplete }
            visited.append(current)
            let content = try inspect(current)
            if let text = content.text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                characterCount += text.count + (parts.isEmpty ? 0 : 2)
                guard characterCount <= 100_000 else { throw ReadFailure.tooLarge }
                parts.append(text)
            } else {
                pending.append(contentsOf: content.children.reversed())
            }
        }
        return parts.isEmpty ? nil : parts.joined(separator: "\n\n")
    }

    static func read(pid: pid_t) -> SelectedTextResult {
        guard AXIsProcessTrusted() else {
            return SelectedTextResult(message: "Allow PA3 in System Settings → Privacy & Security → Accessibility.")
        }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.15)
        let deadline = Date().addingTimeInterval(2)
        func check(_ error: AXError) throws {
            guard Date() < deadline, error != .cannotComplete, error != .invalidUIElement else {
                throw ReadFailure.incomplete
            }
        }
        func attribute(_ element: AXUIElement, _ name: String) throws -> CFTypeRef? {
            try check(.success)
            AXUIElementSetMessagingTimeout(element, 0.15)
            var value: CFTypeRef?
            let error = AXUIElementCopyAttributeValue(element, name as CFString, &value)
            try check(error)
            return error == .success ? value : nil
        }
        func element(_ value: CFTypeRef?) -> AXUIElement? {
            guard let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
            return (value as! AXUIElement)
        }
        func selected(_ item: AXUIElement) throws -> String? {
            if let text = try attribute(item, kAXSelectedTextAttribute) as? String,
               !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return text }
            guard let raw = try attribute(item, kAXSelectedTextRangeAttribute), CFGetTypeID(raw) == AXValueGetTypeID() else { return nil }
            let value = raw as! AXValue
            guard AXValueGetType(value) == .cfRange else { return nil }
            var range = CFRange()
            guard AXValueGetValue(value, .cfRange, &range), range.location >= 0, range.length > 0 else { return nil }
            guard range.length <= 200_000 else { throw ReadFailure.tooLarge }
            var text: CFTypeRef?
            AXUIElementSetMessagingTimeout(item, 0.15)
            try check(.success)
            let error = AXUIElementCopyParameterizedAttributeValue(item, kAXStringForRangeParameterizedAttribute as CFString, value, &text)
            try check(error)
            if error == .success, let text = text as? String { return text }
            if let text = try attribute(item, kAXValueAttribute) as? String { return substring(text, range: range) }
            return nil
        }
        do {
            let focused = element(try attribute(app, kAXFocusedUIElementAttribute))
            // Keep a focused editor/document isolated from other controls with
            // retained selections. Static text can be just one selected paragraph,
            // so walk up to its document or window before collecting the selection.
            var root: AXUIElement?
            var ancestor = focused
            var ancestors: [AXUIElement] = []
            while let current = ancestor {
                guard ancestors.count < 30, !ancestors.contains(where: { CFEqual($0, current) }) else {
                    throw ReadFailure.incomplete
                }
                ancestors.append(current)
                if try attribute(current, kAXSubroleAttribute) as? String == kAXSecureTextFieldSubrole {
                    return SelectedTextResult(message: "Secure text fields cannot be narrated.")
                }
                let role = try attribute(current, kAXRoleAttribute) as? String
                if [kAXTextFieldRole, kAXTextAreaRole, kAXComboBoxRole, "AXWebArea", kAXWindowRole].contains(role ?? "") {
                    root = current
                    break
                }
                ancestor = element(try attribute(current, kAXParentAttribute))
            }
            if root == nil { root = element(try attribute(app, kAXFocusedWindowAttribute)) ?? focused }
            if let root, let text = try collect(from: root, isSame: { CFEqual($0, $1) }, inspect: { item in
                if try attribute(item, kAXSubroleAttribute) as? String == kAXSecureTextFieldSubrole { return (nil, []) }
                if let text = try selected(item) { return (text, []) }
                return (nil, try attribute(item, kAXChildrenAttribute) as? [AXUIElement] ?? [])
            }) {
                return SelectedTextResult(text: text, message: "Reading selection")
            }
        } catch ReadFailure.tooLarge {
            return SelectedTextResult(message: "Select less than 100,000 characters.")
        } catch {
            return SelectedTextResult(message: "Could not read the complete selection. Try selecting less text.")
        }
        return SelectedTextResult(message: "No selected text found. This app may not expose its selection through Accessibility.")
    }
}
