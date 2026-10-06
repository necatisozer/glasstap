# Changelog

## v0.2.0 (2026-10-06)

glasstap now runs WebDriverAgent (WDA) itself. You install Xcode, enter your team id, plug in an iPhone, and control it from a browser. You start nothing by hand.

### Added

- **WDA manager.** The app downloads a pinned WebDriverAgent source (16.12.10, SHA-256 checked), builds it with your team, starts it with `xcodebuild test-without-building`, and talks to it on the iPhone's CoreDevice tunnel address. It watches WDA and restarts it with a growing wait. After a crash, the next launch stops the test run that the crash left behind. `pymobiledevice3` is no longer necessary.
- **Setup window.** It checks Xcode, the team id, each iPhone, camera access and WDA, and gives a fix for each problem. It opens by itself when a new problem appears.
- **Adaptive bitrate.** The viewer reports what it has received, and the app adjusts the bitrate to the link. Below a floor, the picture steps down from 590 to 392 to 294 px. A link that recovers gets its bitrate and size back.
- **More than one iPhone.** Each iPhone has its own stream, viewer and WDA. Paths name the iPhone (`/devices/<udid>/…`), `GET /devices` lists them, and the viewer page has a picker.
- **Listen address.** The app listens on 127.0.0.1 by default, or on one address that you choose, for example a Tailscale address. Each change makes a new access token.
- `scripts/slow-viewer.py`, a slow reader to test the bitrate control.

### Changed

- The config message of the stream has a session id, and a new stats message (type 4) is optional. Old pages get the same stream as before.
- The control port keeps connections open, so reports through an SSH tunnel do not pay for a new connection each time.

### Measured

- 86 ms median delay from the iPhone screen to a browser on the same Mac (81–88 ms).
- On a real WAN SSH loop with about 0.5 Mbit/s and a 230 ms round trip, the stream steps down to fit the link. It climbs back when the link clears.
- A one-hour run with a full-speed viewer on the same Mac: one WDA run with no restart, frames in every second, and no memory growth (94 MB at the start, 72 MB at the end).

### Not tested yet

- Two physical iPhones at the same time.
- Tailscale, and a Wi-Fi change while a LAN address is the listen address.
- An unplugged iPhone, and a dark display.
- The 7-day profile expiry of a free Apple account.
- A run of one full day.

## v0.1.0 (2026-10-06)

The first menu-bar app: USB screen capture, H.265 or H.264 hardware encoding, a viewer page with WebCodecs, taps through WebDriverAgent, and a token for each launch. You had to start WDA by hand.
