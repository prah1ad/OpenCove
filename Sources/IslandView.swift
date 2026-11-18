import SwiftUI

// MARK: - Root

struct IslandView: View {
    @ObservedObject var model: IslandModel
    @ObservedObject var media: NowPlaying
    @ObservedObject var battery: BatteryMonitor
    @ObservedObject var calendar: CalendarMonitor
    @ObservedObject var settings: Settings

    var body: some View {
        let mode = model.mode
        let size = model.size
        let expanded = mode == .expanded
        let topRadius: CGFloat = expanded ? 14 : IslandModel.ear
        let shape = NotchShape(topRadius: topRadius, bottomRadius: expanded ? 32 : 12)

        content(mode, topRadius: topRadius)
            .frame(width: size.width, height: size.height, alignment: .top)
            .background(Color.black)
            .clipShape(shape)
            .contentShape(shape)
            .onTapGesture { model.tapped() }
            .shadow(color: .black.opacity(expanded ? 0.5 : 0), radius: 16, y: 8)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .animation(IslandModel.spring, value: mode)
            .preferredColorScheme(.dark)
    }

    @ViewBuilder
    private func content(_ mode: IslandModel.Mode, topRadius: CGFloat) -> some View {
        switch mode {
        case .idle:
            Color.clear
        case .music:
            CompactMusicView(media: media)
                .padding(.horizontal, topRadius + 6)
                .transition(.blurFade)
        case .hud:
            if let hud = model.hud {
                HUDView(hud: hud, media: media)
                    .padding(.horizontal, topRadius + 8)
                    .id(hud.kind)
                    .transition(.blurFade)
            }
        case .expanded:
            ExpandedView(media: media, battery: battery, calendar: calendar,
                         showCalendar: settings.calendarEnabled,
                         headerHeight: model.geometry.notchSize.height)
                .padding(.horizontal, topRadius + 16)
                .padding(.bottom, 16)
                .transition(.blurFade)
        }
    }
}

// MARK: - Compact live activities (sit on either side of the notch)

struct CompactMusicView: View {
    @ObservedObject var media: NowPlaying

    var body: some View {
        HStack {
            ArtworkView(image: media.artwork, size: 20, corner: 5)
            Spacer()
            AudioBars(playing: media.isPlaying, color: media.accent)
        }
        .frame(maxHeight: .infinity)
    }
}

/// Short notifications that grow out of the notch: left side | (notch) | right side.
struct HUDView: View {
    let hud: IslandModel.HUD
    @ObservedObject var media: NowPlaying

    var body: some View {
        HStack(spacing: 6) {
            leading
            Spacer(minLength: 8)
            trailing
        }
        .font(.system(size: 12, weight: .semibold))
        .foregroundStyle(Color.white)
        .lineLimit(1)
        .frame(maxHeight: .infinity)
    }

    @ViewBuilder private var leading: some View {
        switch hud {
        case .charging:
            Image(systemName: "bolt.fill").foregroundStyle(Color.green)
            Text("Charging")
        case .lowBattery:
            Image(systemName: "battery.25").foregroundStyle(Color.red)
            Text("Low Battery")
        case .volume(let level, let muted):
            Image(systemName: Self.speakerSymbol(level: level, muted: muted))
                .frame(width: 20, alignment: .leading)
        case .bluetooth(let name, _, let audio):
            Image(systemName: audio ? "headphones" : "dot.radiowaves.left.and.right")
            Text(name).frame(maxWidth: 110, alignment: .leading)
        case .calendar(let title, _):
            Image(systemName: "calendar").foregroundStyle(Color.red)
            Text(title).frame(maxWidth: 110, alignment: .leading)
        case .peek:
            ArtworkView(image: media.artwork, size: 20, corner: 5)
            AudioBars(playing: media.isPlaying, color: media.accent)
        }
    }

    @ViewBuilder private var trailing: some View {
        switch hud {
        case .charging(let level):
            Text("\(level)%").foregroundStyle(Color.green)
            BatteryGlyph(level: level, charging: true)
        case .lowBattery(let level):
            Text("\(level)%").foregroundStyle(Color.red)
            BatteryGlyph(level: level, charging: false)
        case .volume(let level, let muted):
            LevelBar(fraction: muted ? 0 : CGFloat(level))
                .frame(width: 80)
        case .bluetooth(_, let connected, _):
            Text(connected ? "Connected" : "Disconnected")
                .foregroundStyle(connected ? Color.green : Color.white.opacity(0.5))
        case .calendar(_, let minutes):
            Text(minutes <= 0 ? "Now" : "in \(minutes) min").foregroundStyle(Color.red)
        case .peek:
            VStack(alignment: .leading, spacing: 0) {
                Text(media.title).font(.system(size: 11, weight: .semibold))
                Text(media.artist).font(.system(size: 10)).foregroundStyle(Color.white.opacity(0.6))
            }
            .frame(width: 120, alignment: .leading)
        }
    }

