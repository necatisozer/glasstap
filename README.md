# glasstap

glasstap shows a physical iPhone live in a browser and lets you tap, swipe and type on it. The iPhone connects over USB to a Mac. The browser can be on another computer, also on a slow link and behind NAT.

glasstap gets the screen from the USB screen-capture device of macOS (the QuickTime route) and encodes it with the hardware H.265 encoder. On a 1.6 Mbit/s uplink, the prototype shows about 30 fps at 590 × 1278. WebDriverAgent (WDA) sends the taps, swipes and text.

> **Status: v0.1, early.** glasstap is a menu-bar app that you build from source. You start WebDriverAgent yourself. [`PLAN.md`](PLAN.md) describes the path to a signed release, and [`docs/design-v0.1.md`](docs/design-v0.1.md) describes this version.

## How it works

```text
 iPhone ──USB── host Mac: glasstap.app (menu bar) ─────────────── browser
                  CoreMediaIO capture
                  VideoToolbox H.265 ──── video, port 9301 ─────►  canvas (WebCodecs)
                  WDA client ◄─────────── actions, port 9300 ────  taps, swipes, text
                     │
                  WebDriverAgent on the iPhone
```

The app listens on two ports, so that a tap never waits behind video frames.

## Requirements

On the host Mac (the Mac with the iPhone on USB):

- macOS 14 or later, Xcode, and [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`). Only macOS 26 on Apple silicon is tested.
- An Apple Development certificate. With it, the camera approval stays valid after a rebuild.
- [WebDriverAgent](https://github.com/appium/WebDriverAgent), built, signed with your own Apple account, and installed on the iPhone.
- [`pymobiledevice3`](https://github.com/doronz88/pymobiledevice3), to start WDA and forward its port. Version 0.2 will remove this dependency.

On the iPhone: Developer Mode on, and the host Mac trusted.

In the browser: WebCodecs with H.265 decoding, for example Chrome or Safari on macOS. If your browser has no H.265, choose H.264 in the settings.

## Build and run

1. Copy `Config/Local.xcconfig.example` to `Config/Local.xcconfig`, and set your team id in it.
2. Build the app:

   ```bash
   make build
   ```

3. Start WDA on the iPhone, and forward its port to the host Mac. Keep both commands running:

   ```bash
   pymobiledevice3 developer dvt xcuitest <your WDA runner bundle id>
   ```

   ```bash
   pymobiledevice3 usbmux forward 8100 8100
   ```

4. Start the app:

   ```bash
   make run
   ```

5. On the first capture, click **Allow** for "glasstap". macOS asks for camera access, because it treats the iPhone screen as a camera.
6. In the menu bar, click the glasstap icon, and then click **Open Viewer**.

The menu shows the iPhone, the frame rate, the viewer, and whether WDA answers. **Settings** has the codec, size, bitrate, frame rate, ports and the WDA address.

## View from another Mac

The app listens only on 127.0.0.1. To view from another Mac, forward both ports over SSH. Use two separate SSH connections. On one shared connection, taps wait behind the video:

```bash
ssh -N -L 9300:127.0.0.1:9300 host-mac &
```

```bash
ssh -N -L 9301:127.0.0.1:9301 host-mac &
```

Then read the viewer link and open it in your browser:

```bash
ssh host-mac 'cat "$HOME/Library/Application Support/glasstap/viewer-link"'
```

The link holds the access token of the current app launch. Only your user can read the file, and the app deletes it when it quits.

## The prototype

[`prototype/`](prototype/) keeps the scripts that came before the app, as a reference. `phone-remote` starts WDA, a capture app and the tunnels for one fixed setup. See the comments in each file.

## Things to know

- **The clock shows 9:41 while the capture runs.** iOS shows a clean status bar during screen capture. The phone's real clock does not change.
- **One viewer at a time.** If you open a second page, it takes the stream, and the first page shows "Take it back".
- **The capture sends frames only while the screen changes.** A still screen uses almost no bandwidth.
- **If the iPhone display is off, there is no picture.** The app presses Home when the lock screen is in front. If an app is in front, the menu shows "Wake the iPhone", and you wake it yourself.

## Security

- Both ports listen only on 127.0.0.1. Every request needs the token of the current launch, except the viewer page, which holds no secret.
- The browser never talks to WDA. The app is the only WDA client and offers only taps, swipes, text, Home, the app switcher, wake and screenshots.
- **Known risks:** WDA on the iPhone also answers on the iPhone's Wi-Fi address, and its forwarder answers on the host Mac's `127.0.0.1:8100`. Anyone on that network, or any local user on the host Mac, can control the iPhone. Use the iPhone only on a network that you trust. [`PLAN.md`](PLAN.md#risks) lists the planned fixes.

## Licence

[MIT](LICENSE)
