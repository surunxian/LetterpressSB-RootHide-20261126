import Combine
import DominantColors
import SwiftUI
import UIKit

/// SpringBoard-safe replacement for the TrollStore HUD's app-delegate proxy.
final class HudEventProxy {
    static let shared = HudEventProxy()

    let isAppInForeground = CurrentValueSubject<Bool, Never>(false)
    let isHudVisible = CurrentValueSubject<Bool, Never>(false)
    let isNowPlaying = CurrentValueSubject<Bool, Never>(false)
    let nowPlayingApp: CurrentValueSubject<String?, Never> = .init(nil)
    let nowPlayingSubtitle: CurrentValueSubject<String?, Never> = .init(nil)
    let nowPlayingArtworkColors: CurrentValueSubject<[Color]?, Never> = .init(nil)

    private let media = LPSBMediaObserver()
    private var observers: [NSObjectProtocol] = []
    private var reloadToken: Int32 = -1
    private var colorGeneration = UUID()

    private init() {
        media.isArtworkDecodingRequired = LetterpressPreferences.isAdaptiveColorEnabled
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: NSNotification.Name("LPSBMediaObserverDidChangeNotification"), object: media, queue: .main) { [weak self] _ in
            self?.mediaDidChange()
        })
        observers.append(center.addObserver(forName: NSNotification.Name("LPSBMediaObserverArtworkDidChangeNotification"), object: media, queue: .main) { [weak self] _ in
            self?.artworkDidChange()
        })
        reloadToken = LPSBNotifyCenter.registerName(LetterpressNotificationNameNeedsReload) { [weak self] in
            guard let self else { return }
            LetterpressPreferences.store.synchronize()
            self.media.isArtworkDecodingRequired = LetterpressPreferences.isAdaptiveColorEnabled
            self.updateVisibility()
            LPSBOverlayHost.refreshVisibility()
        }
        observers.append(center.addObserver(forName: UIScreen.capturedDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.updateVisibility()
            LPSBOverlayHost.refreshVisibility()
        })
        observers.append(center.addObserver(forName: UIDevice.orientationDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.updateVisibility()
            LPSBOverlayHost.refreshVisibility()
        })
        mediaDidChange()
        updateVisibility()
    }

    private func mediaDidChange() {
        isNowPlaying.send(media.isNowPlaying)
        nowPlayingApp.send(media.nowPlayingApp)
        nowPlayingSubtitle.send(media.nowPlayingSubtitle)
        updateVisibility()
    }

    private func artworkDidChange() {
        colorGeneration = UUID()
        let generation = colorGeneration
        guard LetterpressPreferences.isAdaptiveColorEnabled, let image = media.nowPlayingArtwork else {
            nowPlayingArtworkColors.send(nil)
            return
        }
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let colors = (try? image.dominantColors(max: 4))?.map(Color.init)
            DispatchQueue.main.async {
                guard let self, self.colorGeneration == generation,
                      LetterpressPreferences.isAdaptiveColorEnabled else { return }
                self.nowPlayingArtworkColors.send(colors.map { $0 + [.clear.opacity(0)] })
            }
        }
    }

    func updateVisibility() {
        let locked = LPSBEnvironment.isLocked()
        let allowedByLock = !locked || LetterpressPreferences.shouldDisplayOnLockScreen
        let allowedByCapture = !LPSBEnvironment.isScreenCaptured() || LetterpressPreferences.shouldDisplayWhenScreencast
        let visible = LetterpressPreferences.isEnabled && LPSBEnvironment.isLockStateKnown() && allowedByLock &&
            !LPSBEnvironment.isScreenBlanked() && !LPSBEnvironment.isLandscape() && allowedByCapture
        isHudVisible.send(visible)
    }
}

final class HudViewController: UIHostingController<HudContentView> {
    init() { super.init(rootView: HudContentView()) }
    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override var prefersStatusBarHidden: Bool { true }
    override var prefersHomeIndicatorAutoHidden: Bool { true }
}

@objc(LPSBPlugin)
final class LPSBPlugin: NSObject {
    @objc static func makeRootViewController() -> UIViewController? {
        guard Bundle.main.bundleIdentifier == "com.apple.springboard" else { return nil }
        _ = LetterpressResources.shared
        _ = HudEventProxy.shared // Construct the event source before HudViewModel.shared.
        _ = HudViewModel.shared
        return HudViewController()
    }

    @objc static func refresh() {
        HudEventProxy.shared.updateVisibility()
    }

    @objc static func shouldShowOverlay() -> Bool {
        HudEventProxy.shared.isHudVisible.value && HudViewModel.shared.isActivated
    }
}
