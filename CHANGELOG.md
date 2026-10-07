# Changelog

## v0.3.0 (2026-10-08)

You install glasstap with one command from a clone, and you never type your team id. A locked iPhone no longer looks like a frozen stream.

### Added

- **`make install`.** It finds the team of your Apple Development certificate, or takes `TEAM=`, and writes it to `Config/Local.xcconfig`. Then it builds a Release app signed with that team, copies it to `~/Applications`, and opens it.
- **The team comes from the app's signature.** With no team set, glasstap signs WDA with the team that signed the app.
- **No Homebrew.** If XcodeGen is not installed, the build downloads XcodeGen 2.46.0 once and checks its SHA-256. A clean Mac needs only Xcode.
- **A banner for a locked iPhone.** The viewer asks `GET /devices/<id>/locked` every 3 s. It shows "The iPhone is locked" with a **Wake screen** button, or "Unlock the iPhone to control it" while WDA waits for the unlock. The frames cannot show a lock: a locked iPhone can send none, or keep sending its last app screen.
- `scripts/slow-viewer.py --device <udid>` watches one of several iPhones.

### Fixed

- **An idle iPhone on USB was not found.** devicectl lists its tunnel as "disconnected" until a command uses it, and glasstap skipped it. On a Mac with no recent devicectl use, WDA never started.
- **A locked iPhone at WDA start.** glasstap showed "starting" and restarted the run every 180 s. Now it shows "unlock the iPhone" and waits. The run goes on by itself after the unlock.

### Changed

- The project has no Developer ID, so there is no notarized DMG and no Homebrew cask. See decision 6 in [`PLAN.md`](PLAN.md).
- The prototype reads its SSH host and capture bundle id from `PHONE_REMOTE_HOST` and `PHONE_REMOTE_BUNDLE_ID`.

### Tested on devices

- **24 hours on an iPhone 15** on a second Mac, with a full-speed viewer. The app kept one process, and WDA ran once with no restart. Memory stayed between 93 and 97 MB, and the viewer got 4.5 GB of video. The only gap without frames came from Auto-Lock before it was set to Never.
- **Two iPhones on one Mac:** each has its own stream and WDA. The paths without `/devices/<id>` answer 409.
- **Unplug and plug in again:** only that iPhone's session ended, and the other stream had no gap. WDA ran again 24 s after the plug-in.
- **A dark display and a lock:** the banners showed in the right state, Wake brought the lock screen live, and the banner went away within 3 s of the unlock.
- **A fresh clone on a Mac with no Homebrew and no XcodeGen:** the team lookup, the XcodeGen download and the Release build took 20 s. WDA started by itself.

### Not tested yet

- Tailscale, and a Wi-Fi change while a LAN address is the listen address.
- The 7-day profile expiry of a free Apple account.
- A display that goes dark during a session on an iPhone with no passcode.

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
