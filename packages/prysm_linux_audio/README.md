# prysm_linux_audio

Linux PulseAudio/PipeWire input device enumeration for Prysm.

Call capture and playback live in the main app (`LinuxMicCapture`, `call_pcm_playback.dart`).

## Runtime dependencies

- PipeWire with PulseAudio compatibility (`pipewire-pulse`)
- `libpulse`

## Build dependencies (Arch Linux)

```bash
sudo pacman -S pipewire pipewire-pulse libpulse
```
