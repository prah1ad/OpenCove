import AppKit
import SwiftUI

struct TrackSnapshot {
    var title: String
    var artist: String
    var album: String
    var duration: Double
    var elapsed: Double
    var timestamp: Date
    var isPlaying: Bool
    var artworkData: Data?
    var artworkURL: URL?
    var source: NowPlaying.Source
}

@MainActor
final class NowPlaying: ObservableObject {
    enum Source: Equatable { case none, system, music, spotify }
    enum Command { case toggle, next, previous }

    @Published private(set) var title = ""
    @Published private(set) var artist = ""
    @Published private(set) var artwork: NSImage?
    @Published private(set) var accent = Color.white
    @Published private(set) var isPlaying = false
    @Published private(set) var duration: Double = 0
    @Published private(set) var elapsed: Double = 0
    @Published private(set) var timestamp = Date()
    @Published private(set) var source: Source = .none

    /// Called when a new track starts (used for the quick-peek activity).
    var onTrackChange: (() -> Void)?

    private let remote: MediaRemote?
    private let scripts: PlayerScripts
    private var timer: Timer?
    private var observers: [NSObjectProtocol] = []
    private var artworkKey = ""
    private var fetchGeneration = 0
    private var answeredGeneration = 0
    private var remoteSilentCount = 0

    var hasTrack: Bool { !title.isEmpty }

    var sourceLabel: String {
        switch source {
        case .spotify: return "Spotify"
        case .music: return "Music"
        case .system: return "Now Playing"
        case .none: return "OpenCove"
        }
    }

    init() {
        remote = MediaRemote.shared
        scripts = PlayerScripts()
        remote?.registerForNotifications()

        let names = ["kMRMediaRemoteNowPlayingInfoDidChangeNotification",
                     "kMRMediaRemoteNowPlayingApplicationIsPlayingDidChangeNotification",
                     "kMRMediaRemoteNowPlayingApplicationDidChangeNotification"]
        for name in names {
            observers.append(NotificationCenter.default.addObserver(
                forName: Notification.Name(name), object: nil, queue: .main
            ) { [weak self] _ in
                Task { @MainActor in self?.refresh() }
            })
        }
        timer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        refresh()
    }

    func currentElapsed(at date: Date) -> Double {
        guard duration > 0 else { return 0 }
        let e = isPlaying ? elapsed + date.timeIntervalSince(timestamp) : elapsed
        return min(max(e, 0), duration)
    }

    // MARK: - Fetching

    func refresh() {
        // On macOS 15.4+ MediaRemote often never calls back for third-party apps. After a few
        // silent attempts, stop asking it and go straight to Music/Spotify.
        guard let remote, remoteSilentCount < 3 else { refreshFromScripts(fallback: nil); return }

        fetchGeneration += 1
        let generation = fetchGeneration
        remote.fetch { [weak self] snap in
            Task { @MainActor in
                guard let self, generation > self.answeredGeneration else { return }
                self.answeredGeneration = generation
                self.remoteSilentCount = 0
                if let snap, snap.isPlaying {
                    self.apply(snap)
                } else {
                    // Nothing (or something paused) from the system: ask the players directly.
                    self.refreshFromScripts(fallback: snap)
                }
            }
        }
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 500_000_000)
            guard let self, self.answeredGeneration < generation else { return }
            self.answeredGeneration = generation
            self.remoteSilentCount += 1
            NSLog("OpenCove: MediaRemote didn't respond, using AppleScript")
            self.refreshFromScripts(fallback: nil)
        }
    }

    /// Reads Music/Spotify via AppleScript; uses `fallback` if neither has anything.
    private func refreshFromScripts(fallback: TrackSnapshot?) {
        scripts.poll { [weak self] snap in
            Task { @MainActor in self?.apply(snap ?? fallback) }
        }
    }

    private func apply(_ snap: TrackSnapshot?) {
        guard let snap else {
            if source != .none {
                withAnimation(IslandModel.spring) { isPlaying = false }
                title = ""; artist = ""; artwork = nil; duration = 0; elapsed = 0
                source = .none; artworkKey = ""
            }
            return
        }
        if snap.isPlaying != isPlaying {
            withAnimation(IslandModel.spring) { isPlaying = snap.isPlaying }
        }
        title = snap.title
        artist = snap.artist
        duration = snap.duration
        elapsed = snap.elapsed
        timestamp = snap.timestamp
        source = snap.source

        let key = "\(snap.title)|\(snap.artist)|\(snap.album)"
        if key != artworkKey {
            artworkKey = key
            artwork = nil
            loadArtwork(for: snap, key: key)
            onTrackChange?()
        } else if artwork == nil, let data = snap.artworkData, let img = NSImage(data: data) {
            setArtwork(img)
        }
    }

    private func loadArtwork(for snap: TrackSnapshot, key: String) {
        if let data = snap.artworkData, let img = NSImage(data: data) {
            setArtwork(img)
        } else if let url = snap.artworkURL {
            Task { @MainActor [weak self] in
                guard let (data, _) = try? await URLSession.shared.data(from: url),
                      let img = NSImage(data: data), let self, self.artworkKey == key else { return }
                self.setArtwork(img)
            }
        } else if snap.source == .music {
            scripts.musicArtwork { [weak self] data in
                Task { @MainActor in
                    guard let self, self.artworkKey == key, let data, let img = NSImage(data: data) else { return }
                    self.setArtwork(img)
                }
            }
        }
    }

    private func setArtwork(_ image: NSImage) {
        artwork = image
        accent = Color(nsColor: image.vibrantAverageColor ?? .white)
    }

    // MARK: - Controls

    func togglePlayPause() {
        elapsed = currentElapsed(at: Date())
        timestamp = Date()
        withAnimation(IslandModel.spring) { isPlaying.toggle() } // optimistic
        send(.toggle)
    }

    func next() { send(.next) }
    func previous() { send(.previous) }

    private func send(_ command: Command) {
        switch source {
        case .music, .spotify: scripts.send(command, to: source)
        default: remote?.send(command)
        }
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 350_000_000)
            self?.refresh()
        }
    }

    func openSourceApp() {
        let id: String?
        switch source {
        case .spotify: id = "com.spotify.client"
        case .music: id = "com.apple.Music"
        default: id = nil
        }
        guard let id, let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) else { return }
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
    }
}

