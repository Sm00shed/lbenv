# SPDX-License-Identifier: GPL-2.0-only
{
  description = "Ladybird browser development environment";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";

    flake-utils.url = "github:numtide/flake-utils";

    # lbenv overrides this at runtime
    ladybird = {
      url = "github:LadybirdBrowser/ladybird/94a55b0e9045b1e96307c5e4f0242309c589ecd4";
      flake = false;
    };
  };

  outputs = { self, nixpkgs, flake-utils, ladybird }:
    flake-utils.lib.eachSystem [ "x86_64-linux" "aarch64-linux" ] (system:
      let
        pkgs = import nixpkgs {
          inherit system;
          config = { };
          overlays = [ ];
        };

        llvm = pkgs.llvmPackages_21;

        mimalloc227 = pkgs.mimalloc.overrideAttrs (_: rec {
          version = "2.2.7";
          src = pkgs.fetchFromGitHub {
            owner = "microsoft";
            repo  = "mimalloc";
            rev   = "v${version}";
            hash  = "sha256-z9qMOTcGkURblZChXDGfQ58hrql52lG6EE1NQmxxuj0=";
          };
          patches = [];
        });

        wuffsSinglefile = pkgs.stdenv.mkDerivation {
          name = "wuffs-singlefile-0.3.4";
          src  = pkgs.fetchFromGitHub {
            owner = "google";
            repo  = "wuffs-mirror-release-c";
            rev   = "v0.3.4";
            hash  = "sha256-V7inWJqH7Q4Ac/ZB//7XHrpgfAYUPBxWBerBem6Q/Kk=";
          };
          dontBuild    = true;
          installPhase = ''
            mkdir -p $out/include/wuffs
            install -m444 release/c/wuffs-v0.3.c $out/include/wuffs/wuffs-v0.3.c
          '';
        };

        hstsPreload = pkgs.fetchurl {
          url  = "https://raw.githubusercontent.com/chromium/chromium/main/net/http/transport_security_state_static.json";
          hash = "sha256-YuiotSk0Lf3IHz/UjgCmU/brdB1lszob6DN4DXyjiWU=";
        };

        ladybirdSkia = pkgs.skia.overrideAttrs (prev: {
          version = "148-unstable-2026-06-12";
          src = pkgs.fetchgit {
            url  = "https://skia.googlesource.com/skia.git";
            rev  = "46f2e16555cac1211f4087cf24728fd741ac6495";
            hash = "sha256-vpd/W0C8zT+wzShdJYdd18GmNp/TklqF7bGZxfIaDDM=";
          };
          gnFlags = prev.gnFlags ++ [
            "extra_cflags+=[\"-DSKCMS_API=[[gnu::visibility(\\\"default\\\")]]\"]"
          ];
          patches = [];
        });

        ffmpegPinned = pkgs.ffmpeg_7;

        opensslPinned = pkgs.openssl_3_5;

        sqlitePinned = pkgs.sqlite.overrideAttrs (_: rec {
          version = "3.52.0";
          src = pkgs.fetchurl {
            url  = "https://sqlite.org/2026/sqlite-src-3520000.zip";
            hash = "sha256-ZSqYyoM+1jiAmlK+wiWn83eZ9xqZV3j5zLaK0DvR/BE=";
          };
        });

        libjpegTurboPinned = pkgs.libjpeg_turbo;

        libpngPinned = pkgs.libpng;

        zlibPinned = pkgs.zlib;

        harfbuzzPinned = pkgs.harfbuzz.overrideAttrs (prev: rec {
          version = "10.2.0";
          src = pkgs.fetchurl {
            url  = "https://github.com/harfbuzz/harfbuzz/releases/download/${version}/harfbuzz-${version}.tar.xz";
            hash = "sha256-Yg40aPrsLqhoXTLEalhGm4UO9jBAs1Zc3gWVmCW0gic=";
          };
          patches = [];
          mesonFlags = builtins.filter (f: !(pkgs.lib.hasInfix "raster" f)) prev.mesonFlags;
        });

        libxml2Pinned = pkgs.libxml2.overrideAttrs (_: rec {
          version = "2.13.8";
          src = pkgs.fetchurl {
            url  = "mirror://gnome/sources/libxml2/${pkgs.lib.versions.majorMinor version}/libxml2-${version}.tar.xz";
            hash = "sha256-J3KUyzMRmrcbK8gfL0Rem8lDW4k60VuyzSsOhZoO6Eo=";
          };
          patches = [];
        });

        freetypePinned = pkgs.freetype;

        # angle on clang 20
        ladybirdAngle = pkgs.angle.override { stdenv = pkgs.llvmPackages_20.stdenv; };

        libPkgs = with pkgs; [
          curlFull ffmpegPinned.lib fontconfig.lib libavif ladybirdAngle libjxl libwebp libxcrypt
          opensslPinned sdl3 brotli.lib libhwy lcms2 zstd libidn2 woff2.lib icu78
          mimalloc227 harfbuzzPinned libjpegTurboPinned libpngPinned libxml2Pinned sqlitePinned zlibPinned freetypePinned ladybirdSkia
          fmt simdutf simdjson libtommath libpsl libedit cpptrace
          libdrm vulkan-loader vulkan-memory-allocator
          libGL libpulseaudio qt6Packages.qtbase qt6Packages.qtmultimedia qt6Packages.qtpositioning qt6Packages.qtwayland
          stdenv.cc.cc.lib
        ];

        cmakePrefixParts = with pkgs; [
          icu78.dev harfbuzzPinned.dev opensslPinned.dev curlFull.dev sdl3.dev fmt.dev
          fontconfig.dev libavif.dev libjxl.dev libpngPinned.dev libxml2Pinned.dev zlibPinned.dev
          woff2.dev ffmpegPinned.dev libedit.dev libpsl.dev libjpegTurboPinned.dev sqlitePinned.dev
          freetypePinned.dev
          mimalloc227.dev
          # symbolized stacktraces
          cpptrace
          libtommath
          vulkan-loader.dev vulkan-headers vulkan-memory-allocator
          libpulseaudio.dev libGL.dev
          qt6Packages.qtbase qt6Packages.qtmultimedia qt6Packages.qtpositioning qt6Packages.qtwayland
        ];

        cmakePrefixPath = pkgs.lib.concatStringsSep ":" (map toString cmakePrefixParts);

        nixpkgsSrc = nixpkgs;


        # lbenv (newest) | lbenv switch [key|hash] | lbenv new [hash]
        lbenv = pkgs.writeShellScriptBin "lbenv" ''
          set -euo pipefail
          export PATH="${pkgs.lib.makeBinPath (with pkgs; [ jq curl git fzf coreutils ])}:$PATH"

          REPO="LadybirdBrowser/ladybird"
          FLAKE_REPO="Sm00shed/lbenv"

          # local clone if present
          FLAKE_DIR="''${LADYBIRD_FLAKE_DIR:-$PWD/../lbenv}"
          if [ -d "$FLAKE_DIR/.git" ]; then
            FLAKE_REF="$FLAKE_DIR"; LOCAL=1
          else
            FLAKE_REF="github:$FLAKE_REPO"; LOCAL=0
          fi

          versions() {
            if [ "$LOCAL" = 1 ]; then
              cat "$FLAKE_DIR/versions.json"
            else
              curl -fsSL "https://raw.githubusercontent.com/$FLAKE_REPO/main/versions.json"
            fi
          }

          # flake rev for the banner
          flake_rev() {
            if [ "$LOCAL" = 1 ]; then
              git -C "$FLAKE_DIR" rev-parse HEAD 2>/dev/null || true
            else
              curl -fsSL "https://api.github.com/repos/$FLAKE_REPO/commits/HEAD" \
                | jq -r '.sha // empty' 2>/dev/null || true
            fi
          }

          wt_root()  { echo "''${LBENV_WT:-$HOME/lbenv-wt}"; }
          main_src() { echo "''${LADYBIRD_SRC:-$HOME/ladybird}"; }

          # worktree for a ladybird rev, one dir per hash; prints its path
          ensure_worktree() {
            local lh="$1" src dir
            src=$(main_src); dir="$(wt_root)/$lh"
            [ -d "$src/.git" ] || git clone --quiet "https://github.com/$REPO" "$src" >&2
            mkdir -p "$(wt_root)"
            if [ ! -e "$dir" ]; then
              git -C "$src" cat-file -e "$lh^{commit}" 2>/dev/null \
                || git -C "$src" fetch --quiet origin "$lh" 2>/dev/null \
                || git -C "$src" fetch --quiet origin || true
              git -C "$src" worktree add --quiet --detach "$dir" "$lh" >&2
            fi
            echo "$dir"
          }

          override() {
            local dir; dir=$(ensure_worktree "$1")
            export LBENV_FLAKE_REV="$(flake_rev)"
            export LBENV_LADYBIRD="$1" LBENV_TITLE="(not recorded)" LBENV_WHEN="" LBENV_VCPKG="-"
            cd "$dir" || exit 1
            exec nix develop "$FLAKE_REF" --quiet
          }

          # enter one versions.json entry, in its worktree
          freeze_entry() {
            local entry="$1" lh fh dir
            lh=$(printf '%s' "$entry" | jq -r '.ladybird')
            fh=$(printf '%s' "$entry" | jq -r '.flake // empty')
            export LBENV_LADYBIRD="$lh"
            export LBENV_TITLE="$(printf '%s' "$entry" | jq -r '.title // "(no title)"')"
            export LBENV_VCPKG="$(printf '%s' "$entry" | jq -r '.vcpkg // "-"')"
            export LBENV_WHEN="$(printf '%s' "$entry" | jq -r '(.date // "") + (if (.time // "") == "" then "" else " " + .time end)')"
            dir=$(ensure_worktree "$lh")
            cd "$dir" || exit 1
            if [ -n "$fh" ]; then
              export LBENV_FLAKE_REV="$fh"
              exec nix develop "github:$FLAKE_REPO/$fh" --quiet
            else
              echo "warning: no recorded flake rev — floating, not frozen" >&2
              export LBENV_FLAKE_REV="$(flake_rev)"
              exec nix develop "$FLAKE_REF" --quiet
            fi
          }

          case "''${1:-}" in
            "")
              # newest recorded
              entry=$(versions | jq -rc 'to_entries | last | (.value + {date: (.key[0:10])})')
              [ -n "$entry" ] && [ "$entry" != "null" ] \
                || { echo "versions.json has no entries" >&2; exit 1; }
              freeze_entry "$entry"
              ;;
            new)
              hash="''${2:-}"
              if [ -z "$hash" ]; then
                hash=$(curl -fsSL "https://api.github.com/repos/$REPO/commits/HEAD" | jq -r .sha)
                echo "upstream HEAD ''${hash:0:8} — floating placeholder, not recorded"
              else
                echo "''${hash:0:8} — floating placeholder, not recorded"
              fi
              override "$hash"
              ;;
            switch)
              v=$(versions)
              key="''${2:-}"

              # no arg: fzf block picker, or plain blocks without fzf
              if [ -z "$key" ]; then
                if command -v fzf >/dev/null 2>&1; then
                  key=$(printf '%s' "$v" | jq -j --arg cur "''${LBENV_LADYBIRD:-}" '
                      to_entries | reverse | .[]
                      | (if .value.ladybird == $cur then "* " else "  " end)
                        + (.value.title // "(no title)") + "\n"
                      + "    " + (.key[0:10]) + " " + (.value.time // "") + "\n"
                      + "    " + (.value.ladybird) + "\u0000"' \
                    | fzf --read0 --gap --highlight-line --height=90% --prompt='ladybird> ' \
                    | grep -oE '[0-9a-f]{40}' | head -n1 || true)
                  [ -n "$key" ] || { echo "aborted" >&2; exit 1; }
                else
                  printf '%s' "$v" | jq -r --arg cur "''${LBENV_LADYBIRD:-}" '
                      to_entries | reverse | .[]
                      | (if .value.ladybird == $cur then "* " else "  " end)
                        + (.value.title // "(no title)") + "\n"
                      + "    " + (.key[0:10]) + " " + (.value.time // "") + "\n"
                      + "    " + (.value.ladybird) + "\n"'
                  echo "usage: lbenv switch <key|hash>" >&2
                  exit 1
                fi
              fi

              # resolve by key or hash
              entry=$(printf '%s' "$v" | jq -rc --arg k "$key" '.[$k] as $e | if $e then $e + {date: ($k[0:10])} else empty end')
              if [ -z "$entry" ]; then
                entry=$(printf '%s' "$v" | jq -rc --arg k "$key" \
                  'to_entries[] | select(.value.ladybird | startswith($k)) | (.value + {date: (.key[0:10])})' \
                  | head -n1)
              fi
              [ -n "$entry" ] || { echo "not in versions.json: $key" >&2; exit 1; }
              freeze_entry "$entry"
              ;;
            *)
              echo "usage:" >&2
              echo "  lbenv                  newest recorded version" >&2
              echo "  lbenv switch [k|hash]  pick a version (no arg: picker)" >&2
              echo "  lbenv new [hash]       floating, unrecorded commit" >&2
              exit 1
              ;;
          esac
        '';

      in {
        devShells.default = pkgs.mkShell {
          name = "ladybird-dev";

          NIX_ENFORCE_NO_NATIVE = "0";

          packages = libPkgs
            ++ [ llvm.clang llvm.lld lbenv pkgs.libtommath ]
            ++ (with pkgs; [
              cmake ninja pkg-config python3 perl cargo rustc ccache git coreutils
              curlFull.dev fast-float ffmpegPinned.dev fmt fmt.dev fontconfig.dev
              libavif.dev libjxl.dev opensslPinned.dev sdl3.dev simdutf brotli.dev lcms2.dev
              zstd.dev libidn2.dev woff2.dev icu78.dev simdjson mimalloc227.dev
              wuffsSinglefile cpptrace libedit libedit.dev libpsl libpsl.dev harfbuzzPinned.dev libjpegTurboPinned.dev
              libpngPinned.dev libxml2Pinned.dev sqlitePinned.dev zlibPinned.dev freetypePinned.dev
              unicode-character-database unicode-emoji unicode-idna publicsuffix-list
              dejavu_fonts liberation_ttf cacert
              patchelf glslang
              libdrm.dev vulkan-headers vulkan-loader.dev
              libGL.dev libpulseaudio.dev qt6Packages.qtmultimedia qt6Packages.qtpositioning qt6Packages.qtwayland
            ]);

          shellHook = ''
            export CC=${llvm.clang}/bin/clang
            export CXX=${llvm.clang}/bin/clang++
            export CMAKE_BUILD_TYPE=Release
            export CMAKE_PREFIX_PATH="${cmakePrefixPath}''${CMAKE_PREFIX_PATH:+:$CMAKE_PREFIX_PATH}"
            export ICU_ROOT=${pkgs.icu78.dev}
            export PKG_CONFIG_PATH="${ladybirdSkia}/lib/pkgconfig:${ladybirdAngle}/lib/pkgconfig''${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}"
            # fontconfig conf.d
            export FONTCONFIG_FILE=${pkgs.runCommand "ladybird-fonts.conf" { } ''
              substitute ${pkgs.makeFontsConf { fontDirectories = with pkgs; [ dejavu_fonts liberation_ttf ]; }} $out \
                --replace-fail '/etc/fonts/conf.d' '${pkgs.fontconfig.out}/etc/fonts/conf.d'
            ''}
            export CLANGD_PATH=${llvm.clang-unwrapped}/bin/clangd
            export SSL_CERT_FILE=${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt
            _sel=0; [ -n "''${LBENV_FLAKE_REV:-}" ] && _sel=1

            # CA cert into the tree
            if [ -f "$PWD/Meta/CMake/check_for_dependencies.cmake" ]; then
              mkdir -p "$PWD/Caches/CACERT"
              cp --no-preserve=mode ${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt \
                 "$PWD/Caches/CACERT/ca-bundle.crt"
            fi
            LADYBIRD_SRC_DIR="$PWD"
            export LADYBIRD_CERTIFICATE="''${LADYBIRD_CERTIFICATE:-$PWD/Caches/CACERT/ca-bundle.crt}"
            unset VCPKG_ROOT
            unset CMAKE_TOOLCHAIN_FILE

            export LD_LIBRARY_PATH="${pkgs.lib.makeLibraryPath libPkgs}''${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
            export CMAKE_EXE_LINKER_FLAGS="-lGL -lfontconfig''${CMAKE_EXE_LINKER_FLAGS:+ $CMAKE_EXE_LINKER_FLAGS}"
            export CMAKE_SHARED_LINKER_FLAGS="-lGL -lfontconfig''${CMAKE_SHARED_LINKER_FLAGS:+ $CMAKE_SHARED_LINKER_FLAGS}"
            # build dir inside the per-hash worktree
            export LADYBIRD_BUILD_DIR="Build"
            Ladybird() { "$LADYBIRD_SRC_DIR/$LADYBIRD_BUILD_DIR/bin/Ladybird" --certificate="$LADYBIRD_CERTIFICATE" "$@"; }

            ulimit -s unlimited
            export RUST_MIN_STACK=16777216

            if [ -f "$PWD/Meta/CMake/check_for_dependencies.cmake" ]; then
              if [ ! -f "$PWD/Caches/HSTSPreload/transport_security_state_static.json" ]; then
                mkdir -p "$PWD/Caches/HSTSPreload"
                cp --no-preserve=mode ${hstsPreload} "$PWD/Caches/HSTSPreload/transport_security_state_static.json"
              fi
              if [ ! -f "$PWD/Caches/UCD/version.txt" ]; then
                mkdir -p "$PWD/Caches/UCD"
                cp --no-preserve=mode -r ${pkgs.unicode-character-database}/share/unicode/. "$PWD/Caches/UCD/"
                cp --no-preserve=mode ${pkgs.unicode-emoji}/share/unicode/emoji/emoji-test.txt "$PWD/Caches/UCD/"
                cp --no-preserve=mode ${pkgs.unicode-idna}/share/unicode/idna/IdnaMappingTable.txt "$PWD/Caches/UCD/"
                printf '%s' '${pkgs.unicode-character-database.version}' > "$PWD/Caches/UCD/version.txt"
              fi
              if [ ! -f "$PWD/Caches/PublicSuffix/public_suffix_list.dat" ]; then
                mkdir -p "$PWD/Caches/PublicSuffix"
                cp --no-preserve=mode ${pkgs.publicsuffix-list}/share/publicsuffix/public_suffix_list.dat \
                   "$PWD/Caches/PublicSuffix/"
              fi
            fi

            echo ""
            echo "Ladybird Dev Shell"
            echo ""
            if [ "$_sel" = 1 ]; then
              echo "   Commit"
              echo "     ''${LBENV_TITLE:-(not recorded)}"
              echo "     $LBENV_WHEN"
              echo "     $LBENV_LADYBIRD"
              echo ""
              echo "   Environment"
              echo "     nixpkgs  ${builtins.substring 0 8 nixpkgsSrc.rev}"
              echo "     vcpkg    ''${LBENV_VCPKG:--}"
              _flakeRev="''${LBENV_FLAKE_REV:-${self.rev or self.dirtyRev or ""}}"
              [ -n "$_flakeRev" ] || _flakeRev="unknown"
              echo "     flake    ''${_flakeRev:0:8}"
              echo "     dir      $PWD"
              echo ""
              echo "   Reproduce: lbenv switch $LBENV_LADYBIRD"
              echo "   Build:     cmake -B \"\$LADYBIRD_BUILD_DIR\" -GNinja … && ninja -C \"\$LADYBIRD_BUILD_DIR\""
            else
              echo "   no Ladybird version selected"
              echo "     lbenv               newest recorded"
              echo "     lbenv switch <key>  pick a version"
            fi
            echo ""
            echo "   lbenv (newest) | lbenv switch [key|hash] | lbenv new [hash]"
            echo ""
          '';
        };
      }
    );
}
