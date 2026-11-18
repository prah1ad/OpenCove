import AppKit
import AudioToolbox
import CoreAudio
import EventKit
import IOBluetooth

// MARK: - Volume (CoreAudio)

/// Watches the default output device's volume and mute state.
@MainActor
final class VolumeMonitor {
    var onChange: ((Float, Bool) -> Void)?

    private var deviceID = AudioObjectID(kAudioObjectUnknown)
    private var lastLevel: Float = -1
    private var lastMuted = false
    private var deviceListener: AudioObjectPropertyListenerBlock?
    private var defaultDeviceListener: AudioObjectPropertyListenerBlock?

    private var volumeAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
        mScope: kAudioDevicePropertyScopeOutput,
        mElement: kAudioObjectPropertyElementMain)
    private var muteAddress = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyMute,
        mScope: kAudioDevicePropertyScopeOutput,
        mElement: kAudioObjectPropertyElementMain)
    private var defaultDeviceAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultOutputDevice,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain)

    init() {
        let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            Task { @MainActor in self?.attachToDefaultDevice() }
        }
        defaultDeviceListener = listener
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &defaultDeviceAddress, .main, listener)
        attachToDefaultDevice()
    }

    private func attachToDefaultDevice() {
        if deviceID != AudioObjectID(kAudioObjectUnknown), let old = deviceListener {
            AudioObjectRemovePropertyListenerBlock(deviceID, &volumeAddress, .main, old)
            AudioObjectRemovePropertyListenerBlock(deviceID, &muteAddress, .main, old)
        }
        var id = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &defaultDeviceAddress, 0, nil, &size, &id)
        deviceID = id
        lastLevel = -1 // don't flash the HUD just because the output device switched
        guard id != AudioObjectID(kAudioObjectUnknown) else { return }

        let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            Task { @MainActor in self?.read() }
        }
        deviceListener = listener
        AudioObjectAddPropertyListenerBlock(id, &volumeAddress, .main, listener)
        AudioObjectAddPropertyListenerBlock(id, &muteAddress, .main, listener)
        read()
    }

    private func read() {
        var volume = Float32(0)
        var size = UInt32(MemoryLayout<Float32>.size)
        if AudioObjectGetPropertyData(deviceID, &volumeAddress, 0, nil, &size, &volume) != noErr {
            var scalar = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyVolumeScalar,
                                                    mScope: kAudioDevicePropertyScopeOutput,
                                                    mElement: kAudioObjectPropertyElementMain)
            size = UInt32(MemoryLayout<Float32>.size)
            AudioObjectGetPropertyData(deviceID, &scalar, 0, nil, &size, &volume)
        }
        var mute = UInt32(0)
        size = UInt32(MemoryLayout<UInt32>.size)
        AudioObjectGetPropertyData(deviceID, &muteAddress, 0, nil, &size, &mute)
        let muted = mute != 0

        defer { lastLevel = volume; lastMuted = muted }
        guard lastLevel >= 0, abs(volume - lastLevel) > 0.001 || muted != lastMuted else { return }
        onChange?(volume, muted)
    }
}

// MARK: - Bluetooth (IOBluetooth)

@MainActor
final class BluetoothMonitor: NSObject {
    /// name, connected, isAudioDevice
    var onChange: ((String, Bool, Bool) -> Void)?

    private var connectNotification: IOBluetoothUserNotification?
    private let startedAt = Date()

    override init() {
        super.init()
        connectNotification = IOBluetoothDevice.register(forConnectNotifications: self,
                                                         selector: #selector(deviceConnected(_:device:)))
    }

    @objc private func deviceConnected(_ note: IOBluetoothUserNotification, device: IOBluetoothDevice) {
        _ = device.register(forDisconnectNotification: self, selector: #selector(deviceDisconnected(_:device:)))
        // Registration also reports devices that were already connected at launch; skip those.
        guard Date().timeIntervalSince(startedAt) > 3 else { return }
        onChange?(device.name ?? "Bluetooth device", true, Self.isAudio(device))
    }

    @objc private func deviceDisconnected(_ note: IOBluetoothUserNotification, device: IOBluetoothDevice) {
        note.unregister()
        onChange?(device.name ?? "Bluetooth device", false, Self.isAudio(device))
    }

    private static func isAudio(_ device: IOBluetoothDevice) -> Bool {
        device.deviceClassMajor == BluetoothDeviceClassMajor(kBluetoothDeviceClassMajorAudio)
    }
}

// MARK: - Calendar (EventKit)

@MainActor
final class CalendarMonitor: ObservableObject {
    struct Upcoming: Equatable {
        var title: String
        var start: Date
    }

    @Published private(set) var next: Upcoming?
    var onReminder: ((String, Int) -> Void)?

    private let store = EKEventStore()
    private var timer: Timer?
    private var reminded = Set<String>()
    private var started = false

    func setEnabled(_ enabled: Bool) {
        if enabled { start() } else { stop() }
    }

    private func start() {
        guard !started else { return }
        started = true
        let completion: (Bool, Error?) -> Void = { [weak self] _, _ in
            Task { @MainActor in self?.check() }
        }
        if #available(macOS 14.0, *) {
            store.requestFullAccessToEvents(completion: completion)
        } else {
            store.requestAccess(to: .event, completion: completion)
        }
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.check() }
        }
    }

    private func stop() {
        started = false
        timer?.invalidate()
        timer = nil
        next = nil
    }

    private var authorized: Bool {
        let status = EKEventStore.authorizationStatus(for: .event)
        if #available(macOS 14.0, *) { return status == .fullAccess }
        return status == .authorized
    }

    private func check() {
        guard started, authorized else { return }
        let now = Date()
        let predicate = store.predicateForEvents(withStart: now, end: now.addingTimeInterval(24 * 3600), calendars: nil)
        let events = store.events(matching: predicate)
            .filter { !$0.isAllDay && $0.startDate > now.addingTimeInterval(-60) }
            .sorted { $0.startDate < $1.startDate }

        if let first = events.first {
            next = Upcoming(title: first.title ?? "Event", start: first.startDate)
        } else {
            next = nil
        }

        let lead = Double(Settings.shared.calendarLeadMinutes) * 60
        for event in events where event.startDate.timeIntervalSince(now) <= lead {
            let id = "\(event.eventIdentifier ?? event.title ?? "")@\(event.startDate.timeIntervalSince1970)"
            guard !reminded.contains(id) else { continue }
            reminded.insert(id)
            let minutes = max(0, Int((event.startDate.timeIntervalSince(now) / 60).rounded(.up)))
            onReminder?(event.title ?? "Event", minutes)
            break
        }
    }
}
