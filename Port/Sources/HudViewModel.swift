//
//  HudViewModel.swift
//  Letterpress
//
//  Created by Rachel on 8/6/2025.
//

import Combine
import SwiftUI
import UIKit
import Vortex

let LetterpressNotificationNameNeedsReload = "LetterpressNotificationNameNeedsReload"

final class HudViewModel: ObservableObject {
    static let shared = HudViewModel()
    static let characterCount = 20

    static let userDefaults = LetterpressPreferences.store

    private var cancellables = Set<AnyCancellable>()

    @Published var isActivated = false
    @Published var shuffledComponents: [String] = []
    @Published var content: String = ""

    private var reloadToken: Int32 = 0

    enum FontType: String, CaseIterable {
        case pingFang
        case helveticaNeue
        case avenirNext
        case futura
        case georgia
        case fangSong
        case kaiTi

        var displayName: LocalizedStringKey {
            switch self {
            case .pingFang:
                return "PingFang"
            case .fangSong:
                return "ZhuqueFangsong"
            case .kaiTi:
                return "LXGWWenKai"
            case .helveticaNeue:
                return "Helvetica Neue"
            case .avenirNext:
                return "Avenir Next"
            case .futura:
                return "Futura"
            case .georgia:
                return "Georgia"
            }
        }

        func renderFont(size: CGFloat) -> Font {
            switch self {
            case .pingFang:
                .system(size: size, weight: .regular, design: .default)
            case .fangSong:
                .custom("ZhuqueFangsong-Regular", size: size)
            case .kaiTi:
                .custom("LXGWWenKaiLite-Medium", size: size)
            case .helveticaNeue:
                .custom("Helvetica Neue", size: size)
            case .avenirNext:
                .custom("Avenir Next", size: size)
            case .futura:
                .custom("Futura", size: size)
            case .georgia:
                .custom("Georgia", size: size)
            }
        }
    }

    enum TokenizerMode: String, CaseIterable {
        case byCharacter
        case byWord

        var displayName: LocalizedStringKey {
            switch self {
            case .byCharacter:
                return "By Character"
            case .byWord:
                return "By Word"
            }
        }
    }

    private var storedFontType: String { LetterpressPreferences.string("fontType", FontType.pingFang.rawValue) }
    @Published var fontType: FontType = .pingFang

    private var storedTokenizerMode: String { LetterpressPreferences.string("tokenizerMode", TokenizerMode.byCharacter.rawValue) }
    @Published var tokenizerMode: TokenizerMode = .byCharacter

    private var storedWidthRatio: Double { LetterpressPreferences.number("widthRatio", 1.6) }
    @Published var widthRatio: CGFloat = 1.6

    private var storedYOffset: Double { LetterpressPreferences.number("yOffset", 0.0) }
    @Published var yOffset: CGFloat = 0.0

    private var storedYSlide: Double { LetterpressPreferences.number("ySlide", -10.0) }
    @Published var ySlide: CGFloat = -10.0

    private var storedFontSize: Double { LetterpressPreferences.number("fontSize", 20.0) }
    @Published var fontSize: CGFloat = 20.0

    private var storedBirthRate: Double { LetterpressPreferences.number("birthRate", 100.0) }
    @Published var birthRate: Double = 100.0

    private var storedLifespan: Double { LetterpressPreferences.number("lifespan", 3.0) }
    @Published var lifespan: Double = 3.0

    private var storedSpeed: Double { LetterpressPreferences.number("speed", 0.0) }
    @Published var speed: CGFloat = 0.0

    private var storedSpeedVariation: Double { LetterpressPreferences.number("speedVariation", 0.25) }
    @Published var speedVariation: CGFloat = 0.25

    private var storedBurstCount: Double { LetterpressPreferences.number("burstCount", 0) }
    @Published var burstCount: Int = 0

    private var storedBurstCountVariation: Double { LetterpressPreferences.number("burstCountVariation", 0) }
    @Published var burstCountVariation: Int = 0

