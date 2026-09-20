# Changelog

## 2.0.0 — 2026-09-21

This release extends Android Tablet Display to older Intel Macs and legacy
Android tablets, while keeping the normal macOS 13+/Android 8+ path intact.

### Added

- macOS Monterey 12 support using `CGDisplayStream`, including Swift 5.7 and
  Xcode 14.2 compatibility.
- Android 7.1/API 25 support, tested with a Samsung Galaxy Tab 2 and its
  `OMX.TI.DUCATI1.VIDEO.DECODER` hardware decoder.
- A legacy H.264 Baseline compatibility profile at 1280x800, 30 fps and a
  5 Mbps target bitrate.
- Detailed capture, encode, delivery and socket latency metrics in the host
  log.

### Fixed

- Keep a fixed 30 fps encode cadence even when Monterey's damage-driven
  capture API emits only sparse callbacks.
- Bound the complete encode/network pipeline and replace only frames that
  have not entered H.264, preventing delayed playback of stale desktop frames.
- Deliver every encoded access unit completely and in order, including TCP
  short writes, without blocking a VideoToolbox callback.
- Stop silently dropping H.264 access units when the Android decoder needs
  more than 10 ms to return an input buffer.
- Recover a stalled legacy decoder asynchronously and resume only at a fresh
  IDR frame.
- Avoid repeated legacy hardware-decoder allocation during reconnect loops.
- Prevent stale asynchronous capture startup from targeting display ID 0.

### Compatibility notes

- The macOS release archive is ad-hoc signed and is not Apple-notarised.
- The downloadable Android APK is debug-signed because the repository does
  not contain a private release keystore.
- The Galaxy Tab 2 decoder is sensitive to bitrate bursts. A 10 Mbps target
  is intentionally not used: even the 5 Mbps profile can briefly emit more
  than 10 Mbps during complex motion.