    static func speakerSymbol(level: Float, muted: Bool) -> String {
        if muted || level <= 0.001 { return "speaker.slash.fill" }
        if level < 0.34 { return "speaker.wave.1.fill" }
        if level < 0.67 { return "speaker.wave.2.fill" }
        return "speaker.wave.3.fill"
    }
}

struct LevelBar: View {
    let fraction: CGFloat

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.2))
                Capsule().fill(Color.white)
                    .frame(width: geo.size.width * min(max(fraction, 0), 1))
            }
        }
        .frame(height: 5)
        .animation(.easeOut(duration: 0.12), value: fraction)
    }
}

// MARK: - Expanded

struct ExpandedView: View {
    @ObservedObject var media: NowPlaying
    @ObservedObject var battery: BatteryMonitor
    @ObservedObject var calendar: CalendarMonitor
    let showCalendar: Bool
    let headerHeight: CGFloat

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(media.sourceLabel)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color.white.opacity(0.5))
                Spacer()
                if battery.hasBattery {
                    HStack(spacing: 6) {
                        Text("\(battery.level)%")
                            .font(.system(size: 11, weight: .semibold).monospacedDigit())
                            .foregroundStyle(Color.white.opacity(0.7))
                        BatteryGlyph(level: battery.level, charging: battery.isPluggedIn)
                    }
                }
            }
            .frame(height: headerHeight)

            HStack(alignment: .center, spacing: 16) {
                MediaPanel(media: media)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Rectangle()
                    .fill(Color.white.opacity(0.08))
                    .frame(width: 1, height: 84)
                ClockPanel(next: showCalendar ? calendar.next : nil)
                    .frame(width: 118, alignment: .leading)
            }
            .padding(.top, 8)

            Spacer(minLength: 0)
        }
    }
}

struct MediaPanel: View {
    @ObservedObject var media: NowPlaying

    var body: some View {
        HStack(spacing: 14) {
            ArtworkView(image: media.artwork, size: 84, corner: 14)
                .onTapGesture { media.openSourceApp() }

            if media.hasTrack {
                VStack(alignment: .leading, spacing: 5) {
                    Text(media.title)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Color.white)
                        .lineLimit(1)
                    Text(media.artist)
                        .font(.system(size: 12))
                        .foregroundStyle(Color.white.opacity(0.6))
                        .lineLimit(1)
                    if media.duration > 0 {
                        ProgressRow(media: media)
                    }
                    HStack(spacing: 18) {
                        IconButton(symbol: "backward.fill") { media.previous() }
                        IconButton(symbol: media.isPlaying ? "pause.fill" : "play.fill", size: 19) { media.togglePlayPause() }
                        IconButton(symbol: "forward.fill") { media.next() }
                    }
                }
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Nothing playing")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Color.white.opacity(0.8))
                    Text("Play something in Music or Spotify")
                        .font(.system(size: 11))
                        .foregroundStyle(Color.white.opacity(0.45))
                }
            }
        }
    }
}

struct ProgressRow: View {
    @ObservedObject var media: NowPlaying

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.5)) { ctx in
            let elapsed = media.currentElapsed(at: ctx.date)
            let fraction = media.duration > 0 ? elapsed / media.duration : 0
            HStack(spacing: 8) {
                Text(Self.format(elapsed))
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.white.opacity(0.15))
                        Capsule().fill(media.accent)
                            .frame(width: geo.size.width * CGFloat(fraction))
                    }
                }
                .frame(height: 4)
                Text("-" + Self.format(media.duration - elapsed))
            }
            .font(.system(size: 10, weight: .medium).monospacedDigit())
            .foregroundStyle(Color.white.opacity(0.5))
        }
        .frame(height: 14)
    }

    static func format(_ t: Double) -> String {
        let s = max(0, Int(t))
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}

