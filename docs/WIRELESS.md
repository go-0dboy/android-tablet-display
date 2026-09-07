# Wireless mode

USB stays the default. Wireless is an explicit choice in both apps, because it
trades latency for freedom and the person should make that trade knowingly.

## How a device is trusted

Over USB the cable is the authorisation: `adb` already made you accept **Allow
USB debugging**, and the socket only listens on loopback, so nothing on the
network can reach it.

Over Wi-Fi that is gone. The host binds every interface, and a live video feed
of your screen is exactly the thing you do not want any device on the café Wi-Fi
to be able to request. So wireless pairs first, with the same shape of check as
a Bluetooth passkey:

1. The client sends a random nonce and a long-lived identity key.
2. The host answers with its own nonce and key.
3. Both derive the **same six digits** from those four values —
   `SHA-256("usbtabletdisplay-sas-v1" ‖ clientNonce ‖ hostNonce ‖ clientKey ‖ hostKey)`,
   first four bytes, modulo 10⁶.
4. Both show the digits. You confirm on the Mac that they match.
5. The host records the client's key.

A returning client proves it still holds that key with
`HMAC-SHA256(clientKey, "usbtabletdisplay-session-v1" ‖ clientNonce ‖ hostNonce)`
over **fresh** nonces, so an old proof cannot be replayed. That is what makes
reconnecting need no taps at all.

Until a session is authenticated the host honours **only** the pairing messages
and discards everything else. Not one frame is sent first.

The comparison is constant-time. Both implementations are unit-tested against
fixed vectors on both sides, so the Swift and Kotlin derivations cannot drift
apart without a test going red.

## What this protects, and what it does not

**It authenticates the peer.** An unpaired device gets nothing.

**It does not encrypt the video.** Frames go over plain TCP. Anyone already
capturing traffic on your network can reconstruct the stream. Pairing stops the
wrong device connecting; it does not hide the pixels from someone with a packet
capture.

This is a deliberate, documented limit rather than an oversight. Fixing it means
a real key exchange and an AEAD over the frame stream — worth doing, not done.
**Do not use wireless mode on a network you do not trust.**

## Finding the Mac

The host advertises `_usbtablet._tcp` over Bonjour with the ports in its TXT
record; the client browses for it with `NsdManager`. That removes the "type in
your Mac's IP address" step, which is where people give up.

macOS will ask for **Local Network** permission the first time. If the menu says
"Not advertising yet", that permission was refused — System Settings → Privacy
& Security → Local Network.

## Where it stands

**Implemented, and never run over an actual network.** The two halves have not
talked to each other wirelessly. The cryptography is tested on both sides
against fixed vectors; the discovery and transport are not.

**There is no wireless latency figure**, and there will not be an honest one
until it runs on real hardware over real Wi-Fi. Expect it to be worse than USB —
Wi-Fi adds queueing and retransmission that a cable does not have — but "worse"
is not a number and this file will not invent one.

The frame encoder is shared with USB mode: the same H.264 (or HEVC) stream over
TCP, with the same length-prefixed framing. That was the deliberate scope call —
discovery, pairing and the input channel are done, and the codec path did not
need re-inventing to get there. A UDP transport with forward error correction
would suit a lossy network better than TCP, whose retransmissions turn a dropped
packet into a visible stall. That is the next step if wireless proves worth it.
