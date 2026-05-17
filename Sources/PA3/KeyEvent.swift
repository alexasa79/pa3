import AppKit
import SwiftUI

enum PAKey {
    case character
    case enter
    case escape
    case space
    case left
    case right
    case up
    case down
    case backspace
    case delete
    case home
    case end
}

struct KeyEvent {
    let key: PAKey
    let characters: String
    let shift: Bool
    let control: Bool
    let option: Bool
    let command: Bool

    init(nsEvent: NSEvent) {
        let modifiers = nsEvent.modifierFlags
        shift = modifiers.contains(.shift)
        control = modifiers.contains(.control)
        option = modifiers.contains(.option)
        command = modifiers.contains(.command)

        switch nsEvent.keyCode {
        case 36, 76:
            key = .enter
            characters = "\n"
        case 53:
            key = .escape
            characters = ""
        case 49:
            key = .space
            characters = " "
        case 123:
            key = .left
            characters = ""
        case 124:
            key = .right
            characters = ""
        case 125:
            key = .down
            characters = ""
        case 126:
            key = .up
            characters = ""
        case 51:
            key = .backspace
            characters = ""
        case 117:
            key = .delete
            characters = ""
        case 115:
            key = .home
            characters = ""
        case 119:
            key = .end
            characters = ""
        default:
            key = .character
            if control, nsEvent.keyCode == 8 {
                characters = "\u{3}"
            } else {
                characters = nsEvent.charactersIgnoringModifiers ?? nsEvent.characters ?? ""
            }
        }
    }
}

struct KeyCatcher: NSViewRepresentable {
    let onKey: (KeyEvent) -> Void

    @MainActor func makeNSView(context: Context) -> View {
        let view = View()
        view.onKey = onKey
        DispatchQueue.main.async {
            view.window?.makeFirstResponder(view)
        }
        return view
    }

    @MainActor func updateNSView(_ nsView: View, context: Context) {
        nsView.onKey = onKey
        DispatchQueue.main.async {
            nsView.window?.makeFirstResponder(nsView)
        }
    }

    final class View: NSView {
        var onKey: ((KeyEvent) -> Void)?
        override var acceptsFirstResponder: Bool { true }

        override func keyDown(with event: NSEvent) {
            onKey?(KeyEvent(nsEvent: event))
        }
    }
}
