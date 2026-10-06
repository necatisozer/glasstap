# glasstap: project plan

## Goal

glasstap shows a physical iPhone live in a browser and lets you tap, swipe and type on it. The iPhone connects over USB to a Mac (the host). The viewer can be on another computer, also on a slow link and behind NAT.

Version 1 covers:

- One host Mac, and one or more iPhones on USB.
- One viewer at a time for each iPhone, in a desktop browser.
- Links of 1–2 Mbit/s, through a tunnel that the user already has (Tailscale, Cloudflare Tunnel or SSH).

Version 1 does not cover:

- A hosted relay, user accounts or billing.
- Android devices or iOS simulators.
- Test automation, flow recording or an MCP server for AI agents. These can come later (see [Later](#later)).

## Why it exists

Existing open-source tools get the screen from WebDriverAgent (WDA) screenshots or from the WDA MJPEG stream. That stream runs at 10 fps by default, and raw MJPEG needs 25–40 Mbit/s. The research of 2026-10-06 found no maintained tool that uses the USB screen-capture device of macOS (the QuickTime route). glasstap uses that device and encodes the screen with the hardware H.265 encoder. The prototype gets about 30 fps in less than 1 Mbit/s.

The closest project is [iphone-use](https://github.com/leeguooooo/iphone-use) (MIT). It re-encodes WDA frames to H.264, so it keeps the WDA frame-rate limit. [GADS](https://github.com/shamanec/GADS) is a full device farm, but it has open bugs on iOS 26.4 and 26.5.

## Measured baseline

The prototype ran on an Apple M4 Mac mini with macOS 26.6.2 and an iPhone 15 with iOS 26.6.2. The viewer was Chrome on another Mac. The path was SSH through Cloudflare Tunnel, with an uplink of about 1.6 Mbit/s.

| Measurement | Value |
|---|---|
| USB capture, native size | 1180 × 2556, about 56 fps |
| H.265 stream at 590 × 1278 | about 29 fps, about 42 KB/s on a still screen |
| Round trip of one control request | median 160 ms |
| Tap, from click to WDA reply | about 0.75 s |
| WDA JPEG frames, best case (fallback) | about 9 fps |

The prototype proved these facts:

- The CoreMediaIO capture device shows the iPhone screen after the process sets `kCMIOHardwarePropertyAllowScreenCaptureDevices`. The device can take about 6 s to appear.
- A process started over SSH cannot get camera permission (TCC). The capture must run as an app in the desktop session.
- If a development certificate signs the app, the camera approval stays valid after a rebuild.
- Control and video must use separate connections. On one shared TCP connection, a tap took about 15 s. On its own connection, it took about 0.3 s.
- If two viewers share one tunnel, a viewer that stops reading stalls the other one. So the host serves one viewer, and the new viewer replaces the old one.
- Chrome decodes both H.265 and H.264 through WebCodecs.

These facts are **not measured yet**:

- The delay from a change on the iPhone to the same change in the viewer.
- Capture on iOS 17 and 18, on a locked iPhone, and on Intel Macs.
- Capture while QuickTime Player also captures the same iPhone.

## Architecture

```text
 iPhone ──USB──┐
               │
 ┌─────────────┴──────────── host Mac: glasstap.app (menu bar) ──┐
 │  Device manager ── finds iPhones, matches capture ↔ UDID       │
 │  Capture + encoder ── CoreMediaIO → VideoToolbox H.265/H.264   │
 │  WDA manager ── builds, starts and watches WDA (v0.2)          │
 │  HTTP server ── viewer page, /video stream, /control API       │
 └──────────────┬───────────────────────────────┬────────────────┘
                │ video connection              │ control connection
                ▼                               ▼
          ┌──────────── browser viewer (WebCodecs, canvas) ────────────┐
          └────────────────────────────────────────────────────────────┘
```

Design rules that come from the prototype:

1. Use one connection for video and another for control.
2. Serve one viewer for each iPhone. Tell the replaced viewer, so that it stops and offers "Take it back".
3. Listen on 127.0.0.1 by default. If the user binds another address, require an access token.
4. Send each video frame as a length, a type byte and Annex B data. The types are config, key frame, delta frame and replaced. The viewer skips delta frames until the next key frame when it falls behind.
5. Keep the WDA JPEG relay as a fallback for Macs where capture fails.

Adaptive bitrate comes in v0.2. The viewer reports the receive rate and the frame age, and the host changes the encoder bitrate.

## WebDriverAgent

- Depend on [appium/WebDriverAgent](https://github.com/appium/WebDriverAgent), which uses the BSD-3-Clause licence.
- Do not ship a signed WDA. Each user builds and signs it with their own Apple account. A free account gives a profile that is valid for 7 days.
- Do not depend on `pymobiledevice3`, because it uses the GPL-3.0 licence. The prototype uses it to start WDA and to forward port 8100. v0.2 must replace both, and spikes S1 and S2 check how.

## Distribution and permissions

- Ship a DMG that a Developer ID signs and Apple notarizes. Also publish a Homebrew cask, and support a build from source.
- The hardened runtime needs the `com.apple.security.device.camera` entitlement. `Info.plist` needs `NSCameraUsageDescription`.
- If a user builds from source with an ad-hoc signature, macOS asks for camera approval again after each rebuild. The README must say this.
- While the capture runs, iOS shows 9:41 in the status bar. The README must say this, because users think that the clock is wrong.

## Remote access

Version 1 has no relay. The README documents three ways to reach the host:

1. Tailscale (recommended). It can connect directly, which can cut the round trip. Behind CGNAT it may fall back to its relay.
2. Cloudflare Tunnel.
3. SSH port forwarding (`ssh -L`). Use a separate SSH connection for video and for control.

## Milestones

A spike is a short test that decides the design. Do not start a milestone before its spikes pass.

| Milestone | Content | Done when |
|---|---|---|
| **v0.1** Package what works | Menu-bar app: device discovery, capture, encoder, HTTP server, viewer page. WDA is a prerequisite that the user starts. See [the v0.1 design](docs/design-v0.1.md). | A developer builds the app from Xcode, starts WDA from the docs, and sees and taps the iPhone on the same Mac. |
| **S1** Start WDA with Xcode tools | `xcodebuild test-without-building` with a WDA `.xctestrun` on iOS 26. | WDA answers `/status` with no `pymobiledevice3`. |
| **S2** Reach port 8100 | A native usbmuxd client, or the CoreDevice tunnel address of iOS 17+. Capture a real usbmuxd exchange before you write the client. | A tap reaches WDA with no `pymobiledevice3`. |
| **S3** Map capture device to UDID | The capture `uniqueID` is not the UDID. Find the link between them. | With two iPhones on USB, each stream matches the right WDA. |
| **v0.2** WDA manager and robustness | WDA build, sign, start and restart. Access token. Adaptive bitrate. Reconnect. More than one iPhone. | The app runs for a day with no manual restart. |
| **S4** Measure the delay | A test page on the iPhone shows a millisecond clock. Compare it with the viewer's clock in one screenshot. | The README states the delay on LAN and on a 1.6 Mbit/s link. |
| **v0.3** Release | Notarized DMG, Homebrew cask, setup guide, benchmark table. | The setup takes less than 10 minutes on a clean Mac. |

## Spike results

Measured on 2026-10-06 with an iPhone 12 Pro (iOS 26.5) on USB, Xcode 27 and macOS 26.6.2.

| Spike | Result | What v0.2 does with it |
|---|---|---|
| **S1** Start WDA with Xcode tools | **Passed.** `xcodebuild build-for-testing` built WebDriverAgent 16.12.10, signed with the user's team. `xcodebuild test-without-building -xctestrun … -destination id=<UDID>` started WDA with no `pymobiledevice3`. | The WDA manager builds once and starts WDA with `test-without-building`. |
| **S2** Reach port 8100 | **Passed.** `xcrun devicectl device info details` gives the iPhone's CoreDevice tunnel address (`connectionProperties.tunnelIPAddress`, an IPv6 address). WDA answered on `http://[<address>]:8100` in 12 ms. The `<UDID>.coredevice.local` name also works, but its lookup took 5 s. | The app reads the tunnel address from `devicectl` and talks to WDA directly. No forwarder listens on `127.0.0.1:8100`, and no usbmuxd client is needed. |
| **S3** Map capture device to UDID | **No direct link.** The capture `uniqueID` is not the UDID, the ECID or the CoreDevice identifier, and it does not appear in the `devicectl` data. Only the device name is the same on both sides. | Match by name. If two iPhones share a name, ask the user to rename one. |
| **S4** Measure the delay | Not done. | Still open. |

Other findings:

- `POST /session/<id>/wda/lock` fails on this iPhone with "Timed out while waiting until the screen gets locked", with and without a capture. A test of the dark-display path needs a press of the side button.
- WDA logged `ServerURLHere->http://<Wi-Fi address>:8100`, so it also listens on the iPhone's Wi-Fi address. This confirms the risk below.

## Later

- An MCP server, so that AI agents can see and control the iPhone.
- WebRTC over UDP, for less delay on poor links.
- An accessibility-tree overlay and flow recording, as in iphone-use.
- App install from the viewer.
- More than one viewer, with one in control.

## Risks

- An iOS update can break XCTest or WDA. GADS has had this on iOS 26.4 and 26.5.
- Apple can change or remove the iOS screen-capture device of CoreMediaIO.
- WDA signing is the hardest step for new users, especially with a free Apple account.
- WDA on the iPhone listens on the Wi-Fi address too, with no authentication. Anyone on that network can control the iPhone (measured: `http://<iPhone IP>:8100/status` answered 200). Find a way to bind WDA to the USB link only, or tell users to keep the iPhone on a trusted network.
- On the host Mac, the prototype forwards WDA to `127.0.0.1:8100` with `pymobiledevice3`. Any local user on the host can control the iPhone through that port. Spike S2 removes the forwarder, but the CoreDevice tunnel address is also open to every local process on the host. v0.2 must check whether macOS limits that address to the user who owns the tunnel.
- Apple's trademark rules do not allow "iPhone" or "iOS" in a product name. The final name must avoid them.

## Decisions

Made on 2026-10-06:

1. **Name: glasstap.** No GitHub repo and no Homebrew package used it. The first working name, "tapstream", was a mobile marketing SDK, so it would confuse people in the same field.
2. **Licence: MIT.** It is the simplest choice and the most common one for iOS developer tools. A patent grant (Apache-2.0) matters little for a tool of this size.
3. **Minimum macOS: 14 (Sonoma).** It has the SwiftUI menu-bar API and every capture and encoder API that the prototype uses. Only macOS 26 is tested so far.
4. **GitHub owner: necatisozer.** The repo stays private until the prototype no longer holds personal values (the `mac-mini` host and the `com.necatisozer` bundle id).
5. **JPEG fallback: not in v0.1.** It needs `pymobiledevice3` and the WDA MJPEG stream, which v0.1 avoids. The code stays in `prototype/`.

## Prototype sources

The prototype is in [`prototype/`](prototype/), copied from `~/bin` on 2026-10-06. It works for one setup only: the default SSH host is `mac-mini`, and the bundle id is `com.necatisozer.iphonecapture`.

- `iphone_capture.swift`: capture, encoder and stream server.
- `phone_remote.py` and `phone_remote.html`: control server and viewer page.
- `phone_frame_relay.py`: the WDA JPEG relay.
- `phone-remote`: the start script.