// MARK: - MediaRemote (private framework, loaded dynamically)

final class MediaRemote {
    static let shared: MediaRemote? = MediaRemote()

    private typealias GetInfo = @convention(c) (DispatchQueue, @escaping @convention(block) (NSDictionary?) -> Void) -> Void
    private typealias GetIsPlaying = @convention(c) (DispatchQueue, @escaping @convention(block) (Bool) -> Void) -> Void
    private typealias Register = @convention(c) (DispatchQueue) -> Void
    private typealias SendCommand = @convention(c) (Int32, NSDictionary?) -> Bool

    private let getInfo: GetInfo
    private let getIsPlaying: GetIsPlaying
    private let register: Register
    private let sendCommand: SendCommand

    private init?() {
        let url = URL(fileURLWithPath: "/System/Library/PrivateFrameworks/MediaRemote.framework") as CFURL
        guard let bundle = CFBundleCreate(kCFAllocatorDefault, url),
              let a = CFBundleGetFunctionPointerForName(bundle, "MRMediaRemoteGetNowPlayingInfo" as CFString),
              let b = CFBundleGetFunctionPointerForName(bundle, "MRMediaRemoteGetNowPlayingApplicationIsPlaying" as CFString),
              let c = CFBundleGetFunctionPointerForName(bundle, "MRMediaRemoteRegisterForNowPlayingNotifications" as CFString),
              let d = CFBundleGetFunctionPointerForName(bundle, "MRMediaRemoteSendCommand" as CFString)
        else { return nil }
        getInfo = unsafeBitCast(a, to: GetInfo.self)
        getIsPlaying = unsafeBitCast(b, to: GetIsPlaying.self)
        register = unsafeBitCast(c, to: Register.self)
        sendCommand = unsafeBitCast(d, to: SendCommand.self)
    }

    func registerForNotifications() { register(.main) }

    func fetch(_ completion: @escaping (TrackSnapshot?) -> Void) {
        let isPlaying = getIsPlaying
        getInfo(.main) { dict in
            guard let info = dict as? [String: Any],
                  let title = info["kMRMediaRemoteNowPlayingInfoTitle"] as? String, !title.isEmpty else {
                completion(nil)
                return
            }
            isPlaying(.main) { playing in
                completion(TrackSnapshot(
                    title: title,
                    artist: info["kMRMediaRemoteNowPlayingInfoArtist"] as? String ?? "",
                    album: info["kMRMediaRemoteNowPlayingInfoAlbum"] as? String ?? "",
                    duration: info["kMRMediaRemoteNowPlayingInfoDuration"] as? Double ?? 0,
                    elapsed: info["kMRMediaRemoteNowPlayingInfoElapsedTime"] as? Double ?? 0,
                    timestamp: info["kMRMediaRemoteNowPlayingInfoTimestamp"] as? Date ?? Date(),
                    isPlaying: playing,
                    artworkData: info["kMRMediaRemoteNowPlayingInfoArtworkData"] as? Data,
                    artworkURL: nil,
                    source: .system))
            }
        }
    }

