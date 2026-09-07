# Android Tablet Display

Turn an Android tablet into a real external display for macOS, over USB, with
touch and pen input flowing back to the Mac.

The display is genuine: macOS creates it, apps see it, windows move onto it, and
it appears in the Displays pane. It is not a mirrored window.

**Read [docs/STATUS.md](docs/STATUS.md) before relying on any of this.** It sets
out exactly what has been run and what has only been written — including the
fact that this depends on an unpublished Apple API, and what happens when that
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
- **Wacom**: a MovinkPad Pro 14 is a streaming target like any other Android
  tablet; a Movink 13 pen display is a monitor and needs layout presets, not
  streaming. Both covered in [docs/WACOM-MOVINK.md](docs/WACOM-MOVINK.md).

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
android-tablet-display/
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

## How the display is created, and what that means for you

macOS has no published way for an app to add a display that isn't a physical
monitor. What it does have is the machinery Apple built for Sidecar and
AirPlay: a class called `CGVirtualDisplay` that lives inside
CoreGraphics.framework on every Mac. Apple never put it in the SDK headers or
the documentation, so we declare the interface ourselves and call it. That is
all "private API" means here. It is code that ships in macOS, running on your
machine with your permissions, exactly like a public call; the only difference
is that Apple hasn't promised to keep it.

What follows from that, in practice:

- **Nothing is missing from the app.** The display is a real display: apps see
  it, windows move onto it, it appears in the Displays pane.
- **A macOS update could break it without warning.** `swift run vdprobe`
  checks your own machine in ten seconds. It has been seen working from
  Mojave through macOS 26 Tahoe, and verified here on 26.6.2. History in
  [docs/STATUS.md](docs/STATUS.md).
- **It can't be sold on the Mac App Store.** App Review rejects private API.
  Direct download and Developer ID notarisation are fine.

BetterDisplay, Crisp and Deskreen's virtual mode all rest on the same call.

## Known limitations

- **Pinch to zoom is stepped, not smooth, and only in apps that have ⌘+ / ⌘−.**
  The smooth trackpad-gesture path is implemented, but macOS 26.6.2 does not
  deliver synthesised magnify events at all — measured, with the
  per-application table in [docs/STATUS.md](docs/STATUS.md). Two-finger scroll
  is unaffected and is a real trackpad scroll.
- **Wireless mode does not encrypt the video.** Pairing authenticates the
  device; it does not hide the pixels. See [docs/WIRELESS.md](docs/WIRELESS.md).

What has and hasn't been run on real hardware is a separate question from
what the app can do; [docs/STATUS.md](docs/STATUS.md) keeps that list.

## Project structure

```
macos-host/USBDisplayApp/
  Sources/USBDisplayCore/     protocol, device selection, geometry, presets, pairing
  Sources/USBDisplayApp/      menu bar app, capture, encode, sockets, input injection
  Sources/VirtualDisplay/     Objective-C bridge to the private CoreGraphics API
  Sources/VirtualDisplayProbe/  vdprobe — does the private API work here?
  Sources/LatencyClock/       latencyclock — machine-readable clock for measurement
  Sources/GestureLab/         gesturelab — posts gestures, to find out what works
  Tests/                      63 tests
android-client/               Kotlin client, 36 tests
tools/                        build-app.sh, measure-latency.sh, decode-clock.py,
                              pen-probe.sh
docs/                         STATUS.md, WACOM-MOVINK.md, WIRELESS.md, evidence/
```

`macos-host/USBDisplay/` is the original command-line prototype, kept for
reference. The menu bar app is the one to use.

## License

MIT
