# glasstap v0.1: design

This document turns milestone v0.1 of [`PLAN.md`](../PLAN.md) into a design. v0.1 packages what the prototype already does into one macOS menu-bar app on the host Mac.

**v0.1 is done when** a developer builds the app from Xcode on the host Mac, starts WDA from the docs, and sees and taps the iPhone in a browser on the same Mac. The notarized DMG comes in v0.3.

## Scope

In v0.1:

- One app, `glasstap.app`, in the menu bar of the host Mac. It replaces `iPhoneCapture.app`, `phone_remote.py` and the capture half of `phone-remote`.
- One iPhone at a time. If the Mac finds more than one screen device, the menu lets you pick one by name.
- One viewer at a time. The newest viewer takes the stream.
- H.265 or H.264, chosen in the menu.

Not in v0.1:

- Starting or building WDA. The user starts WDA with the two commands in the README. The v0.2 WDA manager takes this over (spikes S1 and S2).
- The JPEG mode, a relay, accounts, and more than one iPhone at a time (spike S3).

## Architecture

```text
 ┌──────────────────────────── glasstap.app (host Mac) ─────────────────────────────┐
 │  MenuBar UI ── device, WDA state, viewer state, fps, settings, "Open viewer"     │
 │                                                                                  │
 │  DeviceWatcher ── CoreMediaIO screen devices ──► CaptureEngine ──► Encoder       │
 │                                                    (last frame)   (VideoToolbox) │
 │                                                                       │          │
 │  WDAClient ◄── ControlServer :9300 ◄── page, actions        VideoServer :9301    │
 │     │              (token, Host, Origin checks)          (token, Origin checks)  │
 └─────┼──────────────────────┬──────────────────────────────────────┬─────────────┘
       ▼                      │ connection 1: page and actions       │ connection 2: video
  WDA on 127.0.0.1:8100       └────────────── browser (WebCodecs) ───┘
  (started by the user)
```

### Two listeners

The app listens on two ports: 9300 for the page and the actions, 9301 for video. You can change both in the settings.

The prototype measured why. When video and control share one SSH connection, a tap took about 15 s. On separate connections, a tap took about 0.3 s. One port would put both through one `ssh -L` for a remote viewer. So the README gives this remote recipe:

```bash
ssh -N -L 9300:127.0.0.1:9300 host-mac &
ssh -N -L 9301:127.0.0.1:9301 host-mac &
```

With Tailscale or on a LAN, no tunnel is needed, but the app still listens only on 127.0.0.1 in v0.1. Binding to another address waits for v0.2.

The ports keep the same numbers on both sides of the tunnel, so the copied viewer link works unchanged.

### Security

These rules come from four security reviews of the prototype:

1. Both listeners bind to 127.0.0.1 only.
2. The app makes a random token at each launch. The viewer link carries it in the URL fragment (`#token=…`), which no server receives.
3. The page itself holds no secret and loads without the token. Every action, screenshot and video request needs the token: actions in the `X-Glasstap` header, video in the `token` query parameter.
4. Both listeners reject a Host other than `127.0.0.1` or `localhost` (DNS rebinding).
5. The control listener rejects a POST with a foreign `Origin`. The video listener allows only the viewer's origin in CORS. It also refuses requests that the browser marks `Sec-Fetch-Site: cross-site`.
6. The browser never reaches WDA. The app is the only WDA client, and it offers only a fixed set of actions: tap, swipe, type, Home, app switcher, wake and screenshot.
7. The app opens the viewer with `NSWorkspace.open(_:)`, so the token never appears in a command line. "Copy viewer link" puts the link on the clipboard.
8. The app also keeps the link in a private file, `~/Library/Application Support/glasstap/viewer-link`. The folder has mode 700 and the file has mode 600, so other local users cannot read the token. A viewer on another Mac reads the link from this file over SSH, because "Copy viewer link" works only at the host's screen. The app writes the file again when the viewer port changes, and deletes it at quit.

v0.1 accepts one known risk: WDA's forwarder answers on the host's `127.0.0.1:8100`, so any local user on the host can control the iPhone. v0.2 replaces the forwarder with a private Unix socket.

### Capture and encoding

The engine keeps the behaviour that the prototype discovered. See [`prototype/iphone_capture.swift`](../prototype/iphone_capture.swift).

