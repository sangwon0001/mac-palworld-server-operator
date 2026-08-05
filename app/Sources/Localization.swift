import Foundation
import SwiftUI

/// App UI localization.
///
/// [Key design] The Korean source text doubles as the lookup key:
///   t("서버 시작")  →  ko: "서버 시작" / en: "Start Server" / ja: "サーバー起動"
/// No separate key namespace to invent, the code reads as the literal text, and
/// any untranslated entry falls back to the key itself — so you never see a blank
/// label or a raw "missing_key" on screen.
///
/// [Live switching] NSLocalizedString follows the system language, which would
/// require an app restart to change. Opening the matching .lproj bundle directly
/// instead lets the language switch take effect immediately. This was verified to
/// work in a hand-assembled .app bundle built without Xcode.
///
/// [Why no actor isolation] Some strings are built outside the main actor —
/// SettingsCatalog's static dictionary and RconClient's error descriptions. Marking
/// this @MainActor would make t() uncallable from there. Lookups are read-only and
/// the language only changes from UI interaction (main thread), so the type stays
/// unisolated and keeps the current bundle in a static instead.
final class Localization: ObservableObject {

    static let shared = Localization()

    enum Language: String, CaseIterable, Identifiable {
        case system, ko, en, ja
        var id: String { rawValue }

        /// Name shown in the picker. Each language is written in its own language.
        var displayName: String {
            switch self {
            case .system: return t("시스템 설정 따름")
            case .ko:     return "한국어"
            case .en:     return "English"
            case .ja:     return "日本語"
            }
        }
    }

    @Published private(set) var language: Language

    /// Current bundle, kept static so t() can read it from outside any actor.
    nonisolated(unsafe) private static var currentBundle: Bundle?

    private init() {
        let saved = UserDefaults.standard.string(forKey: "appLanguage") ?? ""
        language = Language(rawValue: saved) ?? .system
        Self.currentBundle = Self.loadBundle(for: language)
    }

    func setLanguage(_ new: Language) {
        guard new != language else { return }
        language = new
        UserDefaults.standard.set(new.rawValue, forKey: "appLanguage")
        Self.currentBundle = Self.loadBundle(for: new)
        // The @Published change redraws the whole UI.
    }

    /// The language code actually in effect (resolved from the system if .system).
    var resolvedCode: String {
        language == .system ? Self.systemLanguage() : language.rawValue
    }

    /// Falls back to the key (the Korean source text) when no translation exists.
    static func string(_ key: String) -> String {
        currentBundle?.localizedString(forKey: key, value: key, table: nil) ?? key
    }

    // MARK: - Internals

    private static let supported = ["ko", "en", "ja"]

    /// First supported language among the system preferences; English otherwise.
    private static func systemLanguage() -> String {
        for pref in Locale.preferredLanguages {
            // Arrives region-qualified ("ko-KR", "ja-JP"), so compare the prefix.
            let code = String(pref.prefix(2))
            if supported.contains(code) { return code }
        }
        return "en"
    }

    private static func loadBundle(for language: Language) -> Bundle? {
        let code = language == .system ? systemLanguage() : language.rawValue
        guard let path = Bundle.main.path(forResource: code, ofType: "lproj"),
              let b = Bundle(path: path) else {
            // No .lproj → nil, and string(_:) returns the Korean source text.
            return nil
        }
        return b
    }
}

// MARK: - Convenience

/// Look up a translation. The key is the Korean source text.
func t(_ key: String) -> String {
    Localization.string(key)
}

/// For sentences with interpolated values. Translations use %@ placeholders:
///   t("%@ 강퇴", player.name)  →  en: "Kick %@"
/// When argument order differs per language, use %1$@ / %2$@ in the translation.
func t(_ key: String, _ args: CVarArg...) -> String {
    String(format: Localization.string(key), arguments: args)
}
