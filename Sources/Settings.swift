import AppKit
import Foundation
import ServiceManagement
import SwiftUI

/// All user preferences, persisted in UserDefaults.
@MainActor
final class Settings: ObservableObject {
    static let shared = Settings()
    private let defaults = UserDefaults.standard

    // Behaviour
    @Published var expandOnHover: Bool { didSet { save(expandOnHover, "expandOnHover") } }
    @Published var hapticFeedback: Bool { didSet { save(hapticFeedback, "hapticFeedback") } }
    @Published var hideInFullscreen: Bool { didSet { save(hideInFullscreen, "hideInFullscreen") } }
    @Published var swipeGestures: Bool { didSet { save(swipeGestures, "swipeGestures") } }
    @Published var showPausedMedia: Bool { didSet { save(showPausedMedia, "showPausedMedia") } }

    // Notifications
    @Published var hudDuration: Double { didSet { save(hudDuration, "hudDuration") } }
    @Published var volumeHUD: Bool { didSet { save(volumeHUD, "volumeHUD") } }
    @Published var chargingHUD: Bool { didSet { save(chargingHUD, "chargingHUD") } }
    @Published var lowBatteryWarning: Bool { didSet { save(lowBatteryWarning, "lowBatteryWarning") } }
    @Published var lowBatteryThreshold: Int { didSet { save(lowBatteryThreshold, "lowBatteryThreshold") } }
    @Published var bluetoothHUD: Bool { didSet { save(bluetoothHUD, "bluetoothHUD") } }

    // Live activities
    @Published var quickPeek: Bool { didSet { save(quickPeek, "quickPeek") } }
    @Published var peekDuration: Double { didSet { save(peekDuration, "peekDuration") } }
    @Published var calendarEnabled: Bool { didSet { save(calendarEnabled, "calendarEnabled") } }
    @Published var calendarLeadMinutes: Int { didSet { save(calendarLeadMinutes, "calendarLeadMinutes") } }

    // Tuning
    @Published var notchWidthAdjust: Double { didSet { save(notchWidthAdjust, "notchWidthAdjust") } }
    @Published var notchHeightAdjust: Double { didSet { save(notchHeightAdjust, "notchHeightAdjust") } }

    private init() {
        defaults.register(defaults: [
            "expandOnHover": true, "hapticFeedback": true, "hideInFullscreen": true,
            "swipeGestures": true, "showPausedMedia": false,
            "hudDuration": 2.0, "volumeHUD": true, "chargingHUD": true,
            "lowBatteryWarning": true, "lowBatteryThreshold": 20, "bluetoothHUD": true,
            "quickPeek": true, "peekDuration": 2.5, "calendarEnabled": false, "calendarLeadMinutes": 15,
            "notchWidthAdjust": 0.0, "notchHeightAdjust": 0.0,
        ])
        expandOnHover = defaults.bool(forKey: "expandOnHover")
        hapticFeedback = defaults.bool(forKey: "hapticFeedback")
        hideInFullscreen = defaults.bool(forKey: "hideInFullscreen")
        swipeGestures = defaults.bool(forKey: "swipeGestures")
        showPausedMedia = defaults.bool(forKey: "showPausedMedia")
        hudDuration = defaults.double(forKey: "hudDuration")
        volumeHUD = defaults.bool(forKey: "volumeHUD")
        chargingHUD = defaults.bool(forKey: "chargingHUD")
        lowBatteryWarning = defaults.bool(forKey: "lowBatteryWarning")
        lowBatteryThreshold = defaults.integer(forKey: "lowBatteryThreshold")
        bluetoothHUD = defaults.bool(forKey: "bluetoothHUD")
        quickPeek = defaults.bool(forKey: "quickPeek")
        peekDuration = defaults.double(forKey: "peekDuration")
        calendarEnabled = defaults.bool(forKey: "calendarEnabled")
        calendarLeadMinutes = defaults.integer(forKey: "calendarLeadMinutes")
        notchWidthAdjust = defaults.double(forKey: "notchWidthAdjust")
        notchHeightAdjust = defaults.double(forKey: "notchHeightAdjust")
    }

    private func save(_ value: Any, _ key: String) { defaults.set(value, forKey: key) }
}

// MARK: - Settings window

@MainActor
final class SettingsWindowController {
    private var window: NSWindow?

    func show() {
        if window == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 620),
                             styleMask: [.titled, .closable, .miniaturizable],
                             backing: .buffered, defer: false)
            w.title = "OpenCove Settings"
            w.isReleasedWhenClosed = false
            w.contentView = NSHostingView(rootView: SettingsView(settings: .shared))
            w.center()
            window = w
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}

struct SettingsView: View {
    @ObservedObject var settings: Settings
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled

    var body: some View {
        Form {
            Section("General") {
                Toggle("Launch at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { enabled in
                        do {
                            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
                        } catch {
                            NSLog("OpenCove: launch-at-login change failed: \(error)")
                        }
                    }
                Toggle("Hide in fullscreen", isOn: $settings.hideInFullscreen)
            }

            Section("Behaviour") {
                Toggle("Expand on hover (otherwise click)", isOn: $settings.expandOnHover)
                Toggle("Haptic feedback", isOn: $settings.hapticFeedback)
                Toggle("Trackpad gestures", isOn: $settings.swipeGestures)
                Text("Swipe down to open, up to close, left/right to skip tracks.")
                    .font(.caption).foregroundStyle(.secondary)
                Toggle("Keep music activity visible while paused", isOn: $settings.showPausedMedia)
            }

            Section("Notifications") {
                LabeledSlider(title: "Duration", value: $settings.hudDuration, range: 1...5, step: 0.5, format: "%.1fs")
                Toggle("Volume", isOn: $settings.volumeHUD)
                Toggle("Charging", isOn: $settings.chargingHUD)
                Toggle("Low battery warning", isOn: $settings.lowBatteryWarning)
                if settings.lowBatteryWarning {
                    Stepper("Warn at \(settings.lowBatteryThreshold)%", value: $settings.lowBatteryThreshold, in: 5...50, step: 5)
                }
                Toggle("Bluetooth devices", isOn: $settings.bluetoothHUD)
            }

            Section("Live Activities") {
                Toggle("Quick peek when the track changes", isOn: $settings.quickPeek)
                if settings.quickPeek {
                    LabeledSlider(title: "Peek duration", value: $settings.peekDuration, range: 1...5, step: 0.5, format: "%.1fs")
                }
                Toggle("Upcoming calendar events", isOn: $settings.calendarEnabled)
                if settings.calendarEnabled {
                    Stepper("Remind \(settings.calendarLeadMinutes) min before", value: $settings.calendarLeadMinutes, in: 1...60)
                }
            }

            Section("Notch Tuning") {
                LabeledSlider(title: "Width", value: $settings.notchWidthAdjust, range: -20...40, step: 1, format: "%+.0f px")
                LabeledSlider(title: "Height", value: $settings.notchHeightAdjust, range: -10...20, step: 1, format: "%+.0f px")
            }
        }
        .formStyle(.grouped)
        .frame(width: 480, height: 620)
    }
}

struct LabeledSlider: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    let format: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title)
                Spacer()
                Text(String(format: format, value)).monospacedDigit().foregroundStyle(.secondary)
            }
            Slider(value: $value, in: range, step: step)
        }
    }
}
