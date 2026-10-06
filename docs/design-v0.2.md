# glasstap v0.2: design

This document turns milestone v0.2 of [`PLAN.md`](../PLAN.md) into a design. v0.2 makes the app manage WebDriverAgent (WDA) itself, so that the user starts nothing by hand and the app runs for a day with no manual restart.

**v0.2 is done when** a developer installs Xcode, sets a team id in the app, plugs in an iPhone, and controls it from a browser with no other step. The app must then run for 24 hours with no manual restart while the iPhone is unplugged and plugged in again.

## Scope

In v0.2:

1. **WDA manager.** The app builds, signs, starts, watches and restarts WDA. It uses the methods of spikes S1 and S2.
2. **More than one iPhone.** Each iPhone gets its own capture, encoder and WDA. The viewer page picks an iPhone.
3. **Adaptive bitrate.** The encoder lowers its bitrate when the link to the viewer is congested, and raises it again when the link is clear.
4. **Listen address.** The user can choose another address than 127.0.0.1, for example the Tailscale address.
5. **Spike S4.** Measure the delay from the iPhone to the viewer.

Not in v0.2: a notarized DMG (v0.3), WebRTC, a hosted relay, and an MCP server.

## WDA manager

```text
 ┌──────── WDAManager (one for each iPhone) ────────┐
 │  1. source:  WebDriverAgent at a pinned version  │
 │  2. build:   xcodebuild build-for-testing        │──► .xctestrun (cached)
 │  3. start:   xcodebuild test-without-building    │──► child process
 │  4. address: devicectl → tunnel IPv6 address     │──► http://[addr]:8100
 │  5. watch:   GET /status every 5 s               │──► restart on failure
 └──────────────────────────────────────────────────┘
```

1. **Source.** The app downloads the WebDriverAgent source archive of one pinned release from GitHub into `~/Library/Application Support/glasstap/WebDriverAgent/<version>`. It checks the archive against a SHA-256 value in the app. The app never ships a signed WDA. WDA uses the BSD-3-Clause licence.
2. **Build.** The app runs `xcodebuild build-for-testing` with the user's team id and the bundle id `<prefix>.glasstap.wda`. The settings hold the team id and the prefix. The app keeps the `.xctestrun` file and builds again only when the version, the team or the iOS major version changes.
3. **Start.** The app runs `xcodebuild test-without-building -xctestrun … -destination id=<UDID>` as a child process. WDA is up when its output contains `ServerURLHere`.
4. **Address.** The app reads `connectionProperties.tunnelIPAddress` from `xcrun devicectl device info details --json-output`. It talks to WDA on `http://[<address>]:8100`. No forwarder listens on `127.0.0.1:8100`, and the app needs no usbmuxd client and no `pymobiledevice3`.
5. **Watch.** The app checks `GET /status` every 5 s. If the check fails three times, or the child process ends, the app starts WDA again. The waits between attempts grow to at most 5 minutes.

Signing failures need their own message. With a free Apple account, the profile is valid for 7 days. When a start fails because of the profile, the app builds again once. If that fails too, the menu tells the user to open Xcode and sign in.

The menu shows the state of each WDA: building, starting, running, restarting, or failed with the reason.

## More than one iPhone

- The app matches a capture device to an iPhone by name, because spike S3 found no other link. If two connected iPhones share a name, the menu asks the user to rename one.
- Each iPhone gets its own capture, encoder, viewer slot and WDA manager.
- The listeners stay on the same two ports. The paths carry the iPhone: `/devices/<id>/video` and `/devices/<id>/tap`. The id is the UDID.
- The viewer page shows a picker when more than one iPhone is connected. The viewer link can name an iPhone (`#token=…&device=<UDID>`).

## Adaptive bitrate

The host measures congestion itself, with no change to the stream format:

- For each viewer, the host knows how many messages are still waiting to be sent and how long the last sends took.
- If more than 5 messages wait, or a send takes more than 300 ms, the host multiplies the bitrate by 0.7.
- If the link is clear for 2 s, the host raises the bitrate by 10%, up to the bitrate in the settings.
- The lowest bitrate is 150 kbit/s. Under it, the host halves the frame rate instead.

VideoToolbox accepts a new `AverageBitRate` on a running session, so a change needs no new key frame. The menu and the viewer status bar show the current bitrate.

## Listen address

- The settings offer **This Mac only** (127.0.0.1, the default) and a list of the Mac's other addresses, with the Tailscale address marked.
- Any address other than 127.0.0.1 needs a confirmation, because the traffic then leaves the Mac without encryption, unless it goes through Tailscale.
- The token rules stay the same. The Host and Origin checks accept the chosen address.

## Spike S4: delay

1. The app serves a test page that shows a millisecond clock, synced to the host clock.
2. Safari on the iPhone opens the page through WDA.
3. The viewer page shows the same clock next to the video.
4. One screenshot of the viewer shows both clocks. The difference is the delay.

The README then states the delay on a LAN and on a 1.6 Mbit/s link.

## Security

- No forwarder listens on `127.0.0.1:8100` any more. This removes the risk that any local user reaches WDA through that port.
- **Open risk:** the CoreDevice tunnel address may be open to every local process on the host Mac. v0.2 must test this with a second user account. If it is open, the risk moves rather than goes away.
- **Unchanged risk:** WDA still listens on the iPhone's Wi-Fi address. WDA has no setting to stop that. The README keeps the warning.

## Testing

- **Unit tests:** parsing of `devicectl` JSON and of the `ServerURLHere` line, the restart backoff, name matching with duplicate names, the bitrate controller, and the address checks.
- **Device tests:** the iPhone 12 Pro on this Mac:
  1. First run on a clean user: the app downloads, builds and starts WDA with no other step.
  2. Unplug and plug the iPhone: capture and WDA come back by themselves.
  3. Kill the WDA process: the app starts it again within 30 s.
  4. Limit the link to 1 Mbit/s with the Network Link Conditioner: the bitrate falls, the picture stays current, and a tap still answers within 1 s.
  5. Two iPhones at once: both streams, and taps go to the right iPhone.
- **Soak test:** 24 hours with a viewer connected and three unplug cycles.

## Order of work

1. WDA manager for one iPhone, with the README changed to "no manual steps".
2. Adaptive bitrate.
3. Spike S4.
4. More than one iPhone.
5. Listen address.
6. Soak test.

Each step is its own pull request.

## Open questions

- Is the CoreDevice tunnel address open to other local users?
- Does `devicectl` work without a full Xcode install, with only the command line tools?
- Can WDA run without the "Automation Running" overlay that iOS shows during XCTest?