    func send(_ command: NowPlaying.Command) {
        let raw: Int32
        switch command {
        case .toggle: raw = 2
        case .next: raw = 4
        case .previous: raw = 5
        }
        _ = sendCommand(raw, nil)
    }
}

// MARK: - AppleScript fallback for Music & Spotify

final class PlayerScripts {
    private let queue = DispatchQueue(label: "opencove.player-scripts", qos: .utility)

    func poll(_ completion: @escaping (TrackSnapshot?) -> Void) {
        let running = Set(NSWorkspace.shared.runningApplications.compactMap { $0.bundleIdentifier })
        let spotify = running.contains("com.spotify.client")
        let music = running.contains("com.apple.Music")
        guard spotify || music else { completion(nil); return } // never launch a player
        queue.async {
            var best: TrackSnapshot?
            if spotify { best = Self.read(app: "Spotify", source: .spotify) }
            if music, let m = Self.read(app: "Music", source: .music) {
                if best == nil || (best?.isPlaying == false && m.isPlaying) { best = m }
            }
            completion(best)
        }
    }

    func musicArtwork(_ completion: @escaping (Data?) -> Void) {
        queue.async {
            let d = Self.run("tell application \"Music\" to get raw data of artwork 1 of current track")
            completion(d?.data)
        }
    }

    func send(_ command: NowPlaying.Command, to source: NowPlaying.Source) {
        let app = source == .spotify ? "Spotify" : "Music"
        let verb: String
        switch command {
        case .toggle: verb = "playpause"
        case .next: verb = "next track"
        case .previous: verb = "previous track"
        }
        queue.async { _ = Self.run("tell application \"\(app)\" to \(verb)") }
    }

    private static func read(app: String, source: NowPlaying.Source) -> TrackSnapshot? {
        let duration = source == .spotify ? "(duration of current track) / 1000" : "duration of current track"
        let art = source == .spotify ? "artwork url of current track" : "\"\""
        let script = """
        tell application "\(app)"
            if player state is stopped then return {}
            set stateText to player state as string
            return {name of current track, artist of current track, album of current track, \(duration), player position, stateText, \(art)}
        end tell
        """
        guard let d = run(script), d.numberOfItems >= 7 else { return nil }
        func str(_ i: Int) -> String { d.atIndex(i)?.stringValue ?? "" }
        func num(_ i: Int) -> Double { d.atIndex(i)?.doubleValue ?? 0 }
        let title = str(1)
        guard !title.isEmpty else { return nil }
        let artURL = str(7)
        return TrackSnapshot(title: title, artist: str(2), album: str(3),
                             duration: num(4), elapsed: num(5), timestamp: Date(),
                             isPlaying: str(6) == "playing",
                             artworkData: nil,
                             artworkURL: artURL.isEmpty ? nil : URL(string: artURL),
                             source: source)
    }

    private static func run(_ source: String) -> NSAppleEventDescriptor? {
        guard let script = NSAppleScript(source: source) else { return nil }
        var error: NSDictionary?
        let result = script.executeAndReturnError(&error)
        if let error {
            // -1743 = Automation permission denied (System Settings → Privacy & Security → Automation)
            NSLog("OpenCove: AppleScript error \(error[NSAppleScript.errorNumber] ?? "?"): \(error[NSAppleScript.errorMessage] ?? "")")
            return nil
        }
        return result
    }
}

// MARK: - Accent color from artwork

extension NSImage {
    var vibrantAverageColor: NSColor? {
        guard let cg = cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let side = 8
        var pixels = [UInt8](repeating: 0, count: side * side * 4)
        let drawn: Bool = pixels.withUnsafeMutableBytes { buf in
            guard let ctx = CGContext(data: buf.baseAddress, width: side, height: side, bitsPerComponent: 8,
                                      bytesPerRow: side * 4, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            ctx.interpolationQuality = .medium
            ctx.draw(cg, in: CGRect(x: 0, y: 0, width: side, height: side))
            return true
        }
        guard drawn else { return nil }
        var r = 0, g = 0, b = 0
        for i in stride(from: 0, to: pixels.count, by: 4) {
            r += Int(pixels[i]); g += Int(pixels[i + 1]); b += Int(pixels[i + 2])
        }
        let n = CGFloat(side * side * 255)
        let avg = NSColor(srgbRed: CGFloat(r) / n, green: CGFloat(g) / n, blue: CGFloat(b) / n, alpha: 1)
        var h: CGFloat = 0, s: CGFloat = 0, v: CGFloat = 0, a: CGFloat = 0
        avg.getHue(&h, saturation: &s, brightness: &v, alpha: &a)
        return NSColor(hue: h, saturation: min(s * 1.4, 1), brightness: max(v, 0.8), alpha: 1)
    }
}
