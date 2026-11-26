import Foundation
import UIKit
import CoreText

/// Preferences are deliberately kept out of SpringBoard's standard defaults.
enum LetterpressPreferences {
    static let domain = "com.82flex.letterpress"
    static let reloadNotification = LetterpressNotificationNameNeedsReload
    static let store: UserDefaults = {
        // Both SpringBoard and Settings run as mobile; share one explicit domain.
        let defaults = UserDefaults(suiteName: domain)!
        defaults.register(defaults: [
            "isEnabled": true,
            "selectedApplications": [String](),
            "shouldDisplayOnLockScreen": false,
            "shouldDisplayWhenScreencast": true,
            "isAdaptiveColorEnabled": false
        ])
        return defaults
    }()

    static var isEnabled: Bool { bool("isEnabled", true) }
    static var shouldDisplayOnLockScreen: Bool { bool("shouldDisplayOnLockScreen", false) }
    static var shouldDisplayWhenScreencast: Bool { bool("shouldDisplayWhenScreencast", true) }
    static var isAdaptiveColorEnabled: Bool { bool("isAdaptiveColorEnabled", false) }
    static var selectedApplications: Set<String> {
        // Only an explicit saved choice is eligible; registration defaults must
        // never silently opt an app in. An explicitly empty CSV also wins.
        let saved = store.persistentDomain(forName: domain) ?? [:]
        if let csv = saved["selectedApplicationsCSV"] as? String {
            return Set(csv.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty })
        }
        return Set(saved["selectedApplications"] as? [String] ?? [])
    }

    static func string(_ key: String, _ fallback: String) -> String {
        (store.object(forKey: key) as? String) ?? fallback
    }
    static func number(_ key: String, _ fallback: Double) -> Double {
        (store.object(forKey: key) as? NSNumber)?.doubleValue ?? fallback
    }
    static func bool(_ key: String, _ fallback: Bool) -> Bool {
        guard store.object(forKey: key) != nil else { return fallback }
        return store.bool(forKey: key)
    }
    static func notifyReload() {
        _ = store.synchronize()
        LPSBNotifyCenter.postName(reloadNotification)
    }
}

final class LetterpressResources {
    static let shared = LetterpressResources()
    let bundle: Bundle?

    private init() {
        let paths: [String] = [
            LPSBEnvironment.resourceBundlePath(),
            "/Library/Application Support/LetterpressSB.bundle",
            "/var/jb/Library/Application Support/LetterpressSB.bundle"
        ].compactMap { $0 }
        bundle = paths.lazy.compactMap(Bundle.init(path:)).first
        registerFonts()
    }

    private func registerFonts() {
        guard let bundle else { return }
        for name in ["ZhuqueFangsong-Regular.ttf", "LXGWWenKaiLite-Medium.ttf", "ChillBitmapSE_7px.ttf"] {
            guard let url = bundle.url(forResource: name, withExtension: nil) else { continue }
            var error: Unmanaged<CFError>?
            _ = CTFontManagerRegisterFontsForURL(url as CFURL, .process, &error)
        }
    }

    func localized(_ key: String) -> String {
        bundle?.localizedString(forKey: key, value: key, table: nil) ?? key
    }
}
