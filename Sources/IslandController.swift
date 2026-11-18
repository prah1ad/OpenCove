import AppKit
import Combine
import SwiftUI

/// Measures the hardware notch (or fakes one on displays without it), plus the user's tuning offsets.
struct NotchGeometry: Equatable {
    var notchSize: CGSize
    var hasNotch: Bool

    @MainActor
    init(screen: NSScreen, settings: Settings = .shared) {
        let top = screen.safeAreaInsets.top
        var size: CGSize
        if top > 0, let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea {
            size = CGSize(width: screen.frame.width - left.width - right.width, height: top)
            hasNotch = true
        } else {
            let menuBar = screen.frame.maxY - screen.visibleFrame.maxY
            size = CGSize(width: 190, height: max(menuBar, 24))
            hasNotch = false
        }
        size.width = max(80, size.width + settings.notchWidthAdjust)
        size.height = max(18, size.height + settings.notchHeightAdjust)
        notchSize = size
    }
}

/// Owns the floating panel, keeps it pinned over the notch, and drives hover, gestures and fullscreen hiding.
@MainActor
final class IslandController {
    /// The panel is a fixed transparent canvas; the island animates inside it.
    static let canvas = CGSize(width: 720, height: 320)

    private let model: IslandModel
    private let settings: Settings
    private var screen: NSScreen
    private var panel: NSPanel!
    private var pollTimer: Timer?
    private var fullscreenTimer: Timer?
    private var observers: [NSObjectProtocol] = []
    private var scrollMonitor: Any?
    private var bag = Set<AnyCancellable>()

    private var hoverStart: Date?
    private var leaveStart: Date?
    private var hiddenForFullscreen = false
    private var scrollAccum = CGSize.zero
    private var scrollFired = false

