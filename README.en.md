# DeepSeek Harness Desktop for Linux

Brings the official desktop application ([`deepseek-ai/deepseek-harness`](https://github.com/deepseek-ai/deepseek-harness),
`apps/desktop`) to Linux and fills in what it is missing there. This runs upstream's own Electron
application — it is not a browser wrapper.

![Captured on Ubuntu 26.04 / GNOME / Wayland](docs/screenshot.png)

<sub>Captured live: the native titlebar and menu bar are gone, leaving a 40px caption with
system-style window buttons and Application/Edit as popup menus on the caption.</sub>

## What this adds beyond "it launches"

| | |
|---|---|
| **Cross-platform appearance** | Upstream draws a custom titlebar on Windows only; on Linux it falls back to the GTK titlebar **plus** menu bar (110px of non-client area, measured). Linux now takes the same path: a 40px caption, window buttons drawn by Electron's overlay in the system style, and the native menu bar folded into the caption |
| **In-application updates** | Upstream's update channel only knows mac/win, and unsigned builds skip update configuration entirely. The AppImage channel is wired here: check → download → verify sha512 → replace itself → restart |
| **One-command install** | Download the latest release → verify sha512 → install into `~/.local` → create a desktop entry. It installs per user rather than into `/opt` so self-update can replace its own file |
| **Automatic upstream tracking** | CI scans upstream tags daily and publishes a build when the patches still apply; the in-application updater reads that same release. A conflicting patch fails the run and emails the owner instead of shipping something half-built |

## Install

```bash
git clone https://github.com/JamesYasR/dsh-desktop-linux
cd dsh-desktop-linux
./scripts/install-from-release.sh
```

You can also take the AppImage straight from [Releases](../../releases) and run it after `chmod +x`.

## Build from source

Node 22.19+ or 24, and pnpm 11.

```bash
./scripts/fetch-upstream.sh      # clone upstream into ./upstream
./scripts/apply-patches.sh       # apply the patch series
./scripts/build.sh --appimage    # --deb / --rpm / --all also work
```

## When upstream releases

Usually nothing: CI tracks it and the application's Check for Updates does the rest. To build locally:

```bash
./scripts/upgrade.sh --check     # verify the patches still apply; a failure rolls back fully and names the file to fix
./scripts/upgrade.sh             # build and reinstall once that passes
```

See [docs/upgrading.md](docs/upgrading.md) and [docs/updates.md](docs/updates.md).

## Patches

18 of them. `0001–0015` are the community porting base (from
[ffyfox/dsh-desktop-linux](https://github.com/ffyfox/dsh-desktop-linux); this repository keeps its
commit history). `0016–0018` are ours: the in-application update channel, the runtime feed override,
and the cross-platform caption. Each patch is documented in [patches/README.md](patches/README.md).

## Known limitations

- The tray uses StatusNotifierItem, which needs `gnome-shell-extension-appindicator` on GNOME
  (preinstalled on Ubuntu).
- Artifacts are unsigned and updates are verified by sha512 alone, with no signature check, so the
  feed must be an HTTPS origin its publisher controls.
- x86_64 only.
- deb / rpm / Arch packages build, but self-update applies to the AppImage only: installation
  replaces the AppImage file that is currently running.

## License

MIT. A community project with no affiliation to DeepSeek; DeepSeek Harness and its dependencies
remain under their own upstream licenses and trademark policy.
