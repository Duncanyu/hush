# Hush

**A low-latency per-app mixer and system-wide equalizer for macOS.** Hush
captures exposed application audio, mixes it back to the selected output, and
applies optional per-source volume, mute, EQ, compression, and limiting.

**[Download Hush 0.3.0](https://github.com/Duncanyu/hush/releases/tag/v0.3.0)** ·
[Install](#download-and-install) · [Use](#use) ·
[Performance and latency](#performance-and-latency)

Hush requires an Apple Silicon Mac running macOS 14.2 or later.

## Download and install

Download **Hush-v0.3.0-macos-arm64.zip** from the
[0.3.0 release](https://github.com/Duncanyu/hush/releases/tag/v0.3.0).

1. Unzip the download and drag **Hush.app** into **Applications**.
2. Open Hush. This build is ad hoc signed and is **not notarized**. If macOS
   blocks the app, open **System Settings → Privacy & Security → Security →
   Open Anyway**, confirm, and launch Hush again. See
   [Apple's instructions](https://support.apple.com/en-us/102445). Only bypass
   this warning for a copy downloaded from this repository.
3. Allow **System Audio Recording** when macOS asks. Hush does not install a
   driver. If you change this permission in System Settings, quit and reopen
   Hush.
4. Hush appears in the menu bar. Click the waveform icon for quick controls,
   or choose **Full settings** for the complete mixer and processing controls.

The release includes a SHA-256 checksum file. Place it beside the ZIP and run:

```sh
shasum -a 256 -c Hush-v0.3.0-macos-arm64.zip.sha256
```

## Use

- Click the menu-bar waveform for system volume, output selection, app levels,
  mute, EQ presets, and processing status. The popup is keyboard-focused when
  opened.
- The menu-bar waveform follows the macOS appearance and changes into a
  low-cost live visualizer when enabled.
- The Hush app icon is colorful; the menu-bar waveform follows the macOS appearance.
- Choose **Full settings** for the dashboard, advanced mixer, 10-band EQ,
  dynamics, output controls, shortcuts, and general settings.
- Active applications are discovered automatically. Use **Add audio source**
  to add an application before it plays audio; manually added sources stay in
  the mixer and are pinned automatically.
- Pin an automatically discovered application to keep it in the mixer after
  it stops playing. Pinned applications also remain available in the Add audio
  source menu, including when they are not currently running.
- Remove a source from the mixer without permanently blacklisting it. If it
  plays audio again later, Hush can discover it again.
- Adjust each source's volume or mute state independently. Double-click a
  processing dial to reset it. Command-Z undoes EQ edits.
- Select **All**, **Only**, or **Excluding** for EQ and dynamics sources.
  Only and Excluding keep separate application selections.
- EQ presets, custom presets, dynamics settings, source selections, mixer
  sources, and output profiles are saved independently for each output device.
- Hush can switch the default output and control hardware volume when the
  device supports it. The macOS Control Center volume slider remains Apple's
  UI and reflects the same device volume.
- Hush supports ⌘W to close the settings window and ⌘A through the standard
  macOS responder chain.
- Turning Hush off suspends audio processing, listeners, refresh timers, and
  visualizer diagnostics. Only the shortcut and settings UI remain active.

Hush keeps the low-cost audio render graph warm while processing is enabled,
including during idle periods, so a newly active app does not wait for the
shared engine to start. Core Audio event listeners detect process output
quickly, with a low-frequency refresh as a fallback. Routes are retained while
their processes remain alive and are removed when those processes exit or the
output device changes.

Some protected or exclusive audio streams cannot be tapped by macOS. Hush can
only process streams that Core Audio exposes. A stream can remain listed
briefly after playback pauses. Enabled dynamics add processing latency and are
off by default. Auto preamp can attenuate the equalizer by the highest boost to
preserve headroom.

## Performance and latency

The stable audio path is:

```text
process tap → per-app aggregate device → capture IOProc → ring buffer
→ AVAudioEngine → app mixer → EQ/effects → output device
```

The ring buffer uses a small safety margin to avoid crackling and discontinuity
when Core Audio callbacks jitter. It permits a short backlog and trims only
stale excess rather than discarding a whole render buffer. This preserves the
latency improvement without sacrificing audio quality.

Hush's reported processing latency is not complete end-to-end latency. In one
AirPods configuration, Hush reported approximately 10.7 ms of effect latency
while the output device reported approximately 160 ms. The latter can include
Bluetooth buffering. AirPods can therefore feel later than built-in output,
particularly around pause and resume, even when Hush's processing contribution
is small.

Hush intentionally retains its per-app mixer and existing AVAudioEngine
pipeline. A single-clock aggregate-device experiment based on CoreAudioTapKit
was tested and reverted because it corrupted real audio. The current design
prioritizes clean playback, per-app controls, EQ, reliable short sounds, and
safe device recovery over an unverified architectural rewrite.

Automated validation for this release includes:

- `swift test`: 14 tests covering ring-buffer behavior, EQ response, dynamics,
  settings migration, output profiles, source scopes, mixer persistence, and
  master-switch state restoration.
- Release build with `./build.sh`.
- Strict code-signature verification of the packaged application.

The packaged application keeps only the required application icon resource;
SwiftPM's unused resource bundle is omitted to reduce the distribution size.

Bluetooth end-to-end synchronization and subjective audio quality still depend
on the output device and require real-world listening; the automated tests do
not measure those properties.

## Build from source

Install Xcode's command line tools, then run:

```sh
swift test
./build.sh
open dist/Hush.app
```

The build script creates an arm64 `build/Hush.app`, ad hoc signs it, and copies
it to `dist/Hush.app`. It does not produce a notarized distribution.

Hush uses Apple's Core Audio, AVAudioEngine, AudioToolbox, and AppKit/SwiftUI.
Audio capture permissions and the streams available for processing are
controlled by macOS.

## Changelog

### 0.2.2

- Changed the application and menu-bar icon to the supplied monochrome waveform.
- Restored the popup to a translucent native macOS material surface.

### 0.2.3

- Matched source routing typography and spacing to the surrounding dashboard
  cards and quick-menu controls.
- Added a source-routing icon inside the Dashboard card header to match the
  other Dashboard sections.
- Kept Advanced source routing as a standalone editor section with the same
  heading hierarchy as the mixer and equalizer.
- Restored the colorful Hush application icon while keeping the menu-bar
  waveform monochrome and appearance-aware.

### 0.3.0

- Added optional automatic updates from the Hush GitHub releases.
- Added checksum verification before an update is installed.
- Added a General setting to enable or disable automatic updates.
