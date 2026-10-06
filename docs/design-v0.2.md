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

- The app matches a capture device to an iPhone by name, because spike S3 found no other link. If two connected iPhones share a name, the menu asks the user to rename one. Only those iPhones get the problem. The others keep their WDA. This is also true when two capture devices share a name but devicectl shows only one of them, because the name cannot tell the two apart.
- Each iPhone gets its own session: its capture, encoder, viewer slot, identity lookup, wake check and WDA manager. The app makes the session when the capture device appears, and stops it when the device goes. So each capture runs only while its iPhone is there. WDA starts only when devicectl has named the iPhone and a team is set.
- The key of a session is the UDID. Until devicectl names the iPhone, the key is the capture id. The paths accept both forms, so a page that learned the capture id keeps working after the UDID is known.
- Each iPhone has one viewer. A new viewer of an iPhone replaces only the viewer of that iPhone.
- The listeners stay on the same two ports. The paths carry the iPhone: `/devices/<id>/video` on the video port, and `/devices/<id>/tap`, `/swipe`, `/type`, `/home`, `/switcher`, `/wake`, `/stats`, `/info` and `/screenshot` on the control port.
- `GET /devices` lists the iPhones as `[{"udid", "captureID", "name", "state", "wda"}]`. It needs the token. `udid` is the key of the session, `captureID` is the capture id, `state` is the capture state, and `wda` is the WDA state.
- The paths without `/devices/<id>` still work, so that the links of v0.1 work. They act on the only iPhone. With no iPhone or with more than one, they answer 409 with a message. An unknown id gets 404. The server checks the token before the iPhone, so a request without the token learns nothing about the iPhones.
- The viewer link can name an iPhone (`#token=…&device=<UDID>`). Without it, the page asks `GET /devices`. With one iPhone, the page uses it. With more, the page shows a picker and waits for a choice. The page keeps the choice in its link, so a reload stays on that iPhone. The status bar shows the name of the iPhone.
- The page reads `GET /devices` when it opens. After that, it reads the list only while no iPhone is chosen or while the picker shows. The wait between reads grows to 10 s while the list stays the same, and an unchanged list does not draw the picker again. With one chosen iPhone, the stream tells the page instead: the page reads the list when the stream ends, gets 404 or gets 409. So a page that shows one iPhone does not see a second iPhone until it reloads. The page finds its iPhone by the UDID or by the capture id. When the app learns the UDID, the page uses the UDID from then on, with no new connection. If the chosen iPhone is gone and one other iPhone is connected, the page changes to that iPhone. With more, it shows the picker. With none, it says "No iPhone is connected". Each change updates the link of the page.
- The menu has one section for each iPhone, with **Open Viewer** for that iPhone and **Restart WDA**. **Copy Viewer Link** copies the link without an iPhone. The Setup window shows one row for each iPhone.
- The WDA URL override names one WDA, so the app uses it only while one iPhone is connected. With more, a tap could go to the wrong iPhone.
- Two iPhones on the same iOS major version share one WDA build folder. Their builds run one after the other, because two builds in one folder conflict. The second build uses the result of the first, if there is one. A build that waits and is cancelled, for example because its iPhone was unplugged, stops waiting at once.
- A clean build after a signing failure also waits for the build that runs. If no test run uses the folder, the app deletes it. If the test run of another iPhone uses it, the clean build goes into a new folder, and the old folder goes when its last test run ends.
- All sessions share one `devicectl list devices` call when they look at the same time.
- If an iPhone comes back before its old test run has stopped, the new start stops the old run first, through the pid file.
- When a session stops, its viewer hub closes. A viewer that joins after that gets 409 with a message at once. It does not wait for a stream that never starts.

## Adaptive bitrate

The viewer reports what it has received, and the host compares that with what it has sent. The host cannot see congestion by itself. Network.framework reports a send as done when the data enters its own buffer, which holds about 0.5 MB on loopback. Behind an SSH tunnel, sshd also reads into a channel window of about 2 MB. A slow link therefore stays hidden from the host until these buffers are full, which can take 20 s or more of delay.

