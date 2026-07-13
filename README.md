# Audio Router

A lightweight macOS menu-bar app that routes **individual apps' audio to different output devices** — e.g. send Apple Music to a USB DAC while notifications, browser, and system sounds stay on your speakers.

No kernel extension and no virtual audio driver to install. It uses Apple's modern **Core Audio process-tap API** (macOS 14.2+) to tap a chosen app, mute it at the source, and re-render its audio to the device you pick.

## What it does

- Per-app routing rules: **App → Output device**, each independently toggleable.
- Your macOS default output keeps playing everything *else* as normal — a route only siphons the one app you assign.
- **Activity monitor** in the menu-bar popover: shows your current **default output** (where all un-routed audio goes) plus every route, with a colored status dot and a **live level meter** that moves with the audio while a route is active.
- Menu-bar UI with live status (routing / waiting / error) per rule.
- Rules persist across launches and **auto-reconnect** when the app or device reappears.

### How routing behaves

Your macOS **default output** (Sound settings / the volume menu) keeps playing *everything* as usual. Each route you add **pulls one app's audio out** of the default output (muting it at the source) and re-injects it into the device you chose. So a single route `Apple Music → USB DAC` means:

| Audio | Comes out of |
|---|---|
| Apple Music | the USB DAC only |
| Notifications, browser, system sounds, everything else | your default output (speakers / Bluetooth) |

The app never changes your default output — it only siphons off the specific apps you route.

## Requirements

- **macOS 15 (Sequoia) or newer** (the process-tap API needs 14.2+; this project targets 15).
- **Xcode** or the **Command Line Tools** (`xcode-select --install`) to build.

## Build from source & install

This app is distributed as **source you build yourself** (it's ad-hoc signed, not notarized, so copying a prebuilt `.app` between Macs gets quarantined — building locally avoids that and makes the audio-capture permission stick).

```bash
git clone https://github.com/ekartus/audio-router.git
cd audio-router
./scripts/make_app.sh          # builds + bundles + ad-hoc signs
open "dist/Audio Router.app"   # launch it
```

To install it permanently, drag **`dist/Audio Router.app`** into `/Applications`.

The `make_app.sh` script runs `swift build -c release` and assembles a menu-bar `.app` (with `LSUIElement` so there's no dock icon), then ad-hoc signs it. No Xcode project required — just the Swift toolchain.

On first use, when you enable a route, macOS will ask for **Audio Recording / Audio Capture** permission — approve it. (Because the app is *ad-hoc signed*, macOS may ask again after each rebuild; that's expected for a locally built app.)

### Launch at login (optional)

System Settings → General → Login Items → **＋** → add **Audio Router**.

## Usage

1. Click the **waveform icon** (`⌇`) in the menu bar.
2. Pick a running **app** and an **output device**, then **Add route**.
3. Toggle the route on. The status dot turns **green** when audio is flowing.

Repeat to route several apps to several devices at once.

## How it works

```
[app] --tap (muted at source)--> capture aggregate --> ring buffer --> DAC (opened directly)
```

The tapped app is muted on the default output, its audio is captured through a Core Audio process tap, buffered, and played out to the chosen device via that device's **own direct IO path**. The ring buffer decouples the tap's clock from the output device's clock.

> **Design note:** the output device is opened *directly*, never nested inside a Core Audio aggregate. Combining a USB DAC into the tap aggregate triggered static on some USB DACs; the direct path avoids it.

## Debug CLI

A command-line tool is included for troubleshooting:

```bash
swift build
.build/debug/mixerpoc list                                  # list devices + audio processes
.build/debug/mixerpoc route --app com.apple.Music --device Combo384   # route one app (verbose meter)
```

## Troubleshooting

- **Static/noise on a USB DAC:** usually a USB-audio quirk of the DAC + Mac, independent of this app. Try a different USB port (direct, not a hub/dock), a different cable, or fix the DAC to a single sample rate in Audio MIDI Setup.
- **Route stuck on "Waiting":** the app isn't producing audio yet, or the device is unplugged. It'll start automatically once both are present.
- **No permission prompt / no audio:** grant the app Audio Recording permission in System Settings → Privacy & Security.

## Project layout

```
Sources/MixerCore/   shared engine (tap, ring buffer, router, rules, engine)
Sources/MixerApp/    SwiftUI MenuBarExtra app
Sources/mixerpoc/    debug CLI
scripts/make_app.sh  build + bundle + sign
```

## Credits

This app was designed and built by **Claude** (Anthropic's Claude Opus 4.8), running in Claude Code, pair-programming with the repository owner.

Claude wrote the Core Audio engine, the SwiftUI menu-bar interface, and the packaging — and along the way diagnosed a tricky USB-DAC static bug by instrumenting the live audio path, proving the tapped samples were clean, and re-architecting from a fragile Core Audio *aggregate device* to a decoupled **tap → ring buffer → direct output** design that gives the DAC its normal IO path.

Built on Apple's Core Audio process-tap API (`CATapDescription`, macOS 14.2+).
