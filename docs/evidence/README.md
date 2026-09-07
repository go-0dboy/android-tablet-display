# Evidence

Captured on 2026-09-07. Every file here was taken from a real run on the
machine described in [../STATUS.md](../STATUS.md) — an M4 Max on macOS 26.6.2.

**What these do and do not show.** The Android side of every capture is an
**emulator** (`sdk_gphone64_arm64`), not a physical handset. No Samsung device
and no Wacom display were attached to this machine when these were taken. The
emulator genuinely exercises the whole software path — adb reverse forwarding,
the hello handshake, virtual display creation, H.264 encode, MediaCodec decode,
rendering — but it says nothing about real USB throughput, pen hardware, or
display latency. Treat these as "the pipeline is connected end to end", not as
performance figures for a phone.

| File | What it shows |
|---|---|
| `01-virtual-display-on-mac.png` | The virtual display's own contents, captured on the Mac. This is the display macOS created — it is a real display that `screencapture -D` can target like any other. |
| `02-same-frame-on-the-tablet.png` | The same clock, captured on the Android client with `adb exec-out screencap`. The client is decoding and rendering the Mac's display. |
| `03-vdprobe-output.txt` | `swift run vdprobe` on macOS 26.6.2: the private CGVirtualDisplay API is present, creates a display, offers a HiDPI mode ladder, and tears down cleanly. |
| `04-host-session-log.txt` | A host session: the client's hello, the display built to match its metrics, and the per-5s throughput and encode-latency lines. |
| `05-displays-list.txt` | `system_profiler SPDisplaysDataType` with the virtual display listed alongside the two physical ones, under the client's own device name. |

Full-screen screenshots are deliberately absent. The Mac they would come from
has personal mail and other private material on it, and this is a public
repository; the targeted captures above prove the same things without that
risk. Anyone reproducing this can take their own.

## The clock

`01` and `02` show `latencyclock`, which draws a timestamp twice: as text, and
as a row of black and white blocks encoding the same value in binary.
`tools/decode-clock.py` reads the blocks, so a latency measurement never
depends on anyone squinting at digits.

The two captures here are seconds apart and are **not** a latency measurement —
they are proof the same content reaches both screens. See
[../STATUS.md](../STATUS.md) for why `adb screencap` cannot produce a
glass-to-glass number, and what can.
