# Ladybird Nix development environment

A Nix flake that provides a `nix develop` shell for building the
[Ladybird](https://github.com/LadybirdBrowser/ladybird) browser. The shell
supplies a pinned toolchain and every build dependency from the Nix store, so
Ladybird's own dependency fetcher is never used.

Tested scope: on Linux x86_64 (NixOS and CachyOS) the browser builds and runs.
On macOS x86_64 it builds, but runtime testing is limited. Apple Silicon is
untested.

The default source is the last tested Ladybird commit tracked in
`versions.json`. Run `lbenv list` to see all tested versions.

## Requirements

The only thing that must be installed on the host is Nix. No compiler, no
CMake, no git — the shell brings its own Clang 21, LLD, CMake, Ninja, git, and
the rest of the build inputs.

### Install Nix

On any Linux distribution or macOS (not needed on NixOS), install Nix with the
official installer:

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

Clone Ladybird, enter the shell, configure, and build:

```bash
git clone https://github.com/LadybirdBrowser/ladybird.git
cd ladybird
```

Then enter the shell (this opens an interactive subshell):

```bash
nix develop github:Sm00shed/lbenv
```

The shell prints its banner and is ready. Configure the build with CMake:

```bash
cmake -B Build/release -GNinja \
  -DCMAKE_BUILD_TYPE=Release \
  -DENABLE_LTO_FOR_RELEASE=OFF \
  -DICU_ROOT="$ICU_ROOT" \
  -DENABLE_NETWORK_DOWNLOADS=OFF \
  -DLADYBIRD_CACHE_DIR=Caches
```

On macOS, add the deployment target so the build matches the SDK:

```bash
  -DCMAKE_OSX_DEPLOYMENT_TARGET="$MACOSX_DEPLOYMENT_TARGET"
```

Compile:

```bash
ninja -j$(nproc) -C Build/release
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

`-DCMAKE_OSX_DEPLOYMENT_TARGET="$MACOSX_DEPLOYMENT_TARGET"`
  macOS only. Aligns the deployment target with apple-sdk_15. Without it the
  build falls back to an older target and fails.

## Running

After the build, launch the browser from the shell:

```bash
Ladybird
```

`Ladybird` is a shell function that hides the platform differences. On Linux it
runs `Build/release/bin/Ladybird`. On macOS it runs the `Ladybird.app` bundle
with `--disable-sandbox`, because the sandbox needs codesigning. In both cases
the CA certificate is passed automatically. Override it with an environment
variable:

```bash
LADYBIRD_CERTIFICATE=/path/to/cert.crt Ladybird
```

## Source version management

The `lbenv` command is available inside the shell and selects which Ladybird
commit the shell builds. The active version is printed each time the shell
starts:

    Ladybird Dev Shell
       Source:  94a55b0e (2026-07-18)
       nixpkgs: 8f0500b9
       vcpkg:   e9a23531
       flake:   a7676e8f

The `flake` line is the full snapshot hash: `nix develop
github:Sm00shed/lbenv/<flake>` reproduces this exact environment —
toolchain, dependencies, overrides, and source. It also appears as the
`Reproduce:` line further down the banner.

`lbenv list`
  Show all tested versions from `versions.json`, including the flake revision
  each entry freezes.

`lbenv use <key|hash>`
  Re-enter the shell on a tested version. Given a tracked key (from `lbenv list`),
  this freezes the *whole* environment bit-identically: the recorded flake
  revision — toolchain, dependencies, and overrides — plus the exact Ladybird
  source and nixpkgs, reproducible on any machine. Given a bare commit hash
  (untracked), only the Ladybird source is overridden on top of the current
  flake.

`lbenv new`
  Re-enter the shell on the current upstream HEAD. Untested until confirmed.

When filing a bug, include the source hash printed at startup.

For a fully frozen environment use a tracked key with `lbenv use` (above), or pin
the flake reference directly by appending its commit hash:

```bash
nix develop github:Sm00shed/lbenv/<commit-hash>
```

Both freeze everything: a flake commit pins its own `flake.lock` (nixpkgs, and
with it cmake, ninja, clang, and every library) together with the overrides, so
the environment is bit-identical no matter when it is entered.

`lbenv use` and `lbenv list` read `versions.json` from a local clone of this flake
next to the Ladybird source when present:

    ~/ladybird/
    ~/lbenv/

Point `lbenv` at it with `LADYBIRD_FLAKE_DIR=~/lbenv` if it lives
elsewhere; otherwise the published flake on GitHub is used.

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
- **angle** is used on Linux for the GPU backend. It is built with the Clang 20
  standard environment because Clang 21 hits an internal compiler error while
  parsing a nested union type in ANGLE's Vulkan helpers.
- **mimalloc** is pinned to 2.2.7. Ladybird targets the mimalloc 2.x series;
  the nixpkgs default is a 3.x release, which is incompatible.
- **libtommath** is patched so that `mp_set_double` is compiled in. Apple Clang
  does not define `__STDC_IEC_559__` even on x86_64, which is IEEE-754
  compliant, so the function would otherwise be dropped. The patch forces the
  guard on.

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

## Known upstream issues

Two Ladybird bugs surface on macOS and are worked around by the shell. Both are
reported upstream.

- A deprecated Core Video call sits outside its diagnostic-suppression block in
  `VSyncScheduler.cpp`. The shell adds `-Wno-deprecated-declarations`.
  <https://github.com/LadybirdBrowser/ladybird/issues/10657>
- A lambda in `TabController.mm` has no explicit return type. On x86_64 macOS,
  `BOOL` is a signed char, so return-type deduction cannot reconcile `bool` and
  `BOOL`. This is a hard error that no warning flag suppresses, so the shell
  patches in an explicit `-> bool`.
  <https://github.com/LadybirdBrowser/ladybird/issues/10658>

## Platform notes

On Linux the environment uses the standard `nixos-26.05` nixpkgs, so all inputs
come from the binary cache with no local rebuilds. The Linux-only inputs (Qt,
Vulkan, PulseAudio, libdrm, glslang) are present in the shell, but not all code
paths that use them have been exercised.

On macOS the environment also uses the standard `nixos-26.05` nixpkgs, so the
dependencies come from the binary cache. Ladybird itself references a macOS 15
API (`strchrnul`, `API_AVAILABLE(15.4)`), so it needs apple-sdk_15 and a
deployment target of 15.4 or later.

Rather than a nixpkgs fork, the dev shell adds `apple-sdk_15` and
`darwinMinVersionHook "15.4"` as `buildInputs` and exports `SDKROOT` at
`apple-sdk_15.sdkroot`. Only Ladybird compiles against SDK 15; the dependencies
stay on the cached default SDK, so there are no local rebuilds and no fork to
maintain. The deployment target is pinned to 15.4, so the binary runs on
macOS 15.4 or later.

The GPU Compositor's ANGLE libraries (libEGL/libGLESv2) live in the Nix store,
reached at runtime via `DYLD_FALLBACK_LIBRARY_PATH`. The fallback path is used
deliberately instead of `DYLD_LIBRARY_PATH`: the latter would take precedence
over a library's install name and inject the Nix libpng into Apple system tools
(iconutil, ImageIO), crashing the PNG plugin. The fallback path is consulted
only when a library is not resolved normally, so Apple's own libraries keep
priority.

## Acknowledgements

This environment started as the Ladybird shell from
nix-community/nix-environments (MIT). It has since been rewritten,
but the original made it possible. Thanks to its authors.

Original: https://github.com/nix-community/nix-environments/tree/master/envs/ladybird

## License

GPL-2.0, see LICENSE.
Originally derived from nix-community/nix-environments (MIT), see LICENSE.MIT.
