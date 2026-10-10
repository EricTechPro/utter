import AppKit
import SwiftUI
import CoreText

/// Figtree for text, EB Garamond for big numbers and titles.
/// Both are SIL Open Font License fonts from Google Fonts, bundled in Resources/Fonts.
enum Theme {
    static func registerFonts() {
        for name in ["Figtree", "EBGaramond"] {
            if let url = Bundle.main.url(forResource: name, withExtension: "ttf", subdirectory: "Fonts") {
                CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
            }
        }
    }

    static func sans(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .custom("Figtree", size: size).weight(weight)
    }

    static func serif(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .custom("EB Garamond", size: size).weight(weight)
    }

    static func nsSans(_ size: CGFloat, _ weight: NSFont.Weight = .regular) -> NSFont {
        let d = NSFontDescriptor(fontAttributes: [
            .family: "Figtree",
            .traits: [NSFontDescriptor.TraitKey.weight: weight],
        ])
        return NSFont(descriptor: d, size: size) ?? .systemFont(ofSize: size, weight: weight)
    }

    static let cream = Color(red: 0.969, green: 0.961, blue: 0.945)
    static let card = Color(red: 0.992, green: 0.988, blue: 0.980)
    static let line = Color.black.opacity(0.08)
    static let blue = Color(red: 0.145, green: 0.388, blue: 0.922)
}
