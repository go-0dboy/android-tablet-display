# The two Wacom "Movink" products, and what this project does with each

> **If you are here for the MovinkPad Pro 14, skip to
> [the MovinkPad section](#the-movinkpad-pro-14-a-streaming-target).** It is a
> standalone Android tablet, so it is a *client* for this project — the
> Android app installs on it and it becomes a Mac display. The rest of this
> page is about the Movink 13 pen display, which is a different product that
> needs the opposite treatment.

## First: the name

There is **no Wacom "Movink 14" pen display.** Two different products get
confused, and they need opposite things from this project:

| Product | What it is | What this project does with it |
|---|---|---|
| **Wacom Movink** (model DTH135K0, marketed as "Movink 13") | A 13.3" OLED **pen display**: a monitor with a digitiser, connected by USB-C DisplayPort Alt Mode. 1920×1080, 60 Hz. | Nothing needs streaming. macOS already draws to it. This project only helps with layout — see below. |
| **Wacom MovinkPad Pro 14** | A standalone **Android tablet** with its own screen and its own operating system. | This is a streaming target. Install the Android client on it and it becomes a Mac display like any other tablet. |

If the goal is "use it as an extra Mac screen with pen support", those are two
completely different paths. Worth checking which one is actually on the desk
before following either.

## The MovinkPad Pro 14: a streaming target

The MovinkPad Pro 14 is a **standalone Android tablet** with a Wacom EMR
digitiser — the same electromagnetic-resonance technology as Wacom's pen
displays, with a battery-free pen. It runs its own Android, so it is not a
monitor and macOS cannot draw to it directly.

That makes it exactly what this project is for. Install the Android client on
it and it becomes a Mac display with pen pressure and tilt:

```bash
cd android-client && ./gradlew assembleDebug
adb -s <serial> install -r app/build/outputs/apk/debug/app-debug.apk
```

Then the normal flow in [STATUS.md](STATUS.md): USB debugging on, cable in,
start the Mac app.

**Nothing in this project is specific to it.** It is treated like any other
Android tablet: the client reports its resolution and density, the host builds
a display to match. A Wacom EMR digitiser is a better pen than most — that is
the point of the hardware — but from Android's side it is still a
`TOOL_TYPE_STYLUS` reporting `AXIS_PRESSURE` and `AXIS_TILT`, which is what the
client already reads.

**Wacom's macOS driver is irrelevant here.** It drives Wacom hardware attached
to a Mac; the MovinkPad's digitiser is attached to its own Android. Do not
install it for this.

### Confirming what its digitiser actually sends

EMR digitiser behaviour is not documented in any way that can be relied on —
which axes are populated, the pressure range, whether tilt is reported at all,
and whether the side buttons arrive as `BUTTON_STYLUS_PRIMARY` or
`BUTTON_SECONDARY` all vary. So ask the hardware:

```bash
./tools/pen-probe.sh <serial>
```

That turns on the client's pen diagnostics over adb and tails the log while you
hover, draw, tilt and press the buttons. The real axis names and ranges belong
in [STATUS.md](STATUS.md) once someone has run it.

Sources: [Wacom Movink product page](https://www.wacom.com/en-us/products/pen-displays/wacom-movink),
and Wacom's own macOS driver notes, which list "Wacom Movink 13 DTH135" and
separately "Wacom One 13 touch DTH134" — DTH134 is a *different* product, not
the Movink ([driver release notes](https://cdn.wacom.com/u/productsupport/drivers/mac/professional/releasenotes/Mac_6.4.14-1.html)).

## The Movink 13 needs no streaming

It is a real display over DisplayPort Alt Mode. Plug it into an Apple Silicon
Mac and macOS extends onto it with no software at all. Streaming a virtual
display to it would be strictly worse: an encode/decode round trip and a
latency penalty in exchange for nothing.

What macOS does *badly* is remember it. Unplug and replug and the arrangement,
the scale and the rotation have all drifted, and the pen has to be re-restricted
to that one display by hand. That is the gap this project fills.

## What the host app actually does

**Recognises it.** The Movink enumerates as three USB devices under Wacom's
vendor id `0x056A`:

| Product id | Device |
|---|---|
| `0x03F0` | `Wacom Movink 13` — the composite HID device (pen, touch, pad) |
| `0x03F1` | `Wacom Movink 13 Hub` — an internal USB hub |
| `0x03F2` | `Wacom Movink 13 Billboard` — how a USB-C device advertises DP Alt Mode |

Confirmed against [libwacom](https://raw.githubusercontent.com/linuxwacom/libwacom/master/data/wacom-movink-13.tablet),
[OpenTabletDriver](https://github.com/OpenTabletDriver/OpenTabletDriver/blob/master/OpenTabletDriver.Configurations/Configurations/Wacom/DTH-135.json),
and a captured `lsusb` dump
([wacom-hid-descriptors #376](https://github.com/linuxwacom/wacom-hid-descriptors/blob/3dd4a3d41d86a9a51c57d7424af26208d51b9097/Wacom%20Movink%20DTH135K0C/sysinfo.4XIn8KkXzp/lsusb.txt)).

The host matches on those USB ids via IOKit rather than on the display's EDID.
**Deliberately:** no public capture of the Movink's EDID exists, so its
monitor-name string is unknown, and 1920×1080 alone identifies nothing — it is
the commonest resolution there is. The host will only call an anonymous 1080p
panel a Movink when a Movink's USB device is also present *and* the panel
identifies itself as nothing else. There is a unit test for exactly the case of
an ordinary 1080p monitor plugged in beside a Movink.

**Remembers a layout for it.** Position, mode (point and pixel size, so a
HiDPI mode is distinguishable from its 1× namesake), and whether it should be
the main display. Saved per display identity in
`~/Library/Application Support/USBTabletDisplay/display-presets.json`, keyed on
vendor + product + resolution — deliberately **not** the serial number, so two
identical panels share a preset and nothing device-unique is written to disk.

**Applies it from the menu.** When a pen display is attached, the menu grows
*Apply saved layout* and *Save layout as it is now*. A preset is seeded the
first time a Movink is recognised, but **never applied without being asked** —
and the default deliberately does not make it the main display, because moving
someone's menu bar unasked is how an app gets deleted.

## What it deliberately does not do

Three of the things you might want here are not available to any third-party
app, and the app says so rather than silently not doing them:

- **Rotation.** No public API sets display rotation. The preset stores it and
  the app reports that it could not be applied. Set it in System Settings.
- **HDR / EDR off.** No public API toggles it per display.
- **Pen mapping.** Only Wacom's driver can map its own digitiser. In Wacom
  Center, set the pen's screen area to the Movink alone rather than All
  Displays; the physical **Display Toggle** button switches the pen between
  screens if you want that on a key
  ([Wacom's own note](https://web.archive.org/web/20250416045139/https://support.wacom.com/hc/en-us/articles/1500006344202-Why-isn-t-my-pen-controlling-the-other-screen-while-in-multiple-monitor-function-)).
  The app prints this reminder when you apply a preset.

## The driver, on macOS 26

Wacom's unified driver ("Wacom Center") **6.4.14-1**, released 26 August 2026,
lists support for macOS 13, 14, 15 and 26. macOS 26 needs **6.4.11 or newer**.
[Download](https://www.wacom.com/en-us/support/product-support/drivers) ·
[release notes](https://cdn.wacom.com/u/productsupport/drivers/mac/professional/releasenotes/Mac_6.4.14-1.html) ·
[macOS 26 article](https://web.archive.org/web/20260621143354/https://support.wacom.com/hc/en-us/articles/34849924621975-Does-Wacom-have-a-driver-for-macOS-26-Tahoe)

After installing, macOS asks for three separate permissions, and **they must be
granted within 30 minutes of installing or the driver has to be reinstalled**:

- **Accessibility** → `Wacom_IOManager`
- **Input Monitoring** → `WacomTabletDriver`
- **Login Items & Extensions → Allow in the Background** → Wacom

Because the Movink contains a USB hub, macOS will also ask to **allow the use
of a hub**.

### Open issues, from Wacom's own current notes

- **macOS 26: the pen does not work in System Settings windows.** Wacom's
  wording: use a mouse or trackpad for those. Reported to Apple, still open.
- **Sleep/wake loses the device** (issue 13102, all models, still listed in the
  August 2026 notes): if Wacom Center is open and the device is unplugged and
  replugged after the Mac sleeps, Wacom Center stops seeing it. Workaround:
  Wacom Center → General Settings → **Restart Driver**.

### If the screen is dim or will not come on

This is a **power** problem, not a driver one, and it is the single most common
complaint:

- Under 15 W the brightness is limited or it will not power on at all.
- A single USB-C cable from a port supplying **≥15 W** is the minimum.
- **Full brightness needs ≥20 W** into the Movink's second USB-C port, from an
  AC adapter or a USB-PD battery.
- A **quick-blinking white LED means it is power-starved.**
- A replacement cable must carry 5 Gbps or better. A charge-only cable carries
  no video.

Every Apple Silicon MacBook Pro port supports DP Alt Mode, but per-port power
varies by model, so a single-cable setup may still show the dim-screen symptom.

[Power requirements](https://web.archive.org/web/20250811195641/https://support.wacom.com/hc/en-us/articles/21895707010071-What-is-the-power-requirements-for-the-device-or-power-source-needed-to-use-Wacom-Movink) ·
[LED meanings](https://web.archive.org/web/20250811195641/https://support.wacom.com/hc/en-us/articles/21655640668951-What-does-the-LED-of-Wacom-Movink-mean)

## Could the virtual display be mirrored onto the Movink, to test pen input without Wacom's driver?

Asked and answered: **no, and it would not help.**

Mirroring a virtual display onto the Movink is easy — it is a normal display,
so macOS's own mirroring does it. But that only moves *pixels*. The Movink's
pen is a USB HID device owned by Wacom's driver; it does not send anything to
this app, and nothing this app injects changes where the physical stylus points.
Mirroring would produce a screen showing the virtual display's contents while
the pen went on driving the real cursor exactly as before.

Reading the digitiser directly would mean claiming the HID device with
`IOHIDManager`, parsing Wacom's vendor-specific report descriptors, and fighting
Wacom's own driver for the device — a tablet driver, in other words. That is a
large project with no benefit over the driver Wacom already ships for free.

**Not built. Not recommended.** The Movink's value here is the layout preset.

## Verification status

Everything in this file is from documentation and from published USB
descriptors. **No Wacom hardware was attached to the machine this was developed
on.** Detection has been tested only against synthetic display identities in
unit tests. The USB ids are third-party-confirmed but unverified against a real
panel on macOS, and the EDID name is unknown. Nothing here should be trusted as
tested until someone plugs one in.
