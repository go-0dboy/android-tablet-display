# Status

Last updated 2026-09-07.

This file separates what has actually been run from what is written but
unverified. The distinction matters more than usual here, because the whole
project rests on a private Apple API that could stop working in any macOS
update, and because the hardware it is aimed at was not attached to the machine
this was developed on.

## The machine everything below was verified on

| | |
|---|---|
| Mac | Apple M4 Max, macOS **26.6.2** (build 25G83), arm64 |
| Toolchain | Xcode 26.2, Swift 6.2.3 |
| Android | **Emulator only** (`sdk_gphone64_arm64`, API 36). No physical device. |
| Android toolchain | AGP 8.7.3, Gradle 8.11.1, Kotlin 2.0.21, JDK 21, compileSdk 36 |

**No Samsung handset or tablet, and no Wacom display, were connected at any
point.** Everything below labelled "unverified" is unverified for that reason,
not because it was skipped.

## What works today, verified

- **The virtual display is real.** `swift run vdprobe` creates a display
  through the private CGVirtualDisplay API on macOS 26.6.2, it appears in
  `CGGetActiveDisplayList` and in `system_profiler SPDisplaysDataType`,
  `screencapture -D` can target it, and it tears down cleanly in-process.
  Output in [evidence/03-vdprobe-output.txt](evidence/03-vdprobe-output.txt).
- **HiDPI works.** A client reporting ≥200 dpi gets a display with a 2×
  backing store: verified at 2560×1600 pixels presented as 1280×800 points.
- **The display is sized from the client.** The client sends its real
  resolution, density and rotation; the host builds the display to match. In
  the logged session an emulator reporting 2220×1080 at 440 dpi produced a
  2208×1072 HiDPI display named after the device.
- **End-to-end streaming.** Host captures, encodes H.264 through VideoToolbox,
  ships frames over `adb reverse`, the client decodes with MediaCodec and
  renders. Both screens showing the same frame:
  [evidence/01](evidence/01-virtual-display-on-mac.png) and
  [evidence/02](evidence/02-same-frame-on-the-tablet.png).
- **Throughput, emulator, 2208×1072:** 35–54 fps, 1.0–4.8 Mbps depending on how
  much of the screen is changing.
- **Encode latency, host-side: 6.9–7.0 ms median, 11.5 ms worst.** This is the
  time from ScreenCaptureKit handing over a frame to the compressed bytes being
  ready. It is measured inside the host and is the one timing figure here that
  is solid. It is **not** end-to-end latency.
- **Tests: 99 pass.** 63 Swift (`swift test`) covering the wire protocol,
  device selection, display geometry, pen tilt maths, pen-display
  identification and pairing; 36 Kotlin (`./gradlew testDebugUnitTest`)
  covering the wire format byte-for-byte against the Swift implementation, and
  every touch rule — gestures, palm rejection, pen precedence.
- **Both halves build from a clean checkout**, and CI builds both on every push.

## What is written but NOT verified

Everything in this section is implemented and unit-tested where it can be, and
has never been run against the hardware it is for.

- **Anything involving a real Samsung device.** USB throughput and latency over
  an actual cable, One UI's USB mode handling, whether `adb reverse` behaves the
  same on One UI as on the emulator.
- **Any real stylus.** Pressure, tilt, hover, the barrel button and the eraser
  end are implemented and the translation logic is unit-tested, but no stylus
  has ever been put to a screen with this code running. The emulator has no
  digitiser. The intended target is a **Wacom MovinkPad Pro 14**, a standalone
  Android tablet with a Wacom EMR digitiser — see
  [WACOM-MOVINK.md](WACOM-MOVINK.md). What its digitiser actually reports is
  unrecorded; `./tools/pen-probe.sh <serial>` is the tool that answers it, and
  its output should be pasted here once someone has run it.
- **Palm rejection.** The rules are tested against synthetic input. Whether the
  size threshold is right for a real hand on real glass is unknown.
- **Whether macOS applications actually honour the pen.** The host now sends
  proximity-enter events and tags pen movements with the tablet subtype, which
  is what the documentation and every other tablet driver does — but no drawing
  app has been observed responding to pressure from it.
- **Two-finger scroll and pinch on the Mac.** Scroll uses a documented
  CoreGraphics call and should be fine. **Pinch does not.** CoreGraphics has no
  public constructor for a gesture event, so magnification is built by hand as
  an `NSEventTypeMagnify` (type 29) event with the magnification in field 33.
  This is the approach trackpad-emulation tools use; it is undocumented and
  apps that only honour ⌘-scroll will ignore it entirely. Treat pinch as
  best-effort.
- **Samsung DeX.** Detection reads the `semdesktopmode` global setting and a
  Samsung-only configuration field. Neither has been observed returning a true
  value, because that needs a Samsung device.
