# Hush

**Version 0.1.3 — unreleased**

A native macOS menu bar mixer and 10-band system audio equalizer. Requires macOS 14.2 or later.

Build with `./build.sh`, then open `build/Hush.app`. The first active audio app prompts for **System Audio Recording** permission. Hush does not install a driver. It uses private Core Audio process taps, a shared AVAudioEngine, and Apple-supplied audio units: the 10-band EQ, dynamics processor, and peak limiter. The ring buffer only transfers captured PCM between Core Audio callbacks; it performs no signal processing.

Click the waveform in the menu bar for quick controls. **Full settings** has a dashboard for output and presets, plus an **Advanced** tab with the app mixer, 10-band EQ graph, preamp, interactive output dials, routing diagnostics, and optional compressor and peak limiter. Drag around a dial or enter an exact number; double-click a processing dial to reset it. The compressor shows live gain reduction. Drag an EQ point or enter a gain from −24 to +24 dB; Command-Z undoes edits. Gaming, Movie, Music, custom presets, and dynamics settings are saved separately for each output device. Hush can switch the default output and control its hardware volume when that device supports it. The macOS Control Center volume slider stays Apple's UI and reflects the same device volume.

Hiding the menu bar icon shows Hush in the Dock. Hush keeps its low-cost audio render graph warm while processing is enabled, including during idle periods, so a newly active app does not wait for the shared engine to start. Routes are retained while their processes remain alive and are removed when those processes exit or the output device changes. Core Audio event listeners detect process output immediately, with a low-frequency safety refresh as a fallback. Per-app taps can still take a short time when an app first appears or the output device changes. Quit Hush to return audio to the normal path.

Some protected or exclusive audio streams cannot be tapped by macOS. The mixer lists processes with active output streams; a stream can remain listed briefly after playback pauses. Audio processing is limited to streams that Core Audio exposes to Hush. Enabled dynamics add their own processing latency; both effects are bypassed by default. Auto preamp can attenuate the equalizer by the highest boost to preserve headroom.

## AirPods latency investigation

Hush's current per-app routing path is:

```text
process tap → per-app aggregate device → capture IOProc → ring buffer
→ AVAudioEngine → app mixer → EQ/effects → output device
```

This uses separate clock domains for capture and playback. The ring buffer bounds
the queued frames and drops stale backlog, but it does not synchronize the tap
clock with the output clock or preserve audio/video timestamps. The difference
is usually less apparent on built-in output and more noticeable on Bluetooth
devices such as AirPods, whose reported output latency can be approximately
160 ms. Pause/resume transitions can make the mismatch more apparent because
the tap, ring, AVAudioEngine output client, and Bluetooth device resume on
independent schedules.

The reported Hush effect latency (approximately 10.7 ms in one AirPods
configuration) is not the complete end-to-end synchronization cost. Changing
the ring size or polling interval cannot correct the underlying clock-domain
problem. CoreAudioTapKit's single-clock design is a useful reference: it places
the physical output and tap in one private aggregate, makes the physical output
the clock master, enables maximum-quality tap drift compensation, and processes
tap input directly into the aggregate output buffers in one IOProc. That design
does not currently replace Hush's per-app mixer architecture; the limitation is
documented here before making that larger architectural change.

This investigation is documented in v0.1.3. It is not a release.
