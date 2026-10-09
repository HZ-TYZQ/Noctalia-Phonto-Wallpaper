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

## Tests

```sh
tests/run.sh            # service logic + real-process tests (~15 s, no monitor needed)
tests/run.sh --phonto   # also checks the real phonto binary in this session
```

- `tests/service_sim.lua` runs `phonto_service.luau` against simulated outputs and
  a model process table, so multi-monitor behavior (hotplug, per-output videos in
  one process, bursts of changes, upgrades from the per-output layout) is covered
  on any machine.
- `tests/service_shell.lua` executes the service's real shell commands with a
  stand-in `phonto` binary (`tests/fake_phonto.c`): quoting of odd file names,
  pkill patterns against real `/proc` command lines, signals, `nice`, and systemd
  scopes (under a throwaway unit name, never the real `phonto.scope`).
- `tests/phonto_contract.sh` (`--phonto`) checks the phonto behaviors the service
  relies on, with the real binary on one monitor, and prints a memory estimate.
  It briefly draws a test pattern at the background layer.

Checks labeled `#1`–`#6` are regression tests for the issues in
[docs/known_issues.md](docs/known_issues.md).

Requires `luajit`, `ffmpeg`, `gcc`, and procps; the systemd checks run when
`systemd-run --user --scope` works. The tests load the service with LuaJIT, so
it must stay free of Luau-only syntax (`+=`, type annotations).
`TEST_VERBOSE=1` prints every check and command.

## License

MIT — see [LICENSE](LICENSE). Derived from the official Noctalia
`noctalia/mpvpaper` plugin (MIT, © noctalia); picker UI, thumbnail grid,
per-output assignments, state persistence, and systemd supervision are kept
from the original — only the playback backend (mpvpaper → phonto) and the
thumbnail generator (mpv → ffmpeg) were replaced.
