# OpenCove

An original, from-scratch Dynamic Island for the MacBook notch, written in SwiftUI.

## Build & run

```bash
xcode-select --install      # once, if you don't have the Command Line Tools
./build.sh
open build/OpenCove.app
```

OpenCove doesn't put an icon in the Dock. Look for the capsule icon in the menu bar: that menu has Settings… and Quit.

The first time music plays, macOS asks whether OpenCove may control Music or Spotify. Click Allow.

## What it does (v0.2)

**Island**
- Sits over the notch and opens with a spring animation, either when you hover or when you click (you choose in Settings).
- Clicks pass through to the menu bar unless the cursor is over the island.
- Hides itself when an app is in fullscreen.
- Trackpad gestures: swipe down to open, up to close, left or right to skip tracks.

**Live activities**
- Music: album art and audio bars tinted to match the artwork. You can keep it showing while paused.
- Quick peek: when a new track starts, the title and artist slide out for a moment.
- Calendar (optional): your next event shows in the open island, with a reminder N minutes before it starts.

**Notifications**
- Volume, with a level bar and mute state
- Charging
- Low battery warning, with a threshold you set
- Bluetooth devices connecting and disconnecting

**Settings window** (menu bar capsule icon → Settings…)
- Launch at login, hide in fullscreen, hover vs click, haptics, gestures
- How long notifications stay up, and an on/off switch for each one
- Quick peek and calendar options
- Width and height sliders to fine-tune the island to your notch

## Permissions macOS will ask for
- **Automation (Music/Spotify):** to read what's playing and control playback
- **Bluetooth:** for device connect alerts
- **Calendars:** only if you turn on calendar events

## How it works

| File | Role |
|---|---|
| `IslandController.swift` | Borderless, non-activating `NSPanel` above the menu bar on all Spaces. It polls the cursor to handle hover and to switch click-through on and off. |
| `IslandModel.swift` | Picks the mode (idle / music / HUD / expanded) and the island size for each mode. |
| `IslandView.swift` | The SwiftUI views, the animated `NotchShape` and the blur-fade transition. |
| `NowPlaying.swift` | Gets track info from the private MediaRemote framework, falling back to AppleScript for Music and Spotify. |
| `BatteryMonitor.swift` | IOKit power-source notifications. |
| `Monitors.swift` | Volume (CoreAudio), Bluetooth (IOBluetooth) and calendar (EventKit). |
| `Settings.swift` | Saved preferences and the Settings window. |

### Known limitations

- **macOS 15.4+ blocks MediaRemote for third-party apps.** On those versions OpenCove falls back to AppleScript, which only covers Music and Spotify. To also show audio from browsers and other apps, you'd need a helper such as the open-source `mediaremote-adapter`.
- **Permissions reset on every build.** The app is signed ad hoc, so macOS asks for the Automation permission again after each rebuild.
- **No brightness notification.** macOS has no public API that reports brightness changes.
- **The system's own volume pop-up still appears** alongside OpenCove's. Hiding it would need private hacks.
- **Fullscreen detection can misfire** if you set the menu bar to always auto-hide. If it does, turn off "Hide in fullscreen".
