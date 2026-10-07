# glasstap

glasstap shows a physical iPhone live in a browser and lets you tap, swipe and type on it. The iPhone connects over USB to a Mac. The browser can be on another computer, also on a slow link and behind NAT.

glasstap gets the screen from the USB screen-capture device of macOS (the QuickTime route) and encodes it with the hardware H.265 encoder. On a 1.6 Mbit/s uplink, the prototype shows about 30 fps at 590 × 1278. WebDriverAgent (WDA) sends the taps, swipes and text.

> **Status: v0.2.0, early.** glasstap is a menu-bar app that you build from source. It builds, starts and watches WebDriverAgent itself. [`CHANGELOG.md`](CHANGELOG.md) lists what changed and what is not tested yet. [`PLAN.md`](PLAN.md) describes the path to a signed release, and [`docs/design-v0.2.md`](docs/design-v0.2.md) describes this version.

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

- macOS 14 or later. Only macOS 26 on Apple silicon is tested.
- **Xcode is required (devicectl and xcodebuild).** The Command Line Tools alone are not enough.
- An Apple account in Xcode > Settings > Accounts. A free account works, but its WebDriverAgent profile is valid for 7 days. glasstap then builds WebDriverAgent again by itself.
- [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`), to build glasstap from source.
- An Apple Development certificate. With it, the camera approval stays valid after a rebuild of glasstap.

On the iPhone: Developer Mode on, and the host Mac trusted.

In the browser: WebCodecs with H.265 decoding, for example Chrome or Safari on macOS. If your browser has no H.265, choose H.264 in the settings.

## Install

1. Install Xcode, and open it once. In Xcode > Settings > Accounts, sign in with your Apple account. If Manage Certificates shows no Apple Development certificate, add one.
2. Install XcodeGen:

   ```bash
   brew install xcodegen
   ```

3. Get the source, and install glasstap:

   ```bash
   git clone https://github.com/necatisozer/glasstap.git
   ```

   ```bash
   cd glasstap && make install
   ```

   `make install` finds the team of your Apple Development certificate, and writes it to `Config/Local.xcconfig`. It then builds glasstap, copies it to `~/Applications`, and opens it. glasstap uses the same team for WebDriverAgent. If you have more than one team, `make install` lists them. Then run `make install TEAM=<team id>`.
4. Plug in the iPhone with a USB cable, unlock it, and tap **Trust**.
5. On the iPhone, turn on Developer Mode in Settings > Privacy & Security > Developer Mode, and restart the iPhone if it asks.
6. On the first capture, click **Allow** for "glasstap". macOS asks for camera access, because it treats the iPhone screen as a camera.
7. In the menu bar, click the glasstap icon, and then click **Open Viewer**.

To update glasstap, run `git pull` and `make install` again. For development, use `make build` and `make run`. They use the team in `Config/Local.xcconfig`.

At the first start, glasstap downloads WebDriverAgent (WDA) 16.12.10 from GitHub and checks its SHA-256. It then builds WDA with your team, and starts it on the iPhone. The first build takes a few minutes. The menu shows each step. If WDA stops answering, or the iPhone is unplugged and plugged in again, glasstap starts WDA again.

The Setup window lists what glasstap needs and what is missing. It opens at the first launch and when a check fails. **Setup…** in the menu opens it. **Settings** has the codec, size, bitrate, frame rate, the listen address, ports, the team id, the WDA bundle id prefix and a WDA URL override for a WDA that you run yourself.

glasstap keeps the WDA source and its builds in `~/Library/Application Support/glasstap/`.

## More than one iPhone

Plug in each iPhone. glasstap captures each one, and starts a WebDriverAgent for each one. The menu shows one section for each iPhone. **Open Viewer** in a section opens the page of that iPhone.

The link of **Copy Viewer Link** and of the link file names no iPhone. With one iPhone, the page uses it. With more, the page shows a picker. To open one iPhone directly, add `&device=<UDID>` to the link.

Each iPhone must have its own name. If two iPhones have the same name, glasstap cannot tell them apart, and the menu asks you to rename one in Settings > General > About.

`GET /devices` on the viewer port lists the iPhones. It needs the token in the `X-Glasstap` header. The actions are at `/devices/<UDID>/tap` and so on, and the video is at `/devices/<UDID>/video` on the video port. The paths without `/devices/<UDID>` work while only one iPhone is connected.

The WDA URL override in the settings is for one iPhone. While more than one iPhone is connected, glasstap does not use it.

## View from another Mac

By default, the app listens only on 127.0.0.1. There are two ways to view from another computer: an SSH tunnel, or another listen address.

### SSH tunnel

Forward both ports over SSH. Use two separate SSH connections. On one shared connection, taps wait behind the video:

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

### Another listen address

In **Settings > Network > Listen on**, choose an address of the host Mac instead of **This Mac only (127.0.0.1)**. The list marks a Tailscale address. Then click **Apply**, read the warning, and confirm. Both ports then listen on that address only, never on all addresses. The viewer link and the link file use that address.

**Use the Tailscale address.** Tailscale encrypts the traffic, and only the devices in your tailnet can reach the address.

> **Warning:** On any other address, glasstap does not encrypt the traffic. Anyone on that network who gets the viewer link can see and control the iPhone. Use such an address only on a network that you trust.

Open the link with the address itself, for example `http://100.101.102.103:9300/#token=…`. The app accepts only 127.0.0.1, `localhost` and the chosen address as the host, so a host name such as a MagicDNS name does not work.

If the address goes away, for example when Tailscale or Wi-Fi is off, the app listens on 127.0.0.1 again, and the menu tells you. When the address comes back, the app listens on it again. If the app cannot listen on the address, it tries again a few times, and then listens on 127.0.0.1 and tells you why. Each change closes the open viewers and makes a new viewer link.

## The prototype

[`prototype/`](prototype/) keeps the scripts that came before the app, as a reference. `phone-remote` starts WDA with `pymobiledevice3`, a capture app and the tunnels for one fixed setup. The app does not use `pymobiledevice3`. See the comments in each file.

## Things to know

- **The clock shows 9:41 while the capture runs.** iOS shows a clean status bar during screen capture. The phone's real clock does not change.
- **One viewer for each iPhone.** If you open a second page for the same iPhone, it takes the stream, and the first page shows "Take it back".
- **The capture sends frames only while the screen changes.** A still screen uses almost no bandwidth.
- **If the iPhone display is off, there is no picture.** The app presses Home when the lock screen is in front. If an app is in front, the menu shows "Wake the iPhone", and you wake it yourself.
- **The viewer shows when the iPhone is locked.** A banner at the top says "The iPhone is locked", with a **Wake screen** button. A passcode, if set, stays for you to enter. If the iPhone was locked when WDA started, the banner asks you to unlock it on the iPhone itself.
- **For long sessions, set Auto-Lock to Never** on the iPhone, in Settings > Display & Brightness > Auto-Lock. Otherwise the iPhone locks itself after a few minutes without a touch.

## Security

- By default, both ports listen only on 127.0.0.1. If you choose another listen address, they listen on that one address only. Every request needs the token of the current launch, except the viewer page, which holds no secret.
- The token goes over the network unencrypted, unless the network is Tailscale or an SSH tunnel. On another network, anyone who can read the traffic can take the token.
- Each change of the listen address or of a port makes a new token, also a fallback to 127.0.0.1 and the move back. The app writes the link file again and closes the open viewers. So an old link is of no use, also if another local user binds the old address and port later. After a change, copy the link again or read the link file again.
- The browser never talks to WDA. The app is the only WDA client and offers only taps, swipes, text, Home, the app switcher, wake and screenshots.
- The app talks to WDA on the iPhone's CoreDevice tunnel address. No forwarder listens on the host Mac's `127.0.0.1:8100`.
- **Known risks:** WDA on the iPhone also answers on the iPhone's Wi-Fi address, so anyone on that network can control the iPhone. Use the iPhone only on a network that you trust. Other local users on the host Mac may also reach the tunnel address. This is not tested yet. [`PLAN.md`](PLAN.md#risks) lists the planned fixes.

## Licence

[MIT](LICENSE)
