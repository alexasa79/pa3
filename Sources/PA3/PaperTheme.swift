import AppKit
import SwiftUI

/// Paper & Ink: shared surfaces and readable light/dark counterparts.
enum PaperTheme {
    static let paper = adaptive(0xDDD7CA, 0x373934)
    static let canvas = adaptive(0xFAF6EE, 0x242623)
    static let cream = adaptive(0xFAEEDD, 0x292B29)
    static let ink = adaptive(0x292B29, 0xFAEEDD)
    static let muted = adaptive(0x65645B, 0xBCB8AD)
    static let selection = adaptive(0xC9BEA8, 0x57594F)

    private static func adaptive(_ light: UInt32, _ dark: UInt32) -> NSColor {
        NSColor(name: nil) { appearance in
            let hex = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
            return NSColor(srgbRed: CGFloat((hex >> 16) & 255) / 255,
                           green: CGFloat((hex >> 8) & 255) / 255,
                           blue: CGFloat(hex & 255) / 255, alpha: 1)
        }
    }
}
