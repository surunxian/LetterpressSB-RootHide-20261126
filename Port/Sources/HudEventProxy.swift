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
    weak var rootViewController: LPSBRootViewController?
    private var isWindowRefreshPending = false
    // The vendor getters/setter use dispatch_sync on the media queue. Never wait
    // for that queue in SpringBoard's main-thread lock/wake notification path.
    private let mediaReadQueue = DispatchQueue(label: "LetterpressSB.media-read", qos: .utility)
    private var isMediaReadPending = false
    private var mediaReadRequested = false
    // Refresh these only at init / the explicit preference notification, not on wake.
    private var isEnabled = LetterpressPreferences.isEnabled
    private var displayOnLockScreen = LetterpressPreferences.shouldDisplayOnLockScreen
    private var displayWhenScreencast = LetterpressPreferences.shouldDisplayWhenScreencast
    private var adaptiveColorEnabled = LetterpressPreferences.isAdaptiveColorEnabled

    private init() {
        setArtworkDecodingRequired(adaptiveColorEnabled)
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
            self.isEnabled = LetterpressPreferences.isEnabled
            self.displayOnLockScreen = LetterpressPreferences.shouldDisplayOnLockScreen
            self.displayWhenScreencast = LetterpressPreferences.shouldDisplayWhenScreencast
            self.rootViewController?.setScreenshotInvisible(!self.displayWhenScreencast)
            let adaptive = LetterpressPreferences.isAdaptiveColorEnabled
            self.adaptiveColorEnabled = adaptive
            self.setArtworkDecodingRequired(adaptive)
            if !adaptive {
                self.nowPlayingArtworkColors.send(nil)
            }
            self.updateVisibility()
            self.requestWindowRefresh()
        }
        // Orientation/lock/blank inputs are owned by LPSBOverlayHost.
        mediaDidChange()
        updateVisibility()
    }

    private func setArtworkDecodingRequired(_ required: Bool) {
        mediaReadQueue.async { [media] in
            media.isArtworkDecodingRequired = required
        }
    }

    private func mediaDidChange() {
        // One in-flight read and one dirty bit, not one queued job per event.
        guard !isMediaReadPending else { mediaReadRequested = true; return }
        isMediaReadPending = true
        mediaReadQueue.async { [weak self, media] in
            let playing = media.isNowPlaying
            let app = media.nowPlayingApp
            let subtitle = media.nowPlayingSubtitle
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.isMediaReadPending = false
                self.isNowPlaying.send(playing)
                self.nowPlayingApp.send(app)
                self.nowPlayingSubtitle.send(subtitle)
                self.requestWindowRefresh()
                if self.mediaReadRequested {
                    self.mediaReadRequested = false
                    self.mediaDidChange()
                }
            }
        }
    }

    private func requestWindowRefresh() {
        guard !isWindowRefreshPending else { return }
        isWindowRefreshPending = true
        // Never re-enter HudEventProxy.shared / HudViewModel.shared during init.
        // Let all synchronous Combine and preference subscribers settle first.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.isWindowRefreshPending = false
            LPSBOverlayHost.refreshVisibility()
        }
    }

    private func artworkDidChange() {
        if let artworkImage = media.nowPlayingArtwork {
            DispatchQueue.global(qos: .userInitiated).async {
#if DEBUG
                print("Decoding artwork image")
#endif
                guard let dominantColors = try? artworkImage.dominantColors(max: 4) else {
                    return
                }
                let convertedColors = dominantColors.map { Color($0) }
                DispatchQueue.main.async { [weak self] in
                    self?.nowPlayingArtworkColors.send(convertedColors + [.clear.opacity(0)])
                }
            }
        } else {
            nowPlayingArtworkColors.send(nil)
        }
    }

    func updateVisibility() {
        // A blank screen can only hide; showing still requires every live safety check.
        if LPSBEnvironment.isScreenBlanked() {
            if isHudVisible.value { isHudVisible.send(false) }
            return
        }
        let locked = LPSBEnvironment.isLocked()
        let allowedByLock = displayOnLockScreen || (!locked && !LPSBEnvironment.isKeychainLocked())
        // Upstream's screencast switch configures its secure-text container;
        // it does not substitute UIScreen.isCaptured for HUD root visibility.
        let visible = isEnabled && LPSBEnvironment.isLockStateKnown() && allowedByLock &&
            !LPSBEnvironment.isLandscape()
        if isHudVisible.value != visible { isHudVisible.send(visible) }
    }
}

@objc(LPSBPlugin)
final class LPSBPlugin: NSObject {
    @objc static func makeRootViewController() -> UIViewController? {
        guard Bundle.main.bundleIdentifier == "com.apple.springboard" else { return nil }
        // The original controllers use this UIKit selector. Fail closed rather
        // than invoking an unavailable private API inside SpringBoard.
        guard UIViewController.instancesRespond(to: NSSelectorFromString("_setSecurityModeForViewsLayer")) else { return nil }
        _ = LetterpressResources.shared
        _ = HudEventProxy.shared // Construct the event source before HudViewModel.shared.
        _ = HudViewModel.shared
        let root = LPSBRootViewController()
        HudEventProxy.shared.rootViewController = root
        root.setScreenshotInvisible(!LetterpressPreferences.shouldDisplayWhenScreencast)
        return root
    }

    @objc static func refresh() {
        HudEventProxy.shared.updateVisibility()
    }

    @objc static func shouldShowOverlay() -> Bool {
        HudEventProxy.shared.isHudVisible.value
    }
}
