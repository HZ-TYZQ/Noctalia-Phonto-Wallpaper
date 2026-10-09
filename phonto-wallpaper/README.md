# Phonto Video Wallpaper

Animated and video wallpapers for Noctalia, powered by `phonto`
(a GPU-accelerated Wayland video wallpaper renderer with NVDEC/EGL support).

This is a minimal backend replacement of the official `noctalia/mpvpaper` plugin:
the picker UI, thumbnail grid, per-output assignments, state persistence, and
systemd supervision are kept as-is — only the playback backend (`mpvpaper`) and
the thumbnail generator (`mpv`) were swapped for `phonto` and `ffmpeg`.

## Plugin

| Field | Value |
| --- | --- |
| ID | `tyzq/phonto-wallpaper` |
| Entries | Service: `service`; Panel: `picker`; bar widget: `phonto`; Shortcut: `shortcut` |

## Requirements

Install `phonto` and `ffmpeg` on `PATH`. `phonto` ([museslabs/phonto](https://github.com/museslabs/phonto),
GPL-3.0-or-later, invoked as an independent external process) renders the wallpaper
surface (video decoding, scaling, and its own hardware acceleration), and
`ffmpeg` renders picker thumbnails and the static fallback frame.

The plugin works on `wlr-layer-shell` compositors (Niri, Hyprland, Sway, Mango).

## Usage

1. Set **Video directory** in the plugin settings (defaults to `~/Videos`).
2. Add the **Phonto Video Wallpaper** bar widget, the control center shortcut, or open the picker with

   ```sh
   noctalia msg panel-toggle tyzq/phonto-wallpaper:picker
   ```

3. Choose a target output (or **All outputs**), then click a video to apply it.
   Use **Stop** to restore Noctalia's own wallpaper on that output.

Assignments persist across restarts. Supported files: `mp4`, `webm`, `mkv`, `mov`, `gif`.

## IPC Commands

You can control the video wallpaper externally via Noctalia's IPC mechanism. Replace `[connector]` with your display name (e.g. `eDP-1`), or omit it to target all monitors:

- `noctalia msg plugin tyzq/phonto-wallpaper:service all pause [connector]` - Pauses playback via SIGSTOP (or the cgroups freezer in systemd mode).
- `noctalia msg plugin tyzq/phonto-wallpaper:service all resume [connector]` - Resumes playback.
- `noctalia msg plugin tyzq/phonto-wallpaper:service all toggle [connector]` - Toggles playback between paused and resumed state.
- `noctalia msg plugin tyzq/phonto-wallpaper:service all clear <connector>` - Stops the wallpaper on the specified monitor and extracts a frame as a static wallpaper.
- `noctalia msg plugin tyzq/phonto-wallpaper:service all clear-all` - Stops all active video wallpapers.
- `noctalia msg plugin tyzq/phonto-wallpaper:service all reapply` - Re-applies the last applied wallpaper, relaunching phonto; also force-restarts a running one or revives a dead one. Made for lock/unlock hooks: clear-all on lock, reapply on unlock.

## Settings

| Setting | Type | Default | Description |
| --- | --- | --- | --- |
| `video_directory` | `folder` | *(empty)* | Folder scanned for wallpaper videos; defaults to `~/Videos` when empty. |
| `run_as_systemd` | `bool` | `false` | Runs instances inside systemd transient scopes (`systemd-run`) for resource control. |
| `extract_last_frame` | `bool` | `true` | Extracts a static frame to use as a wallpaper when video playback is stopped or paused. |
| `cpu_quota` | `number` | `0` | Systemd `CPUQuota=` limit in percentage. Requires `run_as_systemd`. |
| `allowed_cpus` | `string` | *(empty)* | Systemd `AllowedCPUs=` limits (e.g., `0-3`). Requires `run_as_systemd`. |
| `memory_max` | `string` | *(empty)* | Systemd `MemoryMax=` limits (e.g., `500M`). Requires `run_as_systemd`. |
| `cpu_weight` | `number` | `0` | Systemd `CPUWeight=` priority. Requires `run_as_systemd`. |
| `nice` | `number` | `0` | Process `nice` priority level. Requires `run_as_systemd`. |
| `glyph` | `glyph` | `movie` | Bar widget icon. |

## How it works

A headless service supervises `phonto` instances, either launching them directly
or wrapping them in systemd transient scopes (`systemd-run`) for strict CPU and
memory resource limits. `phonto VIDEO` applies the video to every output;
`phonto --display OUTPUT VIDEO` pins it to one output. When a video is assigned,
the service first shows the cached thumbnail as the Noctalia wallpaper (so themes
follow it and there is no black screen), then hides the host wallpaper layer once
phonto is up. The picker panel, bar widget, and control center shortcut are thin clients that drive the
service through the plugin's shared state. When the plugin is disabled or
Noctalia exits, the service's `onExit` hook terminates every running `phonto`
instance — including frozen or paused ones — so no orphan processes remain.

## License

MIT — see the [LICENSE](../LICENSE) at the repository root. Derived from the
official `noctalia/mpvpaper` plugin (MIT, © noctalia).
