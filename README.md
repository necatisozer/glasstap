# glasstap

glasstap shows a physical iPhone live in a browser and lets you tap, swipe and type on it. The iPhone connects over USB to a Mac. The browser can be on another computer, also on a slow link and behind NAT.

glasstap gets the screen from the USB screen-capture device of macOS (the QuickTime route) and encodes it with the hardware H.265 encoder. On a 1.6 Mbit/s uplink, the prototype shows about 30 fps at 590 × 1278. WebDriverAgent (WDA) sends the taps, swipes and text.

> **Status: prototype.** The code in [`prototype/`](prototype/) works for one setup. It is not a product yet. [`PLAN.md`](PLAN.md) describes the path to a macOS menu-bar app.

## How it works

```text
 iPhone ──USB── host Mac ──────────────────────────── SSH ──── your Mac
                 iPhoneCapture.app                              phone-remote
                   CoreMediaIO capture                            browser page (WebCodecs)
                   VideoToolbox H.265 ──── video stream ───────►  canvas
                 WebDriverAgent (WDA) ◄─── taps, swipes, text ──  control server
```

The video and the control commands use separate SSH connections, so that a tap never waits behind video frames.

## Requirements

On the host Mac (the Mac with the iPhone on USB):

- macOS 14 or later, with Xcode. Only macOS 26 on Apple silicon is tested.
- An Apple Development certificate in the login keychain. glasstap signs the capture app with it, so that the camera approval stays valid after a rebuild.
- [WebDriverAgent](https://github.com/appium/WebDriverAgent), built, signed with your own Apple account, and installed on the iPhone.
- [`pymobiledevice3`](https://github.com/doronz88/pymobiledevice3), to start WDA and forward its port. Version 0.2 will remove this dependency.
- Python 3 with Pillow, for the JPEG mode only.

On your Mac (the viewer):

- SSH access to the host Mac, for example through Tailscale, Cloudflare Tunnel or a LAN.
- A browser with WebCodecs and H.265 decoding, for example Chrome or Safari on macOS.

On the iPhone:

- Developer Mode on, and the host Mac trusted.

## Use the prototype

1. Copy or link the files in `prototype/` into a folder on your `PATH`, for example `~/bin`.
2. If your SSH host is not called `mac-mini`, give its name as the first argument.
3. If your WDA runner has another bundle id, set `PHONE_REMOTE_RUNNER`.
4. Run `phone-remote`.
5. On the first run, click **Allow** for "iPhone Capture" on the host Mac's screen. macOS asks for camera access, because it treats the iPhone screen as a camera.

```bash
phone-remote my-host
```

The script starts WDA, the capture app and the tunnels, and then opens the page in your browser. Press Ctrl-C to stop everything that it started.

To open the page again while it runs, open `~/.glasstap/open.html`. The file holds the access token of the current run.

Useful settings:

| Variable | Default | Meaning |
|---|---|---|
| `PHONE_REMOTE_CODEC` | `hevc` | `hevc` (H.265) or `h264` |
| `PHONE_REMOTE_VIDEO_WIDTH` | `590` | Video width in pixels. The iPhone 15 screen is 1180 wide. |
| `PHONE_REMOTE_BITRATE` | `800000` | Video bitrate in bit/s |
| `PHONE_REMOTE_MODE` | `video` | `jpeg` uses WDA screenshots, about 9 fps, as a fallback |

## Things to know

- **The clock shows 9:41 while the capture runs.** iOS shows a clean status bar during screen capture. The phone's real clock does not change.
- **One viewer at a time.** If you open a second page, it takes the stream, and the first page shows "Take it back".
- **The capture sends frames only while the screen changes.** A still screen uses almost no bandwidth.
- **If the iPhone display is off, there is no picture.** `phone-remote` presses Home when the lock screen is in front. In an app, wake the phone yourself.

## Security

- Every server listens only on 127.0.0.1 and requires a random token for each run.
- The tunnel to WDA ends in a Unix socket in `~/.glasstap`, which only you can open. WDA itself has no authentication.
- **Known risks:** WDA on the iPhone also answers on the iPhone's Wi-Fi address, and its forwarder answers on the host Mac's `127.0.0.1:8100`. Anyone on that network, or any local user on the host Mac, can control the iPhone. Use the iPhone only on a network that you trust. [`PLAN.md`](PLAN.md#risks) lists the planned fixes.

## Licence

[MIT](LICENSE)
