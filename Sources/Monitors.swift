import AppKit
import AudioToolbox
import CoreAudio
import EventKit
import IOBluetooth
import SwiftUI

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

    /// Every property that can report a volume change. Built-in speakers usually only report
    /// per-channel volume (elements 1 and 2), so watching the "main" element alone misses changes.
    private func watchedAddresses() -> [AudioObjectPropertyAddress] {
        var list = [volumeAddress, muteAddress]
        for element: UInt32 in [0, 1, 2] {
            list.append(AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyVolumeScalar,
                                                   mScope: kAudioDevicePropertyScopeOutput,
                                                   mElement: element))
            list.append(AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyMute,
                                                   mScope: kAudioDevicePropertyScopeOutput,
                                                   mElement: element))
        }
        return list
    }

    private func attachToDefaultDevice() {
        if deviceID != AudioObjectID(kAudioObjectUnknown), let old = deviceListener {
            for var address in watchedAddresses() where AudioObjectHasProperty(deviceID, &address) {
                AudioObjectRemovePropertyListenerBlock(deviceID, &address, .main, old)
            }
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
        var watching = 0
        for var address in watchedAddresses() where AudioObjectHasProperty(id, &address) {
            if AudioObjectAddPropertyListenerBlock(id, &address, .main, listener) == noErr { watching += 1 }
        }
        NSLog("OpenCove: watching \(watching) volume properties on output device \(id)")
        read()
    }

    private func readFloat(_ selector: AudioObjectPropertySelector, element: UInt32) -> Float32? {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioDevicePropertyScopeOutput, mElement: element)
        guard AudioObjectHasProperty(deviceID, &address) else { return nil }
        var value = Float32(0)
        var size = UInt32(MemoryLayout<Float32>.size)
        return AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &value) == noErr ? value : nil
    }

    private func readMute(element: UInt32) -> Bool? {
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyMute, mScope: kAudioDevicePropertyScopeOutput, mElement: element)
        guard AudioObjectHasProperty(deviceID, &address) else { return nil }
        var value = UInt32(0)
        var size = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &value) == noErr ? value != 0 : nil
    }

    private func read() {
        // Prefer the overall volume; otherwise average the left/right channels.
        let volume: Float32
        if let main = readFloat(kAudioHardwareServiceDeviceProperty_VirtualMainVolume, element: kAudioObjectPropertyElementMain) {
            volume = main
        } else if let main = readFloat(kAudioDevicePropertyVolumeScalar, element: 0) {
            volume = main
        } else {
            let channels = [readFloat(kAudioDevicePropertyVolumeScalar, element: 1),
                            readFloat(kAudioDevicePropertyVolumeScalar, element: 2)].compactMap { $0 }
            guard !channels.isEmpty else { return } // device has no software volume (e.g. HDMI)
            volume = channels.reduce(0, +) / Float32(channels.count)
        }
        let muted = readMute(element: 0) ?? readMute(element: 1) ?? false

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
        var isAllDay: Bool = false
        var color: Color = .red
    }

    enum Status: Equatable { case off, waiting, denied, ready }

    @Published private(set) var next: Upcoming?
    /// The next few events this week, for the calendar page.
    @Published private(set) var upcoming: [Upcoming] = []
    /// Days of the current month that have at least one event.
    @Published private(set) var eventDays: Set<Int> = []
    @Published private(set) var status: Status = .off
    var onReminder: ((String, Int) -> Void)?

    private let store = EKEventStore()
    private var timer: Timer?
    private var reminded = Set<String>()
    private var started = false
    private var storeObserver: NSObjectProtocol?

    func setEnabled(_ enabled: Bool) {
        if enabled { start() } else { stop() }
    }

    private func start() {
        guard !started else { return }
        started = true
        status = .waiting
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
        storeObserver = NotificationCenter.default.addObserver(
            forName: .EKEventStoreChanged, object: store, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.check() }
        }
    }

    private func stop() {
        started = false
        timer?.invalidate()
        timer = nil
        if let storeObserver { NotificationCenter.default.removeObserver(storeObserver) }
        storeObserver = nil
        next = nil
        upcoming = []
        eventDays = []
        status = .off
    }

    private var authorized: Bool {
        let status = EKEventStore.authorizationStatus(for: .event)
        if #available(macOS 14.0, *) { return status == .fullAccess }
        return status == .authorized
    }

    private func check() {
        guard started else { return }
        guard authorized else {
            let raw = EKEventStore.authorizationStatus(for: .event)
            status = raw == .notDetermined ? .waiting : .denied
            NSLog("OpenCove: calendar access not granted (status \(raw.rawValue))")
            return
        }
        status = .ready
        let now = Date()
        let cal = Calendar.current
        let monthStart = cal.date(from: cal.dateComponents([.year, .month], from: now)) ?? now
        let monthEnd = cal.date(byAdding: .month, value: 1, to: monthStart) ?? now
        let weekAhead = now.addingTimeInterval(7 * 24 * 3600)

        let all = store.events(matching: store.predicateForEvents(
            withStart: min(monthStart, now), end: max(monthEnd, weekAhead), calendars: nil))

        eventDays = Set(all.filter { $0.startDate >= monthStart && $0.startDate < monthEnd }
                           .map { cal.component(.day, from: $0.startDate) })

        let future = all.filter { $0.endDate > now }.sorted { $0.startDate < $1.startDate }
        upcoming = future.filter { $0.startDate < weekAhead }.prefix(3).map { event in
            Upcoming(title: event.title ?? "Event", start: event.startDate, isAllDay: event.isAllDay,
                     color: Color(nsColor: event.calendar?.color ?? .systemRed))
        }

        let events = future.filter { !$0.isAllDay && $0.startDate > now.addingTimeInterval(-60)
                                     && $0.startDate < now.addingTimeInterval(24 * 3600) }
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
