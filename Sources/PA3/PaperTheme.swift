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

    enum Syntax {
        static let heading1 = adaptive(0x9E2A2B, 0xF28B82)
        static let heading2 = adaptive(0x5B3F8C, 0xC5A8FF)
        static let heading3 = adaptive(0x1F6F5B, 0x7FD4B4)
        static let heading4 = adaptive(0x2B5F82, 0x82C7E8)
        static let heading5 = adaptive(0x7A5C1F, 0xE6CF7E)
        static let heading6 = adaptive(0x8A4F2B, 0xF0A978)
        static let code = adaptive(0x7A4E1D, 0xE6D38A)
        static let codeBackground = adaptive(0xEDE6D8, 0x2F312C)
        static let blockquote = adaptive(0x3D6B4A, 0x8CC497)
        static let linkText = adaptive(0x245C8A, 0x7DC4F0)
        static let linkURL = adaptive(0x6D5A82, 0xB8A6CC)
        static let image = adaptive(0x2E6F52, 0x8CD1A4)
        static let listMarker = adaptive(0x8C5E2A, 0xD9A76A)
        static let delimiter = adaptive(0x8C877C, 0x8B877D)
        static let tagDue = adaptive(0x245C8A, 0x7DC4F0)
        static let tagPriority = adaptive(0x9A4D1E, 0xE8A878)
        static let tagDone = adaptive(0x2E6F52, 0x8CD1A4)
        static let tagOpen = adaptive(0x65645B, 0xBCB8AD)
        static let tagBackground = adaptive(0xEFE8DA, 0x31342E)
        static let codeKeyword = adaptive(0x7A2E8A, 0xC99BFF)
        static let codeType = adaptive(0x1D6F6E, 0x76D4C6)
        static let codeString = adaptive(0x3A6B2C, 0xA8D47C)
        static let codeNumber = adaptive(0xA64B17, 0xF0A875)
        static let codeComment = adaptive(0x7B786D, 0x8F8C80)
        static let codeFunction = adaptive(0x22588A, 0x7EC0F2)
        static let codeVariable = adaptive(0x8A561E, 0xE6C87A)
        static let codeConstant = adaptive(0x9E2F3B, 0xF28B94)
        static let codePreprocessor = adaptive(0x8B3A62, 0xE295B8)
    }

    private static func adaptive(_ light: UInt32, _ dark: UInt32) -> NSColor {
        NSColor(name: nil) { appearance in
            let hex = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
            return NSColor(srgbRed: CGFloat((hex >> 16) & 255) / 255,
                           green: CGFloat((hex >> 8) & 255) / 255,
                           blue: CGFloat(hex & 255) / 255, alpha: 1)
        }
    }
}