struct ClockPanel: View {
    let next: CalendarMonitor.Upcoming?

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { ctx in
            VStack(alignment: .leading, spacing: 2) {
                Text(ctx.date, format: .dateTime.hour().minute())
                    .font(.system(size: 30, weight: .semibold, design: .rounded).monospacedDigit())
                    .foregroundStyle(Color.white)
                Text(ctx.date, format: .dateTime.weekday(.wide).month(.abbreviated).day())
                    .font(.system(size: 12))
                    .foregroundStyle(Color.white.opacity(0.55))
                if let next {
                    HStack(spacing: 4) {
                        Circle().fill(Color.red).frame(width: 5, height: 5)
                        Text(next.title).lineLimit(1)
                    }
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Color.white.opacity(0.85))
                    .padding(.top, 4)
                    Text(next.start, format: .dateTime.hour().minute())
                        .font(.system(size: 10))
                        .foregroundStyle(Color.white.opacity(0.45))
                }
            }
        }
    }
}

// MARK: - Building blocks

struct ArtworkView: View {
    let image: NSImage?
    let size: CGFloat
    let corner: CGFloat

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
            } else {
                ZStack {
                    Color.white.opacity(0.1)
                    Image(systemName: "music.note")
                        .font(.system(size: size * 0.4))
                        .foregroundStyle(Color.white.opacity(0.5))
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: corner, style: .continuous))
    }
}

struct AudioBars: View {
    let playing: Bool
    let color: Color

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.18)) { ctx in
            HStack(spacing: 2) {
                ForEach(0..<4, id: \.self) { _ in
                    Capsule()
                        .fill(color)
                        .frame(width: 3, height: playing ? CGFloat.random(in: 4...14) : 3)
                }
            }
            .frame(height: 14)
            .animation(.easeInOut(duration: 0.18), value: ctx.date)
        }
    }
}

struct BatteryGlyph: View {
    let level: Int
    let charging: Bool

    var body: some View {
        HStack(spacing: 1) {
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 3.5)
                    .stroke(Color.white.opacity(0.45), lineWidth: 1)
                    .frame(width: 24, height: 12)
                RoundedRectangle(cornerRadius: 2)
                    .fill(fill)
                    .frame(width: max(2, 20 * CGFloat(level) / 100), height: 8)
                    .padding(.leading, 2)
            }
            RoundedRectangle(cornerRadius: 1)
                .fill(Color.white.opacity(0.45))
                .frame(width: 1.5, height: 4)
        }
    }

    private var fill: Color { charging ? .green : (level <= 20 ? .red : .white) }
}

struct IconButton: View {
    let symbol: String
    var size: CGFloat = 14
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size, weight: .semibold))
                .foregroundStyle(Color.white)
                .frame(width: size + 14, height: size + 10)
                .background(Circle().fill(Color.white.opacity(hovering ? 0.14 : 0)))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.15), value: hovering)
    }
}

// MARK: - Shape & transitions

/// Flat top flush with the screen edge, concave "shoulders", rounded bottom corners.
struct NotchShape: Shape {
    var topRadius: CGFloat
    var bottomRadius: CGFloat

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(topRadius, bottomRadius) }
        set { topRadius = newValue.first; bottomRadius = newValue.second }
    }

    func path(in rect: CGRect) -> Path {
        let t = min(topRadius, rect.width / 4)
        let b = max(0, min(bottomRadius, rect.height - t, (rect.width - 2 * t) / 2))
        var p = Path()
        p.move(to: CGPoint(x: rect.minX, y: rect.minY))
        p.addQuadCurve(to: CGPoint(x: rect.minX + t, y: rect.minY + t), control: CGPoint(x: rect.minX + t, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.minX + t, y: rect.maxY - b))
        p.addQuadCurve(to: CGPoint(x: rect.minX + t + b, y: rect.maxY), control: CGPoint(x: rect.minX + t, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.maxX - t - b, y: rect.maxY))
        p.addQuadCurve(to: CGPoint(x: rect.maxX - t, y: rect.maxY - b), control: CGPoint(x: rect.maxX - t, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.maxX - t, y: rect.minY + t))
        p.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.minY), control: CGPoint(x: rect.maxX - t, y: rect.minY))
        p.closeSubpath()
        return p
    }
}

private struct BlurFade: ViewModifier {
    let radius: CGFloat
    let opacity: Double
    func body(content: Content) -> some View {
        content.blur(radius: radius).opacity(opacity)
    }
}

extension AnyTransition {
    static var blurFade: AnyTransition {
        .modifier(active: BlurFade(radius: 10, opacity: 0), identity: BlurFade(radius: 0, opacity: 1))
    }
}
