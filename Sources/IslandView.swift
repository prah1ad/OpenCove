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
                HUDView(hud: hud, media: media,
                        sideWidth: max(40, (model.size.width - model.geometry.notchSize.width) / 2 - topRadius - 14))
                    .padding(.horizontal, topRadius + 8)
                    .id(hud.kind)
                    .transition(.blurFade)
            }
        case .expanded:
            ExpandedView(model: model, media: media, battery: battery, calendar: calendar,
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
    /// Usable width on each side of the notch, so nothing slides under the camera.
    let sideWidth: CGFloat

    var body: some View {
        HStack(spacing: 0) {
            HStack(spacing: 6) { leading }
                .frame(width: sideWidth, alignment: .leading)
            Spacer(minLength: 0)
            HStack(spacing: 6) { trailing }
                .frame(width: sideWidth, alignment: .trailing)
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
            MarqueeText(text: name).frame(maxWidth: .infinity)
        case .calendar(let title, _):
            Image(systemName: "calendar").foregroundStyle(Color.red)
            MarqueeText(text: title).frame(maxWidth: .infinity)
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
    @ObservedObject var model: IslandModel
    @ObservedObject var media: NowPlaying
    @ObservedObject var battery: BatteryMonitor
    @ObservedObject var calendar: CalendarMonitor
    let showCalendar: Bool
    let headerHeight: CGFloat

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(model.page == 0 ? media.sourceLabel : "Calendar")
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

            // Fills the space between header and page dots, so the content sits centred.
            HStack(alignment: .center, spacing: 16) {
                ZStack(alignment: .leading) {
                    if model.page == 0 {
                        MediaPanel(media: media)
                            .transition(.blurFade)
                    } else {
                        MiniCalendarPanel(calendar: calendar, enabled: showCalendar)
                            .transition(.blurFade)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .animation(IslandModel.spring, value: model.page)

                Rectangle()
                    .fill(Color.white.opacity(0.08))
                    .frame(width: 1, height: 96)
                ClockPanel(calendar: (showCalendar && model.page == 0) ? calendar : nil)
                    .frame(width: 124, alignment: .leading)
            }
            .frame(maxHeight: .infinity)

            PageDots(page: model.page, count: 2) { model.setPage($0) }
        }
    }
}

struct PageDots: View {
    let page: Int
    let count: Int
    let select: (Int) -> Void

    var body: some View {
        HStack(spacing: 5) {
            ForEach(0..<count, id: \.self) { i in
                Capsule()
                    .fill(Color.white.opacity(i == page ? 0.9 : 0.25))
                    .frame(width: i == page ? 14 : 5, height: 5)
                    .contentShape(Rectangle().inset(by: -4))
                    .onTapGesture { select(i) }
            }
        }
        .animation(IslandModel.spring, value: page)
        .frame(height: 8)
    }
}

// MARK: - Mini calendar page

struct MiniCalendarPanel: View {
    @ObservedObject var calendar: CalendarMonitor
    let enabled: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            MonthGrid(eventDays: enabled ? calendar.eventDays : [])
            AgendaList(calendar: calendar, enabled: enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

struct MonthGrid: View {
    let eventDays: Set<Int>

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { ctx in
            let info = MonthInfo(date: ctx.date)
            VStack(alignment: .leading, spacing: 3) {
                Text(ctx.date, format: .dateTime.month(.wide))
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(Color.red)
                HStack(spacing: 0) {
                    ForEach(Array(info.weekdaySymbols.enumerated()), id: \.offset) { _, symbol in
                        Text(symbol)
                            .frame(width: 21)
                    }
                }
                .font(.system(size: 8, weight: .semibold))
                .foregroundStyle(Color.white.opacity(0.4))
                ForEach(0..<info.weeks, id: \.self) { week in
                    HStack(spacing: 0) {
                        ForEach(0..<7, id: \.self) { column in
                            dayCell(info.day(week: week, column: column), today: info.today)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func dayCell(_ day: Int?, today: Int) -> some View {
        ZStack {
            if let day {
                if day == today {
                    Circle().fill(Color.red).frame(width: 15, height: 15)
                }
                Text("\(day)")
                    .font(.system(size: 9, weight: day == today ? .bold : .medium).monospacedDigit())
                    .foregroundStyle(Color.white.opacity(day == today ? 1 : 0.8))
                if eventDays.contains(day) && day != today {
                    Circle().fill(Color.white.opacity(0.6))
                        .frame(width: 2.5, height: 2.5)
                        .offset(y: 7)
                }
            }
        }
        .frame(width: 21, height: 14)
    }
}

/// Layout maths for a month grid that respects the user's first day of the week.
struct MonthInfo {
    let weekdaySymbols: [String]
    let leadingBlanks: Int
    let daysInMonth: Int
    let today: Int

    init(date: Date, calendar: Calendar = .current) {
        let first = calendar.date(from: calendar.dateComponents([.year, .month], from: date)) ?? date
        let firstWeekday = calendar.firstWeekday // 1 = Sunday
        let symbols = calendar.veryShortStandaloneWeekdaySymbols
        weekdaySymbols = Array(symbols[(firstWeekday - 1)...] + symbols[..<(firstWeekday - 1)])
        leadingBlanks = (calendar.component(.weekday, from: first) - firstWeekday + 7) % 7
        daysInMonth = calendar.range(of: .day, in: .month, for: date)?.count ?? 30
        today = calendar.component(.day, from: date)
    }

    var weeks: Int { (leadingBlanks + daysInMonth + 6) / 7 }

    func day(week: Int, column: Int) -> Int? {
        let d = week * 7 + column - leadingBlanks + 1
        return (1...daysInMonth).contains(d) ? d : nil
    }
}

struct AgendaList: View {
    @ObservedObject var calendar: CalendarMonitor
    let enabled: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !enabled {
                placeholder("Turn on calendar events in Settings to see your agenda.")
            } else if calendar.status == .denied {
                placeholder("Calendar access is off. Allow it in Settings.")
            } else if calendar.upcoming.isEmpty {
                placeholder("Nothing scheduled this week.")
            } else {
                ForEach(Array(calendar.upcoming.enumerated()), id: \.offset) { _, event in
                    HStack(alignment: .top, spacing: 6) {
                        Capsule().fill(event.color).frame(width: 3, height: 26)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(event.title)
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(Color.white)
                                .lineLimit(2)
                                .fixedSize(horizontal: false, vertical: true)
                            Text(Self.when(event))
                                .font(.system(size: 10))
                                .foregroundStyle(Color.white.opacity(0.5))
                        }
                    }
                }
            }
        }
    }

    private func placeholder(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11))
            .foregroundStyle(Color.white.opacity(0.5))
            .fixedSize(horizontal: false, vertical: true)
    }

    static func when(_ event: CalendarMonitor.Upcoming) -> String {
        let cal = Calendar.current
        let day: String
        if cal.isDateInToday(event.start) {
            day = "Today"
        } else if cal.isDateInTomorrow(event.start) {
            day = "Tomorrow"
        } else {
            day = event.start.formatted(.dateTime.weekday(.abbreviated))
        }
        if event.isAllDay { return "\(day) · All day" }
        return "\(day) · \(event.start.formatted(.dateTime.hour().minute()))"
    }
}

// MARK: - Scrolling text for long names

/// Shows the text normally if it fits; otherwise scrolls it back and forth.
struct MarqueeText: View {
    let text: String
    var font: Font = .system(size: 12, weight: .semibold)
    var height: CGFloat = 16
    @State private var offset: CGFloat = 0

    var body: some View {
        GeometryReader { box in
            Text(text)
                .font(font)
                .lineLimit(1)
                .fixedSize()
                .background(GeometryReader { measured in
                    Color.clear.onAppear { start(textWidth: measured.size.width, boxWidth: box.size.width) }
                })
                .offset(x: offset)
                .frame(width: box.size.width, height: box.size.height, alignment: .leading)
        }
        .frame(height: height)
        .clipped()
    }

    private func start(textWidth: CGFloat, boxWidth: CGFloat) {
        let overflow = textWidth - boxWidth
        guard overflow > 1 else { return }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 700_000_000)
            withAnimation(.linear(duration: Double(overflow) / 35).repeatForever(autoreverses: true)) {
                offset = -overflow
            }
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
    /// nil when calendar events are turned off in Settings.
    var calendar: CalendarMonitor?

    /// Formats just "AM"/"PM", or nil if this Mac uses a 24-hour clock.
    static let amPMFormatter: DateFormatter? = {
        let pattern = DateFormatter.dateFormat(fromTemplate: "j", options: 0, locale: .current) ?? ""
        guard pattern.contains("a") else { return nil }
        let f = DateFormatter()
        f.locale = .current
        f.dateFormat = "a"
        return f
    }()

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { ctx in
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 3) {
                    Text(ctx.date, format: .dateTime.hour(.defaultDigits(amPM: .omitted)).minute())
                        .font(.system(size: 30, weight: .semibold, design: .rounded).monospacedDigit())
                    if let amPM = Self.amPMFormatter?.string(from: ctx.date) {
                        Text(amPM)
                            .font(.system(size: 13, weight: .semibold, design: .rounded))
                            .foregroundStyle(Color.white.opacity(0.6))
                    }
                }
                .foregroundStyle(Color.white)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                Text(ctx.date, format: .dateTime.weekday(.wide).month(.abbreviated).day())
                    .font(.system(size: 12))
                    .foregroundStyle(Color.white.opacity(0.55))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                if let calendar {
                    CalendarLine(calendar: calendar)
                        .padding(.top, 4)
                }
            }
        }
    }
}

struct CalendarLine: View {
    @ObservedObject var calendar: CalendarMonitor

    var body: some View {
        Group {
            if let next = calendar.next {
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 4) {
                        Circle().fill(Color.red).frame(width: 5, height: 5)
                        Text(next.title).lineLimit(1)
                    }
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Color.white.opacity(0.85))
                    Text(next.start, format: .dateTime.weekday(.abbreviated).hour().minute())
                        .font(.system(size: 10))
                        .foregroundStyle(Color.white.opacity(0.45))
                }
            } else {
                Text(message)
                    .font(.system(size: 10))
                    .foregroundStyle(Color.white.opacity(0.45))
                    .lineLimit(2)
            }
        }
    }

    private var message: String {
        switch calendar.status {
        case .ready: return "No events in the next 24 h"
        case .denied: return "Calendar access off — see Settings"
        case .waiting: return "Waiting for calendar access…"
        case .off: return ""
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
