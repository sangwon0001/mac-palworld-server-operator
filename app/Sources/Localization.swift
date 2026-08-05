import Foundation
import SwiftUI

/// 앱 UI 다국어 처리.
///
/// [설계] 한국어 원문을 그대로 키로 씁니다.
///   t("서버 시작")  →  ko: "서버 시작" / en: "Start Server" / ja: "サーバー起動"
/// 키를 따로 짓지 않아 코드가 읽히는 그대로이고, 번역이 빠진 항목은 키(=한국어)가
/// 그대로 나오므로 화면이 비거나 "missing_key" 같은 게 보이는 일이 없습니다.
///
/// [언어 전환] NSLocalizedString 은 시스템 언어를 따르므로 앱 안에서 바꾸려면
/// 재시작이 필요합니다. 대신 해당 .lproj 번들을 직접 열어 조회하면
/// 재시작 없이 즉시 바뀝니다. Xcode 없이 손으로 만든 .app 번들에서도
/// 이 방식이 동작하는 것을 확인했습니다.
///
/// [액터 격리를 두지 않은 이유] SettingsCatalog 의 static 사전과
/// RconClient 의 오류 메시지처럼 메인 액터 밖에서 만들어지는 문자열이 있어,
/// @MainActor 를 붙이면 그곳에서 t() 를 부를 수 없습니다.
/// 번역 조회는 읽기 전용이고 언어 변경은 UI 조작(메인 스레드)에서만 일어나므로
/// 격리 없이 두고, 대신 현재 번들을 static 으로 보관합니다.
final class Localization: ObservableObject {

    static let shared = Localization()

    enum Language: String, CaseIterable, Identifiable {
        case system, ko, en, ja
        var id: String { rawValue }

        /// 선택 목록에 보일 이름. 각 언어를 그 언어로 적습니다.
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

    /// 현재 번들. t() 가 액터 밖에서도 읽을 수 있도록 static 으로 둡니다.
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
        // @Published 변경으로 화면 전체가 다시 그려집니다.
    }

    /// 실제로 적용되는 언어 코드 (system 이면 시스템 설정에서 해석).
    var resolvedCode: String {
        language == .system ? Self.systemLanguage() : language.rawValue
    }

    /// 번역이 없으면 키(한국어 원문)를 그대로 돌려줍니다.
    static func string(_ key: String) -> String {
        currentBundle?.localizedString(forKey: key, value: key, table: nil) ?? key
    }

    // MARK: - 내부

    private static let supported = ["ko", "en", "ja"]

    /// 시스템 선호 언어 중 우리가 지원하는 첫 번째. 없으면 영어.
    private static func systemLanguage() -> String {
        for pref in Locale.preferredLanguages {
            // "ko-KR", "ja-JP" 처럼 지역이 붙어 오므로 앞부분만 봅니다.
            let code = String(pref.prefix(2))
            if supported.contains(code) { return code }
        }
        return "en"
    }

    private static func loadBundle(for language: Language) -> Bundle? {
        let code = language == .system ? systemLanguage() : language.rawValue
        guard let path = Bundle.main.path(forResource: code, ofType: "lproj"),
              let b = Bundle(path: path) else {
            // .lproj 가 없으면 nil → string(_:) 이 한국어 원문을 돌려줍니다.
            return nil
        }
        return b
    }
}

// MARK: - 짧은 호출 형태

/// 번역 조회. 키는 한국어 원문입니다.
func t(_ key: String) -> String {
    Localization.string(key)
}

/// 값이 끼어드는 문장용. 번역문에는 %@ 자리표시자를 씁니다.
///   t("%@ 강퇴", player.name)  →  en: "Kick %@"
/// 자리표시자 순서가 언어마다 다르면 번역문에서 %1$@, %2$@ 로 지정하세요.
func t(_ key: String, _ args: CVarArg...) -> String {
    String(format: Localization.string(key), arguments: args)
}
