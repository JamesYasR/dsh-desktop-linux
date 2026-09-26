# dsh-desktop-linux

[中文](README.md) | **English**

> An independent community project. **Not** an official DeepSeek product, and not
> affiliated with DeepSeek.

Ports the **packaging pipeline** of the official
[DeepSeek Harness](https://github.com/deepseek-ai/deepseek-harness) desktop app
(the Electron application in `apps/desktop`) to Linux, producing
AppImage / deb / rpm / Arch packages.

Upstream explicitly does not support Linux today (`apps/desktop/README.md`:
*"Linux is not a supported Desktop release target."*). This project fills exactly
that gap: it teaches the official packaging pipeline about `linux-x64` and emits
installable artifacts.

## How this differs from a "wrapper"

Most existing Linux desktops in the ecosystem take another route: launch `dsh web`
and wrap it in a window of their own. What this project ships is **the official
Electron application itself** — which has things a wrapper cannot reproduce:

- the renderer loads over its own `dsh-app://` protocol rather than connecting to a local web server;
- it carries its own Node / pnpm / Python runtime and does not use the system Node;
- it owns `$DSH_HOME/profiles/desktop` exclusively and does not touch the `web` profile.

The cost is a much heavier build: clone the upstream monorepo, run the pnpm
workspace build, then package with electron-builder.

## Install

| Distribution | Format | How |
|---|---|---|
| Arch Linux | AUR | `yay -S deepseek-harness-desktop` (or `paru`) |
| Any | AppImage | Download from [Releases](https://github.com/ffyfox/dsh-desktop-linux/releases), `chmod +x`, run it |
| Debian / Ubuntu | deb | `sudo apt install ./deepseek-harness-*.deb` |
| Fedora / RHEL | rpm | `sudo dnf install ./deepseek-harness-*.rpm` |

Artifacts are **unsigned** builds (the file name carries `-unsigned`). Once
installed, `dsh://` links are handed to it.

## Building from source

Requirements: Node 22.19+ or 24+, **pnpm 11**, git, and network access to GitHub.
Building the rpm additionally needs `rpmbuild` on the system (`rpm-tools` on Arch).

```bash
git clone https://github.com/ffyfox/dsh-desktop-linux
cd dsh-desktop-linux

./scripts/fetch-upstream.sh      # fetch upstream sources (defaults to the tag pinned in PKGBUILD)
./scripts/apply-patches.sh       # apply the patch series
./scripts/build.sh --all         # AppImage + deb + rpm
./scripts/verify.sh --runtime    # verification matrix
```

`build.sh` flags: `--dir` (unpacked directory only, fastest), `--appimage`
(default), `--deb`, `--rpm`, `--all`. The long pole is the pipeline itself
(`build:official` → `release:pack` → `prepare:*` → `package`); each extra format
only adds one fpm/AppImage packaging pass, so building formats separately is both
faster and easier to debug.

Artifacts land in
`upstream/apps/desktop/.desktop-build/targets/linux-x64/unsigned-artifacts/`.

### Fill in `.env.linux` before building deb / rpm

Linux release settings are read from `apps/desktop/.env.linux` (git-ignored;
`build.sh` creates it from `.env.linux.example` on first run):

| Setting | When | Notes |
|---|---|---|
| `DSH_DESKTOP_APP_ID` | always | e.g. `com.deepseek.harness` |
| `DSH_DESKTOP_LINUX_MAINTAINER` | deb / rpm | Becomes Debian's `Maintainer:` and rpm's `Packager:`. Must be `Name <email>` and refers to **whoever built the package** |
| `DSH_DESKTOP_LINUX_HOMEPAGE` | deb / rpm | Becomes Debian's `Homepage:` and rpm's `URL:`. By convention it points at the **upstream project** |

Two easy traps:

- **These three settings can only come from the file.** Upstream filters
  `DSH_DESKTOP_APP_ID` and every `DSH_DESKTOP_LINUX_*` out of the process
  environment before merging the file, so
  `DSH_DESKTOP_LINUX_MAINTAINER=… ./scripts/build.sh --deb` is **silently ignored**.
- **Conversely, which formats to build can only come from the environment**:
  `DSH_DESKTOP_TARGET_FORMATS`. It is a per-build selector and is rejected if
  written into `.env.linux`. (`build.sh`'s `--deb` / `--rpm` / `--all` already set it.)

Both are validated in the `configuration` stage at the very front of packaging,
so you find out before fpm is halfway through.

### Hard requirement

**pnpm 11 is required.** The upstream repository declares
`packageManager: pnpm@11.7.0`, and pnpm 11 switches to that version by itself.
pnpm 9 fails `pnpm install` with `ERR_PNPM_LOCKFILE_CONFIG_MISMATCH`.

## Arch package

The PKGBUILD consumes upstream's release tarball and does not depend on the
`./upstream` checkout:

```bash
./scripts/aur-dir.sh     # flatten into ./aur and generate .SRCINFO
cd aur && makepkg -si
```

`aur-dir.sh` is not optional sugar: **makepkg resolves local sources by basename
inside the PKGBUILD's own directory**, so the PKGBUILD and the patches must sit
flat together. The contents of `./aur` are exactly what you would push to the AUR.

The Arch package installs the unpacked tree into `/opt/deepseek-harness-desktop`
and symlinks `/usr/bin/deepseek-harness` — on Arch there is no need to wrap it in
an AppImage/deb/rpm.

## How it works

```
Official Electron shell (apps/desktop)
├── renderer ──── dsh-app:// protocol ──── application UI
└── Host process ─── real Node from primary-runtime ─── bundled dsh runtime
                          └── $DSH_HOME/profiles/desktop
```

Three design points worth knowing:

- **The Host runs on a real Node, not Electron's node mode.** Under Electron's
  node mode `sharp` segfaults while decoding, so on Linux the Host uses the Node
  bundled in primary-runtime. Consequently **Linux artifacts do not put the dsh
  tree into an asar** (a real Node cannot read inside an archive), which is why
  `linux-unpacked` is large.
- **The profile is exclusive.** The desktop uses `$DSH_HOME/profiles/desktop`, and
  the CLI rejects that profile at the argument layer
  (`error: profile "desktop" is managed exclusively by the Electron application`).
  Sessions, settings, and credentials still live at the root of `$DSH_HOME`,
  shared with the CLI.
- **Sandboxing.** Where the kernel supports unprivileged user namespaces, the
  renderer runs in a namespace sandbox (separate user namespace + seccomp); only
  where it does not does it fall back to a setuid `chrome-sandbox`. The AppImage
  leaves this to AppRun's own probe, and the deb / rpm / Arch packages make the
  same decision in their postinst.

## Known limitations

- **No auto-update.** Upstream's mandatory-update policy channel only recognises
  `desktop-win` / `desktop-mac` client identities, and Linux artifacts carry no
  update channel, so the Linux build embeds no policy, never polls, and never
  updates itself.
- **Unsigned.** Artifacts are unsigned builds.
- **Platform sees a Linux client as macOS.** Upstream maps client identity with
  `platform === 'win32' ? 'desktop-win' : 'desktop-mac'`, so Linux lands on
  `desktop-mac`. That follows from upstream's `'darwin' | 'win32' | null` union
  and is not introduced here; the same request reports `device_model` as
  `linux-x64`.
- **`linux-unpacked` is about 1.1G.** With asar disabled it is a tree of small
  files; the AppImage compresses it to 339M, but first launch reads more files
  than an asar build would.
- **x86_64 only.**

## License

MIT. Upstream `deepseek-harness` is MIT as well. This repository contains only
packaging scripts, patches, and package definitions — no upstream source.
