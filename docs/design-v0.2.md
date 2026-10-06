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

1. **Source.** The app downloads the WebDriverAgent source archive of one pinned release (16.12.10) from GitHub into `~/Library/Application Support/glasstap/WebDriverAgent/<version>`. It checks the archive against a SHA-256 value in the app before it unpacks it. Then it moves the source into place in one rename, so a half-unpacked folder never appears. The app never ships a signed WDA. WDA uses the BSD-3-Clause licence.
2. **Build.** The app runs `xcodebuild build-for-testing -destination id=<UDID> -allowProvisioningUpdates` with an xcconfig file that it writes. The file sets the user's team, automatic signing, and the bundle id of the runner target only. Xcode adds `.xctrunner`, so the runner is `<prefix>.xctrunner`. The default prefix is `glasstap.wda.<team id in lower case>`, and the settings can change it. The build goes into `wda-build/<key>`, where the key is the WDA version, the team, the prefix and the iOS major version. The app builds again only when the key changes, or once after a signing failure.
3. **Start.** The app runs `xcodebuild test-without-building -xctestrun … -destination id=<UDID>` as a child process in a process group of its own. WDA is up when its output contains `ServerURLHere`. The app sets `NSUnbufferedIO=YES`, because xcodebuild holds back its output when it writes to a pipe.
4. **Address.** The app reads `connectionProperties.tunnelIPAddress` from `xcrun devicectl device info details --json-output`. It talks to WDA on `http://[<address>]:8100`. The lookup before the build gives the address for the start, so the start needs no second devicectl call. The app reads the address again when the iPhone's entry in `devicectl list devices` changes, because the address changes when the iPhone is plugged in again. No forwarder listens on `127.0.0.1:8100`, and the app needs no usbmuxd client and no `pymobiledevice3`.
5. **Watch.** The app checks `GET /status` every 5 s. If the check fails three times in a row, or the child process ends, the app starts WDA again. The waits between attempts are 2, 4, 8 … s, and at most 5 minutes. After 60 s in good health, or for a new iPhone or team, the next wait is 2 s again.

**Stop.** The app stops the test run at quit, when the iPhone goes, when the team or the prefix changes, and before each new start. A stop sends SIGTERM to the whole process group, and SIGKILL after 5 s. The app waits until no process of the group is left, because two test runs on one iPhone conflict. A quit waits at most 10 s.

**Crash safety.** The app writes the pid of each test run to `~/Library/Application Support/glasstap/wda-<UDID>.pid`, and deletes the file when the run ends. If the app crashes, the next start reads the file. It stops that process group only if the pid still runs `xcodebuild test-without-building` for this iPhone, because the system can give the pid to another process.

**Failures.** Each kind of failure has its own result:

- A signing failure at start, such as a free account's profile that expired after 7 days: the app builds again once. If the start fails again, WDA stops in the failed state, and the menu tells the user to open Xcode and sign in.
- A build failure because the iPhone was locked, busy or still "Preparing": the app tries again after the next wait. This happens often just after the iPhone is plugged in.
- A compile or signing error in the build, or a download with the wrong SHA-256: WDA stops in the failed state. **Restart WDA**, **Check Again** in the Setup window, a new setting or another iPhone starts it again.
- A start that gives no `ServerURLHere` within 3 minutes, a test run that ends, or a failed devicectl lookup: the app tries again after the next wait.

The menu shows the state of WDA: downloading, building, starting, running, restarting with the wait, or failed with the reason.

**Device identity.** The app gets the UDID by a match of the capture device's name in `devicectl list devices`. It uses only physical devices with a connected or connectable tunnel, and the name must match exactly. One failed lookup does not stop a WDA that runs, because a lookup can fail for a short time. The app stops WDA when the capture device goes, or when a failure has lasted 15 s.

The app looks the iPhone up again after an event: a device change, **Check Again**, or the app coming to the front. Requests within 300 ms give one lookup. While the iPhone is not paired or devicectl fails, the app also looks again after 5, 10, 30 and then every 60 s. Developer Mode off and a duplicate name wait for an event, because only the user can fix them.

**The user's own WDA.** If the settings hold a WDA URL override, the manager starts nothing. It checks `GET /status` on that URL every 5 s and shows the same states: running, or restarting after three failed checks.

**Wake check.** An iPhone with its display off sends no frames. The check waits until WDA runs, then 4 s more. If no frame came, it presses Home when SpringBoard is in front. In an app, the menu asks the user to wake the iPhone until a frame comes.

## Setup window

The Setup window lists what the app needs: Xcode, the team id, the iPhone, camera access and WDA. Each row shows a state and one way to fix it.

- **Xcode:** `xcode-select -p` must point into an Xcode app, and that folder must hold `usr/bin/devicectl`. The Command Line Tools alone have no devicectl.
- **Team id:** the hint names Xcode > Settings > Accounts, and the OU field of the Apple Development certificate. `security find-identity` is not used in the hint, because it shows a member id for an Apple Development certificate, not the team id.
- **iPhone:** found on USB, paired and trusted, with Developer Mode on.
- **WDA:** the state, and the last output lines after a failure.

The window opens at the first launch, when a check starts to fail, and from **Setup…** in the menu. An iPhone problem must last 15 s first, because a newly plugged iPhone looks unpaired until its tunnel is up. The window is an AppKit `NSWindow` with SwiftUI content, because the app must open it without a click. A SwiftUI `Window` scene opens only from a view, and the menu builds its views only when the user opens it.

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
