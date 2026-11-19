import AppKit
import Combine
import SwiftUI

@MainActor
final class IslandModel: ObservableObject {
    enum Mode: Equatable { case idle, music, hud, expanded }

    enum HUD: Equatable {
        case charging(level: Int)
        case lowBattery(level: Int)
        case volume(level: Float, muted: Bool)
        case bluetooth(name: String, connected: Bool, audio: Bool)
        case calendar(title: String, minutes: Int)
        case peek

        /// Changing kind cross-fades the content; same kind updates in place (e.g. volume level).
        var kind: String {
            switch self {
            case .charging: return "charging"
            case .lowBattery: return "lowBattery"
            case .volume: return "volume"
            case .bluetooth: return "bluetooth"
            case .calendar: return "calendar"
            case .peek: return "peek"
            }
        }

        var isWide: Bool {
            switch self {
            case .bluetooth, .calendar, .peek: return true
            default: return false
            }
        }
    }

    static let ear: CGFloat = 8 // the concave "shoulders" where the island meets the screen edge
    static let spring = Animation.spring(response: 0.42, dampingFraction: 0.8)

    @Published var geometry: NotchGeometry
    @Published private(set) var expanded = false
    @Published private(set) var hud: HUD?
    /// Page of the open island: 0 = now playing, 1 = calendar.
    @Published private(set) var page = 0

    let settings: Settings
    let media: NowPlaying
    let battery: BatteryMonitor
    let calendar: CalendarMonitor
    private let volume: VolumeMonitor
    private let bluetooth: BluetoothMonitor

    private var bag = Set<AnyCancellable>()
    private var hudTask: Task<Void, Never>?
    private var warnedLowBattery = false
    private var testObserver: NSObjectProtocol?

    init(geometry: NotchGeometry) {
        self.geometry = geometry
        settings = Settings.shared
        media = NowPlaying()
        battery = BatteryMonitor()
        calendar = CalendarMonitor()
        volume = VolumeMonitor()
        bluetooth = BluetoothMonitor()
        wireUp()
    }

    private func wireUp() {
        battery.$isPluggedIn
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] plugged in
                Task { @MainActor in self?.pluggedInChanged(plugged) }
            }
            .store(in: &bag)

        battery.$level
            .removeDuplicates()
            .sink { [weak self] _ in
                Task { @MainActor in self?.checkLowBattery() }
            }
            .store(in: &bag)

        volume.onChange = { [weak self] level, muted in
            guard let self, self.settings.volumeHUD else { return }
            self.show(.volume(level: level, muted: muted))
        }

        bluetooth.onChange = { [weak self] name, connected, audio in
            guard let self, self.settings.bluetoothHUD else { return }
            self.show(.bluetooth(name: name, connected: connected, audio: audio), for: self.settings.hudDuration + 0.5)
        }

        media.onTrackChange = { [weak self] in
            guard let self, self.settings.quickPeek, self.media.isPlaying else { return }
            self.show(.peek, for: self.settings.peekDuration)
        }

        calendar.onReminder = { [weak self] title, minutes in
            self?.show(.calendar(title: title, minutes: minutes), for: 6)
        }
        testObserver = NotificationCenter.default.addObserver(
            forName: .openCoveTestHUD, object: nil, queue: .main
        ) { [weak self] note in
            let kind = note.object as? String ?? ""
            Task { @MainActor in self?.showTest(kind) }
        }

        calendar.setEnabled(settings.calendarEnabled)
        settings.$calendarEnabled
            .removeDuplicates()
            .sink { [weak self] enabled in
                Task { @MainActor in self?.calendar.setEnabled(enabled) }
            }
            .store(in: &bag)
    }

    // MARK: - Derived layout

    var mode: Mode {
        if expanded { return .expanded }
        if hud != nil { return .hud }
        if media.isPlaying || (settings.showPausedMedia && media.hasTrack) { return .music }
        return .idle
    }

    /// Target size of the island for the current mode.
    var size: CGSize {
        let n = geometry.notchSize
        let base = n.width + Self.ear * 2
        switch mode {
        case .expanded: return CGSize(width: max(base + 200, 580), height: n.height + 160)
        case .hud:      return CGSize(width: base + ((hud?.isWide ?? false) ? 300 : 210), height: n.height + 4)
        case .music:    return CGSize(width: base + 88, height: n.height)
        case .idle:     return CGSize(width: base, height: n.height)
        }
    }

    // MARK: - Actions

    func setExpanded(_ value: Bool) {
        guard value != expanded else { return }
        if value { hud = nil; hudTask?.cancel() }
        withAnimation(Self.spring) { expanded = value }
        if value && settings.hapticFeedback {
            NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
        }
    }

    func setPage(_ newPage: Int) {
        let clamped = min(max(newPage, 0), 1)
        guard clamped != page else { return }
        withAnimation(Self.spring) { page = clamped }
        if settings.hapticFeedback {
            NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
        }
    }

    /// Click-to-open, used when "expand on hover" is off.
    func tapped() {
        if !expanded { setExpanded(true) }
    }

    /// Preview a notification from the Settings window.
    func showTest(_ kind: String) {
        switch kind {
        case "volume": show(.volume(level: 0.6, muted: false))
        case "charging": show(.charging(level: battery.level))
        case "lowBattery": show(.lowBattery(level: min(battery.level, settings.lowBatteryThreshold)))
        case "bluetooth": show(.bluetooth(name: "Test Headphones", connected: true, audio: true))
        case "calendar": show(.calendar(title: calendar.next?.title ?? "Test event", minutes: settings.calendarLeadMinutes), for: 6)
        case "peek": if media.hasTrack { show(.peek, for: settings.peekDuration) }
        default: break
        }
    }

    func show(_ newHUD: HUD, for seconds: Double? = nil) {
        guard !expanded else { return } // don't interrupt the open island
        NSLog("OpenCove: showing \(newHUD.kind) notification")
        withAnimation(Self.spring) { hud = newHUD }
        let duration = seconds ?? settings.hudDuration
        hudTask?.cancel()
        hudTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(duration * 1_000_000_000))
            guard !Task.isCancelled, let self else { return }
            withAnimation(Self.spring) { self.hud = nil }
        }
    }

    private func pluggedInChanged(_ plugged: Bool) {
        if plugged {
            warnedLowBattery = false
            if settings.chargingHUD { show(.charging(level: battery.level), for: settings.hudDuration + 0.8) }
        } else {
            checkLowBattery()
        }
    }

    private func checkLowBattery() {
        guard battery.hasBattery, settings.lowBatteryWarning else { return }
        if battery.isPluggedIn || battery.level > settings.lowBatteryThreshold {
            warnedLowBattery = false
            return
        }
        guard !warnedLowBattery else { return }
        warnedLowBattery = true
        show(.lowBattery(level: battery.level), for: max(settings.hudDuration, 3))
    }
}

extension Notification.Name {
    static let openCoveTestHUD = Notification.Name("OpenCoveTestHUD")
}