- **Wireless mode.** Bonjour advertising, discovery, and the pairing handshake
  are implemented and the cryptography is unit-tested on both sides against
  fixed vectors. The two halves have never talked to each other over a network.
  No wireless latency figure exists.
- **The Wacom preset.** See [WACOM-MOVINK.md](WACOM-MOVINK.md). No Wacom
  hardware was attached, so detection has only been tested against synthetic
  display identities.
- **Sleep and wake.** The host subscribes to wake notifications and rebuilds
  the display, and the virtual display's termination handler triggers a rebuild.
  Not tested across an actual sleep cycle.

## Why there is no glass-to-glass latency number

The obvious method — show a clock, capture the tablet, subtract — does not work
over `adb`. `adb exec-out screencap` costs **180–300 ms** per capture on this
machine, and there is no way to know where inside that window the framebuffer
was actually sampled. The uncertainty is an order of magnitude larger than the
latency being measured. `tools/measure-latency.sh` runs the measurement and
prints a warning saying exactly this when the overhead dominates.

The tooling for a real measurement is here and works:

- `swift run latencyclock --display <id>` draws a timestamp on the virtual
  display, encoded as binary blocks so it can be read by a program rather than
  by eye.
- `tools/decode-clock.py` decodes those blocks from any screenshot or video
  frame. Verified: it reads back exactly the value the clock drew.

What is missing is a capture device fast enough. **Film both screens together
at 120 fps or better and count the frames between the Mac's clock changing and
the tablet's.** That is the only honest way to get the number, and it needs a
person with a camera. No software running on either machine can observe its own
display scanout.

## The private API this depends on, and the risk

The host creates its display with `CGVirtualDisplay`,
`CGVirtualDisplayDescriptor`, `CGVirtualDisplaySettings` and
`CGVirtualDisplayMode`. **These are not public API.** They live inside
CoreGraphics.framework and are reached through class-dumped headers. Apple can
change or remove them in any release, with no deprecation and no warning.

**There is no supported alternative.** macOS has no public API for creating a
display. DriverKit has no display driver family at all — there is no
"DisplayDriverKit". The old `IOFramebuffer` kext route is deprecated and
effectively dead on Apple Silicon (it needs Reduced Security boot and cannot be
distributed). Sidecar and Universal Control are Apple's own consumer features
built on this same private machinery, not something third parties can call. A
hardware HDMI dummy dongle works but burns one of Apple Silicon's limited
external display pipes.

### Which macOS versions this has been seen working on

