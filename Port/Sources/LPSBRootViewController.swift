// Adapted from TRHud/HudRootViewController.swift at the pinned Letterpress
// revision. Only the standalone UIApplication-delegate/class-name/proxy
// coupling is replaced; the original controller containment and screenshot
// container are retained.
import UIKit

final class LPSBRootViewController: UIViewController {
    private let controller: UIViewController
    private var invisibleContainerView: ScreenshotInvisibleContainer?
    private var screenshotInvisible = false

    init() {
        self.controller = HudContainerViewController()
        super.init(nibName: nil, bundle: nil)
        self._setSecurityModeForViewsLayer()
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        edgesForExtendedLayout = []
        view.backgroundColor = .clear
        controller.view.backgroundColor = .clear
        controller.edgesForExtendedLayout = []
        invisibleContainerView = ScreenshotInvisibleContainer(content: controller.view)
        if let hiddenContainer = invisibleContainerView?.hiddenContainer {
            hiddenContainer.translatesAutoresizingMaskIntoConstraints = false
            addChild(controller)
            view.addSubview(hiddenContainer)
            controller.didMove(toParent: self)
            hiddenContainer.topAnchor.constraint(equalTo: view.topAnchor).isActive = true
            hiddenContainer.leadingAnchor.constraint(equalTo: view.leadingAnchor).isActive = true
            hiddenContainer.bottomAnchor.constraint(equalTo: view.bottomAnchor).isActive = true
            hiddenContainer.trailingAnchor.constraint(equalTo: view.trailingAnchor).isActive = true
        }
        // Like upstream, do not display an unprotected fallback if the private
        // secure-text content container cannot be recognised on this OS.
        setScreenshotInvisible(screenshotInvisible)
    }

    override func viewWillLayoutSubviews() {
        super.viewWillLayoutSubviews()
        controller.view.frame = view.bounds
    }

    override var prefersStatusBarHidden: Bool { true }
    override var prefersHomeIndicatorAutoHidden: Bool { true }

    @objc(_canShowWhileLocked)
    public func _canShowWhileLocked() -> Bool {
        return true
    }

    func setScreenshotInvisible(_ screenshotInvisible: Bool) {
        self.screenshotInvisible = screenshotInvisible
        guard isViewLoaded else { return }
        if screenshotInvisible {
            invisibleContainerView?.setupContainerAsHideContentInScreenshots()
        } else {
            invisibleContainerView?.setupContainerAsDisplayContentInScreenshots()
        }
    }
}
