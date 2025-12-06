# USB Tablet Display

Turn your Android tablet into a USB-connected external display for macOS with touch and pen/stylus support.

## Features

- **Virtual display**: Creates a real macOS display that apps recognize natively
- **H.264 hardware encoding/decoding**: Low-latency video streaming via USB
- **Touch input**: Full touch support with events mapped to the virtual display
- **Pen/stylus support**: Pressure and tilt sensitivity for drawing apps
- **Menu bar app**: Easy start/stop, permission management, and FPS toggle
- **Auto-reconnect**: Handles sleep/wake and disconnection gracefully

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

### macOS Host
- macOS 13.0+ (Ventura or later)
- ADB installed (via Android Studio or Homebrew: `brew install android-platform-tools`)
- Screen Recording permission
- Accessibility permission (for touch input)

### Android Client
- Android 7.0+ (API 24+)
- USB debugging enabled
- USB cable connected to Mac

## Building

### macOS Menu Bar App

```bash
cd macos-host/USBDisplayApp
swift build
```

The binary will be at `.build/debug/USBDisplayApp`

### Android Client

Open `android-client/` in Android Studio and build, or:

```bash
cd android-client
./gradlew assembleDebug
```

Install on device:
```bash
adb install -r app/build/outputs/apk/debug/app-debug.apk
```

## Usage

1. Connect your Android tablet via USB
2. Enable USB debugging on the tablet
3. Launch the macOS menu bar app
4. Grant Screen Recording and Accessibility permissions when prompted
5. Click "Start Streaming" from the menu bar
6. The Android app will launch automatically and display your new monitor

### Menu Bar Options

- **Start/Stop Streaming**: Control the display connection
- **Launch Android App**: Manually restart the Android client
- **Show/Hide FPS on Android**: Toggle the FPS counter overlay
- **Show Log**: View connection and streaming logs

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

## Technical Details

- **Video**: H.264 Main Profile, 15 Mbps, 60 FPS target
- **Resolution**: Configurable (default 2560x1600)
- **Ports**: 5560 (video), 5561 (touch input)
- **Connection**: ADB reverse port forwarding over USB

## Known Limitations

- Frame delivery depends on screen changes (ScreenCaptureKit behavior)
- Cursor may linger briefly when leaving the virtual display
- Requires USB connection (no WiFi support currently)

## License

MIT
