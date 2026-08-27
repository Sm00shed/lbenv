# Reproducible Nix build environment for the Ladybird browser

A Nix flake that provides a `nix develop` shell for building the
[Ladybird](https://github.com/LadybirdBrowser/ladybird) browser. The shell
supplies a pinned toolchain and every build dependency from the Nix store, so
Ladybird's own dependency fetcher is never used.

Tested scope: on Linux x86_64 (NixOS and CachyOS) the browser builds and runs.

Versions live in the `Sm00shed/lbdb` repository: one `<sha>.toml` per
Ladybird commit, with `latest` naming the newest. No version is active until you
pick one with `lbenv` — see [Source version management](#source-version-management).

## Requirements

The only thing that must be installed on the host is Nix. No compiler, no
CMake, no git — the shell brings its own Clang 21, LLD, CMake, Ninja, git, and
the rest of the build inputs.

### Install Nix

On any Linux distribution (not needed on NixOS), install Nix with the official
installer:

```bash
sh <(curl -L https://nixos.org/nix/install)
```

### Enable flakes

Enable flakes once so they stay on. Add this line to `~/.config/nix/nix.conf`:

```
experimental-features = nix-command flakes
```

On NixOS, set it in `configuration.nix` instead and run `nixos-rebuild switch`:

```nix
nix.settings.experimental-features = [ "nix-command" "flakes" ];
```

After this, `nix develop github:Sm00shed/lbenv` works directly.

## Quick start

Enter the shell — it opens an interactive subshell:

```bash
nix develop github:Sm00shed/lbenv
```

Pick a version with `lbenv` (newest) or `lbenv switch <hash>`. That creates a
git worktree for the chosen Ladybird commit under `~/lbenv-wt/<hash>/`, drops
you into it, and exports `LADYBIRD_BUILD_DIR` (`Build` inside the worktree). Each
version is fully isolated — its own source and build, never mixed. Configure and
build there:

```bash
cmake -B "$LADYBIRD_BUILD_DIR" -GNinja \
  -DCMAKE_BUILD_TYPE=Release \
  -DENABLE_LTO_FOR_RELEASE=OFF \
  -DICU_ROOT="$ICU_ROOT" \
  -DENABLE_NETWORK_DOWNLOADS=OFF \
  -DLADYBIRD_CACHE_DIR=Caches
```

Compile:

```bash
ninja -j$(nproc) -C "$LADYBIRD_BUILD_DIR"
```

## Build configuration

The CMake options above serve these purposes.

`-DCMAKE_BUILD_TYPE=Release`
  Optimized build.

`-DENABLE_LTO_FOR_RELEASE=OFF`
  Disables link-time optimization to keep link times and memory use down.

`-DICU_ROOT="$ICU_ROOT"`
  Points CMake at the ICU 78 development tree from the store. The shell exports
  `ICU_ROOT`.

`-DENABLE_NETWORK_DOWNLOADS=OFF`
  Stops the build from fetching data files at configure time. The shell
  pre-populates them (see below).

`-DLADYBIRD_CACHE_DIR=Caches`
  Uses the in-tree `Caches` directory that the shell fills.

## Running

After the build, launch the browser from the shell:

```bash
Ladybird
```

`Ladybird` is a shell function that runs the browser from the selected version's
`$LADYBIRD_BUILD_DIR` and passes the CA certificate automatically. Override it
with an environment variable:

```bash
LADYBIRD_CERTIFICATE=/path/to/cert.crt Ladybird
```

## Source version management

Ladybird versions are recorded in the `Sm00shed/lbdb` repository (one TOML
per commit, maintained by a CI job every few minutes). The picker, the list and
the banner are all derived from it.

Until you pick a version the shell shows none:

    Ladybird Dev Shell

       no Ladybird version selected
         lbenv               newest recorded
         lbenv switch <hash>  pick a version

`lbenv`
  Enter the newest recorded version.

`lbenv switch <hash>`
  Pick a recorded version by its Ladybird commit hash; a unique prefix is
  enough. A recorded entry pins the whole environment — flake revision,
  toolchain, dependencies, overrides, plus the exact Ladybird source and
  nixpkgs — so it rebuilds deterministically. The recorded flake revision is
  the lbenv HEAD at the time the entry was written; it is not independently
  verified to build that Ladybird commit.

`lbenv dev`
  Develop on top of the newest recorded version. Checks out that commit on a
  fresh `lbenv-dev/<hash>` branch so you can commit onto it, while inheriting
  the recorded entry's frozen nixpkgs and lbenv pin. The banner then shows the
  branch's real HEAD, which may be ahead of the recorded commit.

`lbenv new [hash]`
  Floating placeholder on a commit not in lbdb yet (default: upstream
  HEAD). No frozen flake revision.

Once selected, the banner shows the commit and the environment:

    Ladybird Dev Shell

       Commit
         LibWeb: Fix flexbox min-size computation
         2026-08-02 09:15
         12176d08207fb7cb8e8e0b87521ed3468cf8ee40

       Environment
         nixpkgs  8f0500b9
         vcpkg    1bfb778f
         flake    5e6c3378
         dir      ~/lbenv-wt/12176d08…

       Reproduce: lbenv switch 12176d08207fb7cb8e8e0b87521ed3468cf8ee40

The `Reproduce` line rebuilds the exact environment on any machine. When filing a
bug, include the commit hash from the banner. You can also pin the flake
reference directly:

```bash
nix develop github:Sm00shed/lbenv/<commit-hash>
```

Each selected version lives in its own git worktree under
`~/lbenv-wt/<ladybird-hash>/`, its build in `Build/` inside. Switching never
touches another version; jump back to a built one and it is ready instantly. The
worktrees share one clone (`~/ladybird`) for git objects. Set `LADYBIRD_SRC` /
`LBENV_WT` to relocate the clone or the worktree root.

`lbenv` reads the database from the `lbdb` flake input (works offline), with
curl as a fallback/refresh. `LADYBIRD_FLAKE_DIR=~/lbenv` points `lbenv` at a
local clone of *this* flake for `nix develop`; otherwise the published flake on
GitHub is used.

## What this environment does

The shell replaces Ladybird's vendored dependency handling. Ladybird normally
uses vcpkg to fetch and build third-party libraries; here every library comes
from the Nix store instead.

The shell unsets `VCPKG_ROOT` and `CMAKE_TOOLCHAIN_FILE` so the build ignores
vcpkg entirely.

It sets `CMAKE_PREFIX_PATH` to the store paths of each dependency, so CMake
never reads `/usr/lib` or other system locations.

Several dependencies need overrides:

- **skia** is pinned to the exact revision Ladybird expects and built with an
  extra flag that gives `SKCMS_API` default symbol visibility, which the link
  step requires.
- **angle** provides the GPU backend. It is built with the Clang 20 standard
  environment because Clang 21 hits an internal compiler error while parsing a
  nested union type in ANGLE's Vulkan helpers.
- **mimalloc** is pinned to 2.2.7. Ladybird targets the mimalloc 2.x series;
  the nixpkgs default is a 3.x release, which is incompatible.

The shell also exports environment used by the build, and pre-populates data
caches:

- `ICU_ROOT` points at the ICU 78 development tree, matching the `-DICU_ROOT`
  CMake option.
- `FONTCONFIG_FILE` points at a generated fontconfig file that exposes the
  DejaVu and Liberation font packages, so text rendering works without any
  host font configuration.
- The `Caches` directory is filled with the data files Ladybird would otherwise
  download: the Unicode Character Database (UCD, including emoji and IDNA
  tables), the HSTS preload list, the Public Suffix List, and the CA
  certificate bundle (CACERT). The CA bundle is copied into the tree rather
  than referenced in the store because the Linux Landlock sandbox blocks
  RequestServer from reading store paths directly.

## Platform notes

The environment uses the standard `nixos-26.05` nixpkgs, so all inputs come from
the binary cache with no local rebuilds. The Linux inputs (Qt, Vulkan,
PulseAudio, libdrm, glslang) are present in the shell, but not all code paths
that use them have been exercised.

## Acknowledgements

This environment started as the Ladybird shell from
nix-community/nix-environments (MIT). It has since been rewritten,
but the original made it possible. Thanks to its authors.

Original: https://github.com/nix-community/nix-environments/tree/master/envs/ladybird

## License

GPL-2.0, see LICENSE.
Originally derived from nix-community/nix-environments (MIT), see LICENSE.MIT.