    private var storedAttractionStrength: Double { LetterpressPreferences.number("attractionStrength", -1.6) }
    @Published var attractionStrength: CGFloat = -1.6

    private var storedDampingFactor: Double { LetterpressPreferences.number("dampingFactor", 1.0) }
    @Published var dampingFactor: CGFloat = 1.0

    private var storedInitialSize: Double { LetterpressPreferences.number("initialSize", 0.2) }
    @Published var initialSize: CGFloat = 0.2

    private var storedSizeMultiplier: Double { LetterpressPreferences.number("sizeMultiplier", 5.0) }
    @Published var sizeMultiplier: CGFloat = 5.0

    private var storedIsLabelEnabled: Bool { LetterpressPreferences.bool("isLabelEnabled", false) }
    @Published var isLabelEnabled: Bool = false

    private var storedLabelFontSize: Double { LetterpressPreferences.number("labelFontSize", 20.0) }
    @Published var labelFontSize: CGFloat = 20.0

    private var storedYLabelOffset: Double { LetterpressPreferences.number("yLabelOffset", 0.0) }
    @Published var yLabelOffset: CGFloat = 0.0

    private var storedOpacity: Double { LetterpressPreferences.number("opacity", 1.0) }
    @Published var opacity: CGFloat = 1.0

    private var storedColor1: String { LetterpressPreferences.string("color1", "1.0,1.0,0.0,1.0") }
    private var storedColor2: String { LetterpressPreferences.string("color2", "1.0,0.0,0.0,1.0") }
    private var storedColor3: String { LetterpressPreferences.string("color3", "1.0,1.0,1.0,0.0") }
    private var storedColor4: String { LetterpressPreferences.string("color4", "1.0,1.0,1.0,0.0") }

    @Published var colors: [VortexSystem.Color] = []
    @Published var suggestedColors: [VortexSystem.Color]?
    private var selectedApplications: Set<String> = []
    private var masterEnabled = false

    init() {
        masterEnabled = LetterpressPreferences.isEnabled
#if os(iOS)
        let eventProxy = HudEventProxy.shared

        selectedApplications = LetterpressPreferences.selectedApplications

        // Business activation owns the SwiftUI/Vortex lifetime, not permission
        // to display it. Lock/blank/capture changes hide the native window via
        // LPSBPlugin.shouldShowOverlay; they must not tear down the renderer and
        // replay HudContentView's activation fade on every unlock.
        Publishers.CombineLatest(
            eventProxy.isNowPlaying,
            eventProxy.nowPlayingApp
        )
        .sink { [unowned self] (isNowPlaying, nowPlayingApp) in
            let newActivated = masterEnabled && isNowPlaying && isEligibleNowPlayingApp(nowPlayingApp)
            if isActivated != newActivated {
#if DEBUG
                print("now playing: \(isNowPlaying), app: \(nowPlayingApp ?? "")")
#endif
                isActivated = newActivated
            }
        }
        .store(in: &cancellables)

        eventProxy.nowPlayingSubtitle
            .sink { [unowned self] subtitle in
                updateContent(subtitle)
            }
            .store(in: &cancellables)

        eventProxy.nowPlayingArtworkColors
            .sink { [unowned self] colors in
#if DEBUG
                print("artwork colors: \(String(describing: colors ?? []))")
#endif
                suggestedColors = colors?.map(VortexSystem.Color.init)
            }
            .store(in: &cancellables)

        reloadToken = LPSBNotifyCenter.registerName(LetterpressNotificationNameNeedsReload) { [weak self] in
            guard let self else { return }
            Self.userDefaults.synchronize()
            self.reloadUserDefaults()
            HudEventProxy.shared.updateVisibility()
        }

        reloadUserDefaults()
#else
        isActivated = true
        reloadUserDefaults()
#endif
    }

