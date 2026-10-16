# Hush

Hush is a per-app audio mixer and equalizer for Apple Silicon Macs. It captures
audio that macOS exposes through Core Audio taps, then routes it through per-app
volume and mute controls, a 10-band EQ, optional dynamics, and the selected
output device.

**[Download Hush 0.3.1](https://github.com/Duncanyu/hush/releases/tag/v0.3.1)** ·
[Install](#install) · [Use](#use) · [Latency and diagnostics](#latency-and-diagnostics) ·
[Build](#build-from-source)

Requires macOS 14.2 or later on Apple Silicon.

## Install

1. Download `Hush-v0.3.1-macos-arm64.zip` from the
   [0.3.1 release](https://github.com/Duncanyu/hush/releases/tag/v0.3.1).
2. Unzip it and move `Hush.app` to Applications.
3. Open Hush and grant **System Audio Recording** when macOS prompts you. If you
   change this permission later, quit and reopen Hush.

The release is ad hoc signed and **not notarized**. If macOS blocks it, use
**System Settings → Privacy & Security → Open Anyway** for the copy downloaded
from this repository. See [Apple's instructions](https://support.apple.com/en-us/102445).

The release also includes a checksum file. Verify both downloads from the same
release before installing:

```sh
shasum -a 256 -c Hush-v0.3.1-macos-arm64.zip.sha256
```

## Use

Hush lives in the menu bar. Click its waveform icon for quick output, app
volume, mute, and EQ controls. Choose **Full settings** for source routing,
the advanced mixer, EQ, dynamics, shortcuts, and general settings.

- Playing apps appear automatically. **Add audio source** can prepare an app
  before it plays; pin an app to keep it in the mixer after playback stops.
- Set each source's output in **Source routing**. An unassigned source follows
  the system default output.
- Adjust EQ globally or limit it to selected sources. The compressor and peak
  limiter are optional and off by default. EQ presets and output profiles are
  saved per output device.
- Double-click a processing dial to reset it. Command-Z undoes EQ edits.
- Turn off **Processing** to suspend routing and the visualizer. Automatic
  update checks can be disabled in **General**.

Some protected or exclusive streams are unavailable to Core Audio taps and
cannot be processed by Hush. A source may remain visible briefly after audio
stops. Output volume control depends on the selected device.

## Latency and diagnostics

Hush's audio path is:

```text
process tap → per-app aggregate device → capture callback → ring buffer
→ AVAudioEngine → per-app effects and mixer → output device
```

The ring allows a small safety margin for callback jitter. It trims stale
backlog only when needed, to protect clean playback and short sounds. Hush does
not currently preserve an app's original audio/video presentation schedule
through the separate capture and playback path. In particular, AirPods may
show additional A/V offset with Hush enabled even when the ring is healthy.
This release does **not** claim to fix that offset.

For troubleshooting, open **Full settings → Advanced → Routing diagnostics** at
the bottom of the page. The section is collapsed by default. It shows current
and recent peak ring occupancy, missing frames, skipped backlog, tap-input to
source-render timestamp difference, and the default output's reported hardware
latency. Detailed per-frame timing runs only while the section is open.

These are different parts of the path. The tap-to-source value excludes
downstream output and Bluetooth presentation. The device figure is reported by
macOS; it is not a measured end-to-end or audible latency. Do not add it to
another downstream estimate. To compare A/V sync, record the same visible
flash and audible click with and without Hush, using an external microphone
and the same output device.

Hush keeps AVAudioEngine and the per-app mixer. A previous single-clock
aggregate-device experiment corrupted audio and was reverted. Bluetooth A/V
sync and subjective audio quality still need real-device listening checks.

## Build from source

Install Xcode's command line tools, then run:

```sh
swift test
./build.sh
open dist/Hush.app
```

`build.sh` builds an arm64 release app, signs it ad hoc, and copies it to
`dist/Hush.app`. It does not notarize the app. The test suite covers ring
buffering and timestamps, EQ response, dynamics, settings migration, mixer
persistence, and output profiles.

## Changelog

### 0.3.1

- Added tap and source-render timing diagnostics for investigating routing
  delay, while keeping the existing audio buffering and engine.
- Moved routing diagnostics into a collapsed Advanced section and removed
  redundant latency estimates, temporary counters, and unused UI.
- Disabled per-frame timing work when diagnostics are closed; cached the
  reported output latency instead of querying Core Audio on every visualizer
  refresh.
- Corrected planar stereo visualizer sampling and reduced unnecessary
  diagnostics-driven UI updates.

### 0.3.0

- Added optional automatic updates from GitHub releases, with SHA-256
  verification before installation.
- Added a General setting for update checks.

### 0.2.3

- Refined the source-routing controls in Dashboard and Advanced settings.
- Restored the colorful app icon and kept the menu-bar waveform monochrome.

### 0.2.2

- Updated the app and menu-bar icons and restored the translucent quick menu.