- The process sets `kCMIOHardwarePropertyAllowScreenCaptureDevices`, and the screen device can take about 6 s to appear.
- The capture sends frames only while the screen changes. The engine keeps the last frame. When a viewer joins or waits for a key frame, the engine encodes that frame again as a key frame.
- All presentation times come from the host clock, because old frames are encoded again.
- The capture output scales the frames, and VideoToolbox encodes them in real time with no frame reordering. The defaults are 590 px wide, 800 kbit/s, 30 fps and a key frame every 2 s.
- When a viewer falls more than 15 frames behind, it skips to the next key frame.
- **Display off:** an iPhone with its display off sends no frames at all. If no frame comes within 4 s and SpringBoard is in front, the app presses Home through WDA. In an app, the menu shows "Wake the iPhone".

### Stream format

The video listener keeps the prototype's format: a 4-byte big-endian length, a type byte and a payload. The types are 0 (config JSON), 1 (key frame), 2 (delta frame) and 3 (another viewer took the stream). The frames are Annex B with the parameter sets in front of each key frame. The page decodes them with WebCodecs, as in [`prototype/phone_remote.html`](../prototype/phone_remote.html).

## Permissions and signing

- `Info.plist` has `NSCameraUsageDescription` and `LSUIElement`. macOS asks for camera access at the first capture, because it treats the iPhone screen as a camera.
- **Development builds:** Xcode signs automatically with an Apple Development certificate. The designated requirement then stays the same, so the camera approval stays valid after a rebuild. A contributor without that certificate must approve again after each build.
- **Release builds (v0.3):** a Developer ID signature, notarization, and the hardened runtime with the `com.apple.security.device.camera` entitlement.

## Project layout

```text
project.yml            XcodeGen spec. The .xcodeproj is generated and not committed.
App/                   glasstap.app: menu bar UI, app lifecycle, settings
GlasstapKit/           Swift package: the testable core
  Sources/GlasstapKit/   capture, encoder, servers, WDA client, auth, stream format
  Tests/GlasstapKitTests/
Viewer/                the viewer page, copied into the app's resources
prototype/             kept for reference until v0.2
```

- `make project` runs XcodeGen. `make test` runs `swift test` in `GlasstapKit`.
- **Swift 6 language mode** with strict concurrency. The shared state of the frame path (the viewer registry, the last frame and the key-frame request) sits behind `OSAllocatedUnfairLock`, not in an actor. An actor would add a hop to every frame on the hot path. The UI state is `@MainActor`.
- The minimum is macOS 14.
- The HTTP servers use `Network.framework`, with no third-party packages.

## Settings

The menu holds these settings in `UserDefaults`. A change restarts the encoder:

| Setting | Default |
|---|---|
| Codec | H.265 (H.264 as an option) |
| Width | 590 px |
| Bitrate | 800 kbit/s |
| Frame rate | 30 fps |
| Ports | 9300 and 9301 |
| WDA URL | `http://127.0.0.1:8100` |

## Testing

Unit tests in `GlasstapKit` cover the pure parts:

- HTTP request parsing, and the token, Host and Origin checks.
- The conversion from length-prefixed NAL units to Annex B, and the message framing.
- The viewer state: the newest viewer replaces the old one, and a slow viewer skips to the next key frame.

A manual check on the device repeats the prototype's measured baseline:

1. The stream shows about 30 fps at 590 × 1278 while the screen moves.
2. A tap returns 200 with the token and 403 without it.
3. A viewer that joins on a still screen gets a picture at once.
4. With the display off and the lock screen in front, the app wakes the iPhone.
5. A second viewer takes the stream, and the first one shows "Take it back".

Spike S4 (the delay from the iPhone to the viewer) stays open. This document does not state a number for it.

## What happens to the prototype

| Prototype file | v0.1 |
|---|---|
| `iphone_capture.swift` | Becomes `CaptureEngine`, `Encoder` and `VideoServer` in `GlasstapKit` |
| `phone_remote.py` | Becomes `ControlServer` and `WDAClient` |
| `phone_remote.html` | Becomes `Viewer/index.html`, with the video URL on port 9301 |
| `phone-remote` | The capture and build half goes. The WDA commands and the tunnel recipe move to the README. |
| `phone_frame_relay.py` | Not in v0.1. It stays in `prototype/` as a reference. |

## Open questions

- Does the capture work while the iPhone is locked, on Intel Macs, or while QuickTime Player captures the same iPhone?
- Can the two listeners become one later, for example over WebRTC on a direct UDP path?
- How does the app find the WDA port of the right iPhone when more than one is on USB? This is spike S3.
