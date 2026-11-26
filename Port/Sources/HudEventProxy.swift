import Combine
import DominantColors
import SwiftUI
import UIKit
import Vortex

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
            let adaptive = LetterpressPreferences.isAdaptiveColorEnabled
            if self.adaptiveColorEnabled != adaptive {
                self.adaptiveColorEnabled = adaptive
                self.setArtworkDecodingRequired(adaptive)
            }
            if !adaptive {
                // Invalidate before clearing, including a reload while already off.
                self.colorGeneration = UUID()
                if self.nowPlayingArtworkColors.value != nil { self.nowPlayingArtworkColors.send(nil) }
            }
            self.updateVisibility()
            self.requestWindowRefresh()
        }
        // Capture changes are already observed by LPSBOverlayHost before this
        // singleton is created. Keep one policy evaluation per capture event.
        observers.append(center.addObserver(forName: UIDevice.orientationDidChangeNotification, object: nil, queue: .main) { _ in
            LPSBOverlayHost.refreshVisibility()
        })
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
                if self.isNowPlaying.value != playing { self.isNowPlaying.send(playing) }
                if self.nowPlayingApp.value != app { self.nowPlayingApp.send(app) }
                if self.nowPlayingSubtitle.value != subtitle { self.nowPlayingSubtitle.send(subtitle) }
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
        colorGeneration = UUID()
        let generation = colorGeneration
        guard adaptiveColorEnabled, let image = media.nowPlayingArtwork else {
            nowPlayingArtworkColors.send(nil)
            return
        }
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let colors = (try? image.dominantColors(max: 4))?.map(Color.init)
            DispatchQueue.main.async {
                guard let self, self.colorGeneration == generation,
                      self.adaptiveColorEnabled else { return }
                self.nowPlayingArtworkColors.send(colors.map { $0 + [.clear.opacity(0)] })
            }
        }
    }

    func updateVisibility() {
        // A blank screen can only hide; showing still requires every live safety check.
        if LPSBEnvironment.isScreenBlanked() {
            if isHudVisible.value { isHudVisible.send(false) }
            return
        }
        let locked = LPSBEnvironment.isLocked()
        let allowedByLock = !locked || displayOnLockScreen
        let allowedByCapture = !LPSBEnvironment.isScreenCaptured() || displayWhenScreencast
        let visible = isEnabled && LPSBEnvironment.isLockStateKnown() && allowedByLock &&
            !LPSBEnvironment.isLandscape() && allowedByCapture
        if isHudVisible.value != visible { isHudVisible.send(visible) }
    }
}

// Keep the original visual views and their state alive, but never run a hidden
// Canvas timeline. Visibility remains governed by the unchanged native policy.
private struct LPSBRootView: View {
    @ObservedObject private var vm = HudViewModel.shared
    @State private var isPolicyVisible = false

    var body: some View {
        HudContentView()
            .environment(\.lpsbVortexRenderingPaused, !isPolicyVisible || !vm.isActivated)
            .onReceive(HudEventProxy.shared.isHudVisible.removeDuplicates()) { visible in
                isPolicyVisible = visible
            }
    }
}

private final class HudViewController: UIHostingController<LPSBRootView> {
    init() { super.init(rootView: LPSBRootView()) }
    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func viewDidLoad() {
        super.viewDidLoad()
        // The TrollStore container cleared the hosting view as well as its window.
        // This controller is the SpringBoard window's root, so preserve that here.
        view.backgroundColor = .clear
        view.isOpaque = false
    }
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