| macOS | Status | Source |
|---|---|---|
| 10.14 Mojave, 11.3 Big Sur | Classes present in CoreGraphics classdumps | [Mojave headers](https://github.com/Chr0nicT/macOS-Headers-10.14.6-Mojave/blob/main/Frameworks/CoreGraphics/1265.9/CGVirtualDisplayDescriptor.h), [Big Sur headers](https://github.com/cmsj/ApplePrivateHeaders/blob/main/macOS/11.3/System/Library/Frameworks/CoreGraphics.framework/Versions/A/CoreGraphics/CGVirtualDisplayDescriptor.h) |
| 14 Sonoma, 15 Sequoia | Runtime class-resolution probe passes in VMs | [Crisp issue #22](https://github.com/didriksg/Crisp/issues/22) |
| 26 Tahoe | Same probe passes (26.5.1); **and verified directly here on 26.6.2** | [Crisp issue #22](https://github.com/didriksg/Crisp/issues/22); `vdprobe` output in this repo |
| 26 Tahoe, shipping products | BetterDisplay lists macOS 26 support | [BetterDisplay](https://github.com/waydabber/BetterDisplay) |

The API has also **gained** properties over time — `rotation` on
`CGVirtualDisplay` and `CGVirtualDisplaySettings`, plus `refreshDeadline`,
`isReference`, and a `transferFunction` initializer on `CGVirtualDisplayMode`
— confirmed by a runtime dump on 26.3.1 and by generated 26.4 headers
([screen-salvage audit](https://github.com/ShashkovS/screen-salvage/blob/main/docs/V2_RUNTIME_AUDIT.md),
[26.4 headers](https://github.com/thatmarcel/macOS-26.4-headers/blob/main/headers/CoreGraphics/CGVirtualDisplay.h)).
This project does not use any of them, so it works on older releases too. The
exact version that introduced them is not documented anywhere I could find.

**Run `swift run vdprobe` first on any new macOS version.** If it fails,
nothing else in this project can work, and its output is the bug report.

### Known traps, and what this project does about them

- **A second display with the same identity is refused.** macOS keys a
  display's saved arrangement to its vendor/product/serial, so the identity
  must be stable across restarts — but `initWithDescriptor:` returns nil if
  that identity is already in use by a live display. Both are true at once.
  *Handled:* the host tries its stable identity first and walks the serial
  forward only when it is taken. `vdprobe` uses an identity of its own so it
  works while the app is running. This was caught by running the two together.
- **macOS substitutes its own mode.** A display routinely comes up at a scaled
  mode nobody asked for. *Handled:* the requested mode is re-asserted after
  creation.
- **`CGDisplayCopyAllDisplayModes` hides HiDPI modes** unless
  `kCGDisplayShowDuplicateLowResolutionModes` is passed in the options
  dictionary. Without it the 2× mode is invisible and the display silently
  stays at 1×. This cost real time to find; it is the single most
  consequential line in the display code.
- **The HiDPI ladder must be declared as a pair.** Declaring only the
  point-size mode means the 2× variant is never enumerated. *Handled.*
- **Teardown is asynchronous.** Recreating a display before WindowServer has
  finished makes the next `applySettings:` fail. *Handled:* teardown waits for
  the display to leave the active list, bounded at two seconds.
- **Reports disagree on whether releasing the object frees the display.**
  [One project](https://github.com/Sipioteo/FuVR) found only process exit
  released it; [another](https://github.com/didriksg/Crisp) recreates in the
  same process successfully. On this machine, in-process teardown and recreate
  both work — `vdprobe` does exactly that on every run. Treat it as
  environment-dependent.
- **A saved configuration can get poisoned.** Pressing "Stop Extending" from
  the system UI can make WindowServer store a broken configuration against that
  display identity, surviving app restarts
  ([report](https://github.com/peetzweg/opendisplay/issues/230)). The serial
  walk above is the escape hatch.
- **Sequoia and later re-prompt for Screen Recording periodically.** This
  affects every screen-capture app, not just this one. There is an
  undocumented entitlement Apple grants case by case; there is nothing this
  project can do about it.

### Distribution

Not sandboxed, so no entitlement is needed. **A sandboxed build would need**
`com.apple.security.temporary-exception.mach-lookup.global-name` for
`com.apple.VirtualDisplay`. Notarisation does not scan for private API use, so
a Developer ID build notarises fine. **The Mac App Store is impossible** —
App Review rejects private API.

## Installing it, from nothing

Everything below assumes a Mac on macOS 13 or later and an Android device on
Android 8 (API 26) or later.

```bash
# 1. Tools. Xcode's command line tools, and adb.
xcode-select --install
brew install --cask android-platform-tools

# 2. Check the private API works on your macOS before anything else.
cd macos-host/USBDisplayApp
swift run vdprobe
#    Expect "RESULT: PASS". If it fails, stop and read the section above.

# 3. Build the Mac app. This produces a real .app bundle, which matters:
#    macOS attaches Screen Recording permission to a bundle identity, and a
#    bare `swift build` binary has none, so the permission will not stick.
cd ../..
./tools/build-app.sh release

# 4. Build and install the Android client.
cd android-client
./gradlew assembleDebug
adb install -r app/build/outputs/apk/debug/app-debug.apk
```

Then:

1. On the Android device, turn on **Developer options → USB debugging**
   (tap Build number seven times in About phone to reveal Developer options).
2. Plug it into the Mac and accept the **Allow USB debugging** prompt. Any USB
   mode works — File transfer, Charging only, whatever — as long as debugging
   is on and the cable carries data. A charge-only cable will not do.
3. `open "build/USB Tablet Display.app"`. It appears in the menu bar.
4. Grant **Screen Recording** and **Accessibility** from its menu. Accessibility
   is what lets touch and pen move the Mac's pointer.
5. Pick **Start**. The client launches on the tablet by itself.

With **Connect automatically when plugged in** left on, steps 3–5 happen once.
After that, plugging the cable in is the whole interaction.

### When it does not work

| What you see | Why |
|---|---|
| "No tablet connected" with the cable plugged in | USB debugging is off, or the prompt was not accepted. The menu names any device it can see but cannot use. |
| "adb not found" | `brew install --cask android-platform-tools` |
| Start is greyed out | Screen Recording is not granted. |
| The tablet shows the picture but touch does nothing | Accessibility is not granted. |
| The display appears but stays black | Screen Recording was granted to your terminal rather than the app. Launch the `.app`, not the `swift build` binary. |
| "Address already in use" | Another copy is already running. |
| It streams to the wrong device | More than one is attached — pin the right one under Tablet in the menu. An emulator is deliberately ranked last, but it is still a candidate. |

### A note for anyone building inside a synced folder

SwiftPM keeps its build state in a SQLite database, which does not survive
being written inside a Dropbox, iCloud Drive or Syncthing folder — it fails
partway through with `disk I/O error`. `tools/build-app.sh` builds into
`~/Library/Caches` for this reason. Plain `swift build` in the package
directory will hit it; pass `--scratch-path` somewhere outside the synced tree.