    init() {
        settings = Settings.shared
        screen = IslandController.pickScreen()
        model = IslandModel(geometry: NotchGeometry(screen: screen))
        panel = makePanel()
        layout()
        panel.orderFrontRegardless()

        // Poll the cursor instead of relying on tracking areas: works even while the
        // panel ignores mouse events, and never needs Accessibility permission.
        pollTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        fullscreenTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.updateFullscreenVisibility() }
        }
        observers.append(NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.screensChanged() }
        })
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.updateFullscreenVisibility() }
        })

        // Notch tuning sliders resize the island live.
        settings.$notchWidthAdjust.combineLatest(settings.$notchHeightAdjust)
            .dropFirst()
            .sink { [weak self] _ in
                Task { @MainActor in self?.screensChanged() }
            }
            .store(in: &bag)

        // Trackpad swipes over the island. Scroll events reach the panel under the cursor even
        // when OpenCove isn't the active app.
        scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            let fingerDX = event.isDirectionInvertedFromDevice ? event.scrollingDeltaX : -event.scrollingDeltaX
            let fingerDY = event.isDirectionInvertedFromDevice ? event.scrollingDeltaY : -event.scrollingDeltaY
            let phase = event.phase
            let momentum = event.momentumPhase
            Task { @MainActor in self?.handleScroll(dx: fingerDX, dy: fingerDY, phase: phase, momentum: momentum) }
            return event
        }
    }

    private static func pickScreen() -> NSScreen {
        NSScreen.screens.first { $0.safeAreaInsets.top > 0 } ?? NSScreen.main ?? NSScreen.screens[0]
    }

    private func makePanel() -> NSPanel {
        let p = NSPanel(contentRect: .zero,
                        styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = false
        p.level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 3) // above the menu bar
        p.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        p.isMovable = false
        p.hidesOnDeactivate = false
        p.ignoresMouseEvents = true

        let root = IslandView(model: model, media: model.media, battery: model.battery,
                              calendar: model.calendar, settings: settings)
        let host = FirstMouseHostingView(rootView: root)
        host.sizingOptions = []
        host.frame = NSRect(origin: .zero, size: Self.canvas)
        host.autoresizingMask = [.width, .height]
        p.contentView = host
        return p
    }

    private func layout() {
        let f = screen.frame
        let c = Self.canvas
        panel.setFrame(NSRect(x: f.midX - c.width / 2, y: f.maxY - c.height, width: c.width, height: c.height),
                       display: true)
    }

    private func screensChanged() {
        screen = Self.pickScreen()
        model.geometry = NotchGeometry(screen: screen)
        layout()
    }

    /// The island's current target rect, in screen coordinates.
    private func islandRect() -> CGRect {
        let s = model.size
        let f = screen.frame
        return CGRect(x: f.midX - s.width / 2, y: f.maxY - s.height, width: s.width, height: s.height)
    }

    // MARK: - Hover

    private func tick() {
        guard !hiddenForFullscreen else { return }
        let inside = islandRect().insetBy(dx: -6, dy: -6).contains(NSEvent.mouseLocation)

        // Only capture clicks while the cursor is over the island, so the transparent
        // canvas never blocks the menu bar or windows underneath.
        if panel.ignoresMouseEvents == inside { panel.ignoresMouseEvents = !inside }

        let now = Date()
        if inside {
            leaveStart = nil
            guard settings.expandOnHover, !model.expanded else { hoverStart = nil; return }
            if let start = hoverStart {
                if now.timeIntervalSince(start) > 0.12 {
                    hoverStart = nil
                    model.setExpanded(true)
                }
            } else {
                hoverStart = now
            }
        } else {
            hoverStart = nil
            guard model.expanded else { leaveStart = nil; return }
            if let start = leaveStart {
                if now.timeIntervalSince(start) > 0.3 {
                    leaveStart = nil
                    model.setExpanded(false)
                }
            } else {
                leaveStart = now
            }
        }
    }

    // MARK: - Gestures

    private func handleScroll(dx: CGFloat, dy: CGFloat, phase: NSEvent.Phase, momentum: NSEvent.Phase) {
        guard settings.swipeGestures, momentum.isEmpty, !phase.isEmpty else { return } // trackpad only, no momentum
        if phase.contains(.began) {
            scrollAccum = .zero
            scrollFired = false
        }
        scrollAccum.width += dx
        scrollAccum.height += dy
        if phase.contains(.ended) || phase.contains(.cancelled) {
            scrollAccum = .zero
            scrollFired = false
            return
        }
        guard !scrollFired else { return }

        let w = scrollAccum.width, h = scrollAccum.height
        if abs(w) > 50, abs(w) > abs(h) * 1.5 {
            scrollFired = true
            guard model.media.hasTrack else { return }
            if w < 0 { model.media.next() } else { model.media.previous() }
            if settings.hapticFeedback {
                NSHapticFeedbackManager.defaultPerformer.perform(.generic, performanceTime: .now)
            }
        } else if abs(h) > 30, abs(h) > abs(w) {
            scrollFired = true
            model.setExpanded(h > 0) // fingers down opens, up closes
        }
    }

    // MARK: - Fullscreen

    private func updateFullscreenVisibility() {
        let shouldHide = settings.hideInFullscreen && frontAppIsFullscreen()
        guard shouldHide != hiddenForFullscreen else { return }
        hiddenForFullscreen = shouldHide
        if shouldHide {
            model.setExpanded(false)
            panel.ignoresMouseEvents = true
            panel.orderOut(nil)
        } else {
            panel.orderFrontRegardless()
        }
    }

    /// Fullscreen = the menu bar is gone and the frontmost app has a window spanning the screen.
    /// (If you set the menu bar to always auto-hide, this can misfire; turn the setting off.)
    private func frontAppIsFullscreen() -> Bool {
        guard let front = NSWorkspace.shared.frontmostApplication,
              front.processIdentifier != ProcessInfo.processInfo.processIdentifier,
              let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]] else { return false }

        let menuBarLevel = Int(CGWindowLevelForKey(.mainMenuWindow))
        var menuBarVisible = false
        var frontSpansScreen = false
        let screenWidth = screen.frame.width

        for info in list {
            let layer = info[kCGWindowLayer as String] as? Int ?? -1
            let owner = info[kCGWindowOwnerName as String] as? String ?? ""
            if layer == menuBarLevel && owner == "Window Server" { menuBarVisible = true }

            guard layer == 0,
                  (info[kCGWindowOwnerPID as String] as? Int32) == front.processIdentifier,
                  let boundsDict = info[kCGWindowBounds as String] as? [String: Any],
                  let bounds = CGRect(dictionaryRepresentation: boundsDict as CFDictionary) else { continue }
            if abs(bounds.width - screenWidth) < 1 && bounds.minY <= 40 { frontSpansScreen = true }
        }
        return !menuBarVisible && frontSpansScreen
    }
}

/// Lets buttons respond on the first click even though the panel never becomes key.
final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