    private func reloadUserDefaults() {
        masterEnabled = LetterpressPreferences.isEnabled
        fontType = FontType(rawValue: storedFontType) ?? .pingFang
        tokenizerMode = TokenizerMode(rawValue: storedTokenizerMode) ?? .byCharacter
        widthRatio = CGFloat(storedWidthRatio)
        yOffset = CGFloat(storedYOffset)
        ySlide = CGFloat(storedYSlide)
        fontSize = CGFloat(storedFontSize)
        birthRate = storedBirthRate
        lifespan = storedLifespan
        speed = CGFloat(storedSpeed)
        speedVariation = CGFloat(storedSpeedVariation)
        burstCount = Int(round(storedBurstCount))
        burstCountVariation = Int(round(storedBurstCountVariation))
        attractionStrength = CGFloat(storedAttractionStrength)
        dampingFactor = CGFloat(storedDampingFactor)
        initialSize = CGFloat(storedInitialSize)
        sizeMultiplier = CGFloat(storedSizeMultiplier)
        opacity = CGFloat(storedOpacity)
        isLabelEnabled = storedIsLabelEnabled
        labelFontSize = storedLabelFontSize
        yLabelOffset = CGFloat(storedYLabelOffset)
        let rawColors = [
            parseColor(from: storedColor1),
            parseColor(from: storedColor2),
            parseColor(from: storedColor3),
            parseColor(from: storedColor4),
        ].filter { $0.opacity > 1e-3 }
        colors = rawColors + [.clear.opacity(0)]
        selectedApplications = LetterpressPreferences.selectedApplications
        let current = content
        content = "\u{0000}"
        updateContent(current)
        refreshActivation()
    }

    private func parseColor(from string: String) -> VortexSystem.Color {
        let components = string.split(separator: ",").compactMap { Double($0) }
        guard components.count == 4, components.allSatisfy({ $0.isFinite && (0...1).contains($0) }) else { return .clear }
        return VortexSystem.Color(red: components[0], green: components[1], blue: components[2], opacity: components[3])
    }

    // Never run the original App preview timer inside SpringBoard. Preference
    // reloads must use the same business-only activation as media updates.
    private func refreshActivation() {
        let source = HudEventProxy.shared
        let activated = masterEnabled && source.isNowPlaying.value
            && isEligibleNowPlayingApp(source.nowPlayingApp.value)
        if isActivated != activated { isActivated = activated }
    }

    deinit { LPSBNotifyCenter.cancel(reloadToken) }

    private func updateContent(_ content: String?) {
        let trimmedContent = content?
            .components(separatedBy: .whitespacesAndNewlines).joined(separator: " ")

        guard self.content != trimmedContent else {
            return
        }

#if DEBUG
        print("subtitle: \(trimmedContent ?? "")")
#endif

        self.content = trimmedContent ?? ""
        if let comps = trimmedContent?.hudTokenized(
            byCharacter: tokenizerMode == .byCharacter,
            minimumCount: 20,
            shuffled: true
        ), !comps.isEmpty {
            self.shuffledComponents = comps
        } else {
            self.shuffledComponents = Array(repeating: "⬤", count: 20)
        }
    }

    private func isEligibleNowPlayingApp(_ app: String?) -> Bool {
        guard let app else { return false }
        return selectedApplications.contains(app)
    }
}

extension VortexSystem.Color {
    init(_ color: Color) {
#if os(iOS)
        let cgColor = UIColor(color).cgColor
#else
        let cgColor = NSColor(color).cgColor
#endif
        if cgColor.numberOfComponents == 1 {
            self.init(white: cgColor.components![0])
        } else if cgColor.numberOfComponents == 2 {
            self.init(white: cgColor.components![0], opacity: cgColor.components![1])
        } else if cgColor.numberOfComponents == 3 {
            self.init(red: cgColor.components![0],
                      green: cgColor.components![1],
                      blue: cgColor.components![2])
        } else if cgColor.numberOfComponents == 4 {
            self.init(red: cgColor.components![0],
                      green: cgColor.components![1],
                      blue: cgColor.components![2],
                      opacity: cgColor.components![3])
        } else {
            self.init(white: 1, opacity: 0)
        }
    }
}
