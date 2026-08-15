# Noctalia plugin source: phonto-wallpaper

A Noctalia plugin source repository holding personal plugins:

| Plugin | ID | Description |
| --- | --- | --- |
| Phonto Video Wallpaper | `tyzq/phonto-wallpaper` | Video wallpapers via phonto (GPU-accelerated Wayland renderer), a minimal backend replacement of the official `noctalia/mpvpaper` plugin. |

## Install

Add this repo as a plugin source in Noctalia (Settings → Plugins → Add source),
or from the command line:

```sh
noctalia msg plugins source add tyzq git https://github.com/HZ-TYZQ/Noctalia-Phonto-Wallpaper.git
```

Then enable **Phonto Video Wallpaper** and configure its **Video directory**.

## Requirements

- `phonto` on `PATH` — renders the video wallpaper surface
- `ffmpeg` on `PATH` — generates picker thumbnails and the static fallback frame

See [phonto-wallpaper/README.md](phonto-wallpaper/README.md) for usage, IPC
commands, and settings.

## License

MIT — see [LICENSE](LICENSE). Derived from the official Noctalia
`noctalia/mpvpaper` plugin (MIT, © noctalia); picker UI, thumbnail grid,
per-output assignments, state persistence, and systemd supervision are kept
from the original — only the playback backend (mpvpaper → phonto) and the
thumbnail generator (mpv → ffmpeg) were replaced.
