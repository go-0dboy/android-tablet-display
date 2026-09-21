# Android Tablet Display

Turn an Android tablet into a second display for your Mac, over USB or Wi-Fi,
with touch and pen input flowing back.

The display is real: macOS creates it, apps see it, windows move onto it, and
it appears in System Settings › Displays. It is not a mirrored window.

## Features

- **A real display**, sized from the tablet that connects: its resolution,
  pixel density and rotation. High-density panels get a HiDPI display, not a
  desktop drawn at half size.
- **Hardware video**: H.264 or HEVC, VideoToolbox on the Mac, MediaCodec on
  the tablet.
- **Pen with pressure and tilt**, delivered to macOS as tablet events, so
  drawing apps see a pen. Barrel button and eraser end included.
- **Touch**: one finger moves the pointer, two fingers scroll and pinch. Or
  pen-only, so a resting hand is ignored.
- **Palm rejection**: fingers are ignored while the pen is near the screen.
- **Auto-connect**: once trusted, plugging the cable in is the whole interaction.
- **Wireless**: Bonjour discovery and six-digit pairing over Wi-Fi.
  See [docs/WIRELESS.md](docs/WIRELESS.md).
- **Wacom**: a MovinkPad Pro 14 works like any other Android tablet. A Movink
  13 pen display is a monitor, and gets layout presets instead of streaming.
  See [docs/WACOM-MOVINK.md](docs/WACOM-MOVINK.md).

## Requirements

**Mac:** macOS 12 or later, `adb` (`brew install --cask android-platform-tools`),
Screen Recording permission, and Accessibility permission for input. The
Monterey capture backend is tested on macOS 12.7.6 on an Intel Mac.

**Tablet:** Android 7.1 or later, USB debugging enabled, and a USB cable that
carries data. Android 7 uses an automatic compatibility profile: H.264
Baseline, 1280x800 at 30 fps and a 5 Mbps target on the tested Galaxy Tab 2.

## Install

Ready-built applications are attached to the
[latest GitHub release](https://github.com/go-0dboy/android-tablet-display/releases/latest):

- `Android-Tablet-Display-macOS-v2.0.0.zip` — the macOS menu-bar app;
- `Android-Tablet-Display-Android-v2.0.0.apk` — the Android client.

The macOS build is ad-hoc signed rather than notarised. If Gatekeeper retains
the download quarantine, unpack it and run:

```bash
xattr -dr com.apple.quarantine "Android Tablet Display.app"
```

To build from source instead:

```bash
# Mac app. Build it as a .app bundle: macOS ties Screen Recording permission
# to a bundle, so a bare `swift build` binary would be asked every launch.
./tools/build-app.sh release
open "build/Android Tablet Display.app"

# Tablet app.
cd android-client && ./gradlew assembleDebug
adb install -r app/build/outputs/apk/debug/app-debug.apk
```

## Use

1. Plug the tablet in, with USB debugging on.
2. Open the Mac app. It lives in the menu bar.
3. Grant Screen Recording and Accessibility when asked.
4. Click **Start**. The tablet app opens on its own and shows the new display.

The menu bar item has:

- **Connect over**: USB (default) or Wi-Fi.
- **Tablet**: which device, when more than one is attached. A real tablet is
  preferred over an emulator.
- **Touch**: finger moves the pointer, or pen only.
- **Connect automatically when plugged in**.
- **Apply / save layout**: appears when a Wacom pen display is attached.
- **Paired devices**: forget a wireless device.
- **Show log**.

## How it works

```
macOS (Swift)                          Android (Kotlin)
┌─────────────────────┐              ┌─────────────────────┐
│ Virtual display     │              │ Receiver            │
│ (CGVirtualDisplay)  │              │ (adb reverse / TCP) │
│         │           │              │         │           │
│         ▼           │              │         ▼           │
│ ScreenCaptureKit    │   USB/Wi-Fi  │ MediaCodec          │
│ (frame capture)     │─────────────▶│ (decode)            │
│         │           │              │         │           │
│         ▼           │              │         ▼           │
│ VideoToolbox        │              │ SurfaceView         │
│ (encode)            │              │ (display)           │
│         │           │   USB/Wi-Fi  │         │           │
│ Event injection     │◀─────────────│ Touch / pen input   │
└─────────────────────┘              └─────────────────────┘
```

- **Video**: H.264 Main profile (HEVC optional), 15 Mbps, 60 fps target. A
  keyframe is forced whenever a client connects. Legacy Android decoders use
  a separate H.264 Baseline, 30 fps compatibility profile.
- **Resolution**: from the tablet's hello message, aligned to 16 pixels for
  the encoder, capped at 4096.
- **Transport**: `adb reverse` over USB, plain TCP over Wi-Fi. Ports 5560
  (video) and 5561 (input), loopback-only in USB mode.
- **Framing**: video frames carry a 4-byte length prefix. Input messages are
  `[type][u16 length][payload]`, so an unknown type is skipped rather than
  desynchronising the stream. Both sides' tests pin the byte layout.

## Repository layout

```
macos-host/USBDisplayApp/
  Sources/USBDisplayCore/       protocol, device selection, geometry, presets, pairing
  Sources/USBDisplayApp/        menu bar app: capture, encode, sockets, input injection
  Sources/VirtualDisplay/       Objective-C bridge that creates the display
  Sources/VirtualDisplayProbe/  vdprobe: creates and tears down a display, to check a machine
  Sources/LatencyClock/         latencyclock: on-screen clock for latency measurement
  Sources/GestureLab/           gesturelab: posts gestures, to see what apps accept
  Tests/
macos-host/USBDisplay/          original command-line prototype, kept for reference
android-client/                 Kotlin app
tools/                          build-app.sh, measure-latency.sh, decode-clock.py, pen-probe.sh
docs/                           STATUS.md, WIRELESS.md, WACOM-MOVINK.md, evidence/
```

Tests: `swift test` in `macos-host/USBDisplayApp`, and
`./gradlew testDebugUnitTest` in `android-client`.

## Notes

- Pinch zoom sends ⌘+ / ⌘−, so it steps rather than glides, and only in apps
  that have those shortcuts. Two-finger scroll is a real scroll.
- Wireless mode pairs the device but does not encrypt the video. Use it on a
  network you trust.
- [docs/STATUS.md](docs/STATUS.md) records what has been run on real hardware
  and what hasn't, with measurements.

## License

MIT
