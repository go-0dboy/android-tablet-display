# USB Tablet Display

Turn an Android tablet into a real external display for macOS, over USB, with
touch and pen input flowing back to the Mac.

The display is genuine: macOS creates it, apps see it, windows move onto it, and
it appears in the Displays pane. It is not a mirrored window.

**Read [docs/STATUS.md](docs/STATUS.md) before relying on any of this.** It sets
out exactly what has been run and what has only been written — including the
fact that this depends on a private Apple API, and what happens when that
changes.

## Features

- **A real virtual display**, sized from the tablet that connects to it — its
  resolution, its pixel density, its rotation. High-density panels get a HiDPI
  display rather than a desktop drawn at half size.
- **Hardware H.264 (or HEVC) encode and decode**, VideoToolbox to MediaCodec.
- **Pen with pressure and tilt**, delivered to macOS as genuine tablet events,
  including a proximity signal so drawing apps know a tablet is there at all.
  Barrel button and eraser end included.
- **Multi-touch**: two-finger scroll and pinch forwarded as Mac gestures, one
  finger as the pointer — or pen-only, by setting, so a resting hand is ignored.
- **Palm rejection**: fingers are ignored while the pen is in range.
- **Auto-connect**: once trusted, plugging the cable in is the whole interaction.
- **Wireless mode** (Wi-Fi, Bonjour discovery, six-digit pairing) — see
  [docs/WIRELESS.md](docs/WIRELESS.md).
- **Wacom pen display presets** — see [docs/WACOM-MOVINK.md](docs/WACOM-MOVINK.md).

## Architecture

```
macOS Host (Swift)                    Android Client (Kotlin)
┌─────────────────────┐              ┌─────────────────────┐
│ Virtual Display     │              │ USB Receiver        │
│ (CGVirtualDisplay)  │              │ (ADB Reverse)       │
│         │           │              │         │           │
│         ▼           │              │         ▼           │
│ ScreenCaptureKit    │   USB/ADB    │ MediaCodec          │
│ (Frame Capture)     │─────────────▶│ (H.264 Decode)      │
│         │           │              │         │           │
│         ▼           │              │         ▼           │
│ VideoToolbox        │              │ SurfaceView         │
│ (H.264 Encode)      │              │ (Display)           │
│         │           │   USB/ADB    │         │           │
│ CGEvent Injection   │◀─────────────│ Touch/Pen Input     │
└─────────────────────┘              └─────────────────────┘
```

## Requirements

**macOS host:** macOS 13 or later; `adb`
(`brew install --cask android-platform-tools`); Screen Recording permission;
Accessibility permission for input.

**Android client:** Android 8 or later (API 26+); USB debugging enabled; a USB
cable that carries data.

Verified on macOS 26.6.2 on an M4 Max. Run `swift run vdprobe` to check your own
machine before anything else — see [docs/STATUS.md](docs/STATUS.md).

## Building

```bash
# Check the private virtual-display API works on your macOS. Do this first.
cd macos-host/USBDisplayApp && swift run vdprobe

# Build the Mac app as a proper .app bundle. This matters: macOS attaches
# Screen Recording permission to a bundle identity, and a bare `swift build`
# binary has none, so the permission will not persist.
cd ../.. && ./tools/build-app.sh release

# Build and install the Android client.
cd android-client && ./gradlew assembleDebug
adb install -r app/build/outputs/apk/debug/app-debug.apk
```

Tests: `swift test` in `macos-host/USBDisplayApp`, and
`./gradlew testDebugUnitTest` in `android-client`.

Full step-by-step install, and what to do when it does not work, is in
[docs/STATUS.md](docs/STATUS.md).

## Usage

1. Connect your Android tablet via USB
2. Enable USB debugging on the tablet
3. Launch the macOS menu bar app
4. Grant Screen Recording and Accessibility permissions when prompted
5. Click "Start Streaming" from the menu bar
6. The Android app will launch automatically and display your new monitor

### Menu bar

- **Connect over** — USB (the default) or Wi-Fi.
- **Tablet** — which device, when more than one is attached. A real handset on
  the cable is preferred over an emulator automatically.
- **Touch** — finger moves the pointer, or pen only.
- **Connect automatically when plugged in**.
- **Apply / save layout** — appears when a Wacom pen display is attached.
- **Paired devices** — forget a wireless device.
- **Show log**.

## Project Structure

```
usb-tablet-display/
├── macos-host/
│   ├── USBDisplayApp/       # Menu bar app (recommended)
│   │   ├── Package.swift
│   │   └── Sources/
│   │       ├── USBDisplayApp/
│   │       └── VirtualDisplay/
│   └── USBDisplay/          # CLI tool (alternative)
├── android-client/
│   └── app/
│       └── src/main/
│           ├── java/.../MainActivity.kt
│           └── res/
└── README.md
```

## Technical details

- **Video**: H.264 Main profile (HEVC optional), 15 Mbps, 60 fps target,
  hardware encoded. A keyframe is forced whenever a client connects, so a
  reconnecting tablet is not left staring at black.
- **Resolution**: taken from the client's hello message, aligned to 16 pixels
  for the encoder, capped at 4096.
- **Ports**: 5560 video, 5561 input. Bound to loopback only in USB mode.
- **Transport**: `adb reverse` over USB; plain TCP over Wi-Fi.
- **Framing**: video frames carry a 4-byte length prefix; input messages are
  `[type][u16 length][payload]` and self-describing, so an unknown message type
  is skipped rather than desynchronising the stream.

Both halves implement the protocol independently, and both test suites pin the
byte layout, so the two cannot drift apart quietly.

## Known limitations

- **This depends on a private Apple API** with no supported alternative. It can
  break in any macOS update. [docs/STATUS.md](docs/STATUS.md) has the version
  history, the sources, and the diagnostic to run.
- **Pinch-to-zoom is best-effort.** CoreGraphics has no public way to post a
  gesture event; magnification is synthesised, and some apps will ignore it.
- **Wireless mode does not encrypt the video.** Pairing authenticates the
  device; it does not hide the pixels. See [docs/WIRELESS.md](docs/WIRELESS.md).
- **Frame delivery follows screen changes** — a still screen sends few frames.
  That is ScreenCaptureKit behaving correctly, not a stall.
- **Much of this is untested on real hardware.**
  [docs/STATUS.md](docs/STATUS.md) lists exactly which parts.

## Project structure

```
macos-host/USBDisplayApp/
  Sources/USBDisplayCore/     protocol, device selection, geometry, presets, pairing
  Sources/USBDisplayApp/      menu bar app, capture, encode, sockets, input injection
  Sources/VirtualDisplay/     Objective-C bridge to the private CoreGraphics API
  Sources/VirtualDisplayProbe/  vdprobe — does the private API work here?
  Sources/LatencyClock/       latencyclock — machine-readable clock for measurement
  Tests/                      63 tests
android-client/               Kotlin client, 36 tests
tools/                        build-app.sh, measure-latency.sh, decode-clock.py
docs/                         STATUS.md, WACOM-MOVINK.md, WIRELESS.md, evidence/
```

`macos-host/USBDisplay/` is the original command-line prototype, kept for
reference. The menu bar app is the one to use.

## License

MIT