**The stream.** The stream gains one optional message, type 4 (stats JSON with the current bitrate and frame rate). A viewer asks for it with `stats=1` in the video URL. Older pages do not ask, so they get the same stream as before. The config message (type 0) also names a `session`: a random id for this stream. See the stream format in the [v0.1 design](design-v0.1.md#stream-format).

**The reports.** Every 250 ms, the viewer sends `POST /stats` to the control port with `{"session": …, "received": …}`. `received` is the number of bytes of the stream body that the viewer has received. If `received` did not change, the page skips the report, but it sends one at least every 900 ms. The request needs the token in the `X-Glasstap` header, with the same checks as the other actions. A report with another session gets 404 and changes nothing. The control port keeps a connection open between requests, so that a report does not open a new connection each time. Through `ssh -L`, a new connection costs a new SSH channel and a round trip.

**In flight and the queue.** The host counts the bytes that it hands to the connection after the HTTP header. "In flight" is the bytes sent less the bytes received, at the time of the report. Part of it is the path itself: about two round trips of stream, because a report is one round trip old when it arrives. The host takes the lowest amount in flight of the last 10 s as the baseline of the path. The baseline can rise again after 10 s, for example when the viewer moves to another network. Only the amount above the baseline is the queue.

**Room for a key frame.** A key frame goes out at once and is many times the size of a delta frame. At 75 kbit/s, one key frame is more than 1 s of the bitrate. So each threshold below adds the largest key frame of the last 10 s ("K"). "1 s" means the bytes of 1 s at the current target bitrate.

The host measures every 250 ms while a viewer is connected. It stops when no frame went out since the last measurement and the bitrate and size are at the settings, because then it has nothing to measure or to raise.

The rules:

- **Congested:** the queue is more than K + 1 s (at least 64 KB). Or the amount in flight grew in the last 1 s by more than 0.15 s (at least 16 KB), and the queue is more than K + 0.5 s (at least 32 KB). The host then multiplies the bitrate by 0.7.
- **Draining:** if the amount in flight fell in the last 1 s, the host does not cut, because the queue drains by itself. Another cut would go below what the link carries.
- **Clear:** the queue is less than K + 0.25 s (at least 16 KB). If the link is clear for 2 s, the host raises the bitrate by 10%, up to the bitrate in the settings. Between clear and congested, the bitrate stays.
- **No feedback:** if the last report is older than 1 s, or the viewer never reports (a page from before v0.2), the host uses its own signal. If more than 5 messages wait, or a send takes more than 300 ms, the link is congested. Otherwise it is clear.
- After a decrease, the host waits 1 s before the next one, so that one burst does not cut the bitrate several times.
- Each size of the stream has a lowest bitrate (a floor). At the floor, the host makes the picture smaller instead, and cuts the bitrate by 0.7 again, down to the next floor. The frame rate stays at the settings.
- When the link is clear and the bitrate has reached the floor of the larger size, the host makes the picture larger again. Before that, it raises the bitrate.
- With no viewer, when a new viewer joins, and when the capture stops, the bitrate and the frame rate go back to the settings. A new viewer may have another link.

**The size ladder.** Under a floor, VideoToolbox does not lower the stream: it drops most frames. The host measured this with the real encoder, on a page of text that scrolls at 30 fps, for 8 s:

| Width | 300 kbit/s | 250 | 200 | 150 | 125 | 100 | 75 |
|---|---|---|---|---|---|---|---|
| 590 px | 183 of 240 frames | 206 | 12 | 8 |  | 8 | 8 |
| 392 px | 240 |  |  | 240 | 101 | 20 | 11 |
| 294 px | 240 |  |  | 240 |  | 114 | 20 |
| 294 px, a key frame every 4 s |  |  |  | 240 |  | 240 | 136 |

The ladder keeps at least about half of the frames at each floor:

| Size | Width at 590 px in the settings | Floor | Key frame |
|---|---|---|---|
| Full | 590 px | 250 kbit/s | every 2 s |
| About 2/3 | 392 px | 150 kbit/s | every 2 s |
| About 1/2 | 294 px | 75 kbit/s | every 4 s |

For another width in the settings, the floors change with the area of the picture. All sizes are even, and the height keeps the aspect ratio of the screen.

**A size change.** The capture queue makes a new encoder session for the new size, with no restart of the capture. The capture output scales its frames to the new size, and frames of the old size that are still on the way are scaled on the Mac. The first frame of the new session is a key frame with a new config message, so the viewer makes a new decoder.

**The encoder.** The host changes only `AverageBitRate` on a running session. `ExpectedFrameRate` stays at the settings. A lower value makes VideoToolbox spend more bits on each frame, and the stream then grows: 245 kbit/s at 5 fps against 185 kbit/s at 30 fps, for a target of 150 kbit/s. `DataRateLimits` is not available on this encoder.

**A dropped key frame.** At a low bitrate, the encoder can drop a key frame that a viewer waits for. The host then tries again after 250 ms, 500 ms, 1 s, and then every 2 s, until a key frame comes out. It logs the first drop only. Without the wait, it would try again at once and drop the frame again, at the frame rate.

VideoToolbox accepts a new `AverageBitRate` on a running session, so a change needs no new key frame. The menu and the viewer status bar show the current bitrate. The viewer status bar takes it from the stats messages.

## Listen address

- The settings offer **This Mac only** (127.0.0.1, the default) and a list of the Mac's other addresses. The app reads the addresses with `getifaddrs`, from the interfaces that are up. It skips loopback and link-local addresses, because 127.0.0.1 is the first choice and a link-local address needs a scope. It marks an address in 100.64.0.0/10 or fd7a:115c:a1e0::/48 as Tailscale. Each row shows the interface name.
- Any address other than 127.0.0.1 needs a confirmation when the user clicks **Apply**, because the traffic then leaves the Mac without encryption, unless it goes through Tailscale. Anyone on that network who gets the link can see and control the iPhone.
- Both listeners bind to the chosen address only. The app never binds to the unspecified address (0.0.0.0 or ::), and the settings refuse it.
- A move to an address starts both listeners and waits until both are ready. Only then do the menu and the link file show the new address. If a listener fails or waits, the app tries again after 1, 2 and 4 s. A new IPv6 address cannot be bound for a moment after its interface comes up, and the retries cover that. If the address still fails, the listeners go to 127.0.0.1, and the menu says why. The app tries the address again when the addresses of the Mac or the settings change.
- Each move gets a new token: a new address or port in the settings, a fallback to 127.0.0.1, and the move back. The link file is written again, and the open viewers close. So a link to an address that the app left is of no use, also if another local user binds that address and port later.
- The token rules stay the same. The Host check accepts 127.0.0.1, `localhost` and the chosen address, with or without a port. An IPv6 address must be in brackets, and any spelling of the same address passes. The video listener accepts the viewer origins of the same three hosts. In loopback mode, the checks are the same as before.
- The viewer link and the link file use the chosen address.
- The app reads the addresses when the network changes (`NWPathMonitor`), when the app comes to the front, and every 30 s in case a change has no network event. If the chosen address goes, for example when its interface is down, the listeners move to 127.0.0.1, and the menu says so. When the address comes back, the listeners move back. Each move closes the open viewers.
- The list does not offer a `utun` interface, unless its address is a Tailscale address. The CoreDevice tunnel of each iPhone is a `utun` interface with an fd… address. That address changes at each plug-in, and a connection from the Mac itself to it did not answer. Other VPNs that use `utun` are not offered either.

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
- **Listen address:** on an address other than 127.0.0.1, the token and the stream go over the network. Only Tailscale encrypts them. On another network, anyone who reads the traffic can take the token, and then see and control the iPhone. The confirmation and the README say this. The Host check still blocks DNS rebinding, because it accepts only the chosen address and the loopback names.

## Testing

- **Unit tests:** parsing of `devicectl` JSON and of the `ServerURLHere` line, the restart backoff, name matching with duplicate names, the bitrate controller, the address checks, the session registry, the routes with and without `/devices/<id>`, the classes of listen addresses, and the fallback to 127.0.0.1.
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
