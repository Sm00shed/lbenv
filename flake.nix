# SPDX-License-Identifier: GPL-2.0-only
{
  description = "Ladybird browser development environment";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";

    flake-utils.url = "github:numtide/flake-utils";

    # Overridden at runtime by `lbenv new` / `lbenv use` via --override-input.
    ladybird = {
      url = "github:LadybirdBrowser/ladybird/94a55b0e9045b1e96307c5e4f0242309c589ecd4";
      flake = false;
    };
  };

  outputs = { self, nixpkgs, flake-utils, ladybird }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        isDarwin = builtins.match ".*-darwin" system != null;
        isLinux  = builtins.match ".*-linux"  system != null;

        pkgs = import nixpkgs {
          inherit system;
          config = {
            allowDeprecatedx86_64Darwin = true;
          };
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

        # Apple Clang lacks __STDC_IEC_559__, which compiles mp_set_double out.
        libtommath130 = pkgs.libtommath.overrideAttrs (prev: {
          postPatch = (prev.postPatch or "") + ''
            substituteInPlace bn_mp_set_double.c \
              --replace-fail \
                '#if defined(__STDC_IEC_559__) || defined(__GCC_IEC_559)' \
                '#if 1 /* forced: x86_64 is IEEE754 compliant */'
          '';
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

        # nixpkgs' APNG patch is incompatible, keep it off.
        libpngPinned = pkgs.libpng.override { apngSupport = false; };

        zlibPinned = pkgs.zlib;

        harfbuzzPinned = pkgs.harfbuzz.overrideAttrs (prev: rec {
          version = "10.2.0";
          src = pkgs.fetchurl {
            url  = "https://github.com/harfbuzz/harfbuzz/releases/download/${version}/harfbuzz-${version}.tar.xz";
            hash = "sha256-Yg40aPrsLqhoXTLEalhGm4UO9jBAs1Zc3gWVmCW0gic=";
          };
          patches = [];
          # 10.2.0 predates the meson "raster" option.
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

        # Clang 21 ICEs on vk_helpers.h, build angle with Clang 20 on Linux.
        ladybirdAngleBase = if isLinux
          then pkgs.angle.override { stdenv = pkgs.llvmPackages_20.stdenv; }
          else pkgs.angle;
        # Drop the extra libGLESv2 build variants from angle.pc; each carries its
        # own ANGLESwapCGLLayer copy and objc warns about the duplicate class.
        ladybirdAngle = if isDarwin
          then ladybirdAngleBase.overrideAttrs (prev: {
            postFixup = (prev.postFixup or "") + ''
              substituteInPlace "$out/lib/pkgconfig/angle.pc" \
                --replace-fail " -lGLESv2_with_capture" "" \
                --replace-fail " -lGLESv2_vulkan_secondaries" ""
            '';
          })
          else ladybirdAngleBase;

        libPkgs = with pkgs; [
          curlFull ffmpegPinned.lib fontconfig.lib libavif ladybirdAngle libjxl libwebp libxcrypt
          opensslPinned sdl3 brotli.lib libhwy lcms2 zstd libidn2 woff2.lib icu78
          mimalloc227 harfbuzzPinned libjpegTurboPinned libpngPinned libxml2Pinned sqlitePinned zlibPinned freetypePinned ladybirdSkia
          fmt simdutf simdjson libtommath130 libpsl libedit cpptrace
        ] ++ pkgs.lib.optionals isLinux (with pkgs; [
          libdrm vulkan-loader vulkan-memory-allocator
          libGL libpulseaudio qt6Packages.qtbase qt6Packages.qtmultimedia qt6Packages.qtpositioning qt6Packages.qtwayland
          stdenv.cc.cc.lib
        ]);

        cmakePrefixParts = with pkgs; [
          icu78.dev harfbuzzPinned.dev opensslPinned.dev curlFull.dev sdl3.dev fmt.dev
          fontconfig.dev libavif.dev libjxl.dev libpngPinned.dev libxml2Pinned.dev zlibPinned.dev
          woff2.dev ffmpegPinned.dev libedit.dev libpsl.dev libjpegTurboPinned.dev sqlitePinned.dev
          freetypePinned.dev
          mimalloc227.dev
          # enables AK_HAS_CPPTRACE (symbolized stacktraces)
          cpptrace
        ] ++ [ libtommath130 ]
          ++ pkgs.lib.optionals isLinux (with pkgs; [
          vulkan-loader.dev vulkan-headers vulkan-memory-allocator
          libpulseaudio.dev libGL.dev
          qt6Packages.qtbase qt6Packages.qtmultimedia qt6Packages.qtpositioning qt6Packages.qtwayland
        ]);

        cmakePrefixPath = pkgs.lib.concatStringsSep ":" (map toString cmakePrefixParts);

        nixpkgsSrc = nixpkgs;

        versions    = builtins.fromJSON (builtins.readFile ./versions.json);
        ladybirdRev = ladybird.rev or "unknown";
        tracked     = pkgs.lib.filterAttrs (_: v: v.ladybird == ladybirdRev) versions;
        ladybirdDate =
          if tracked == {} then "untracked"
          else builtins.head (builtins.attrNames tracked);
        # Informational: vcpkg pin hash recorded by the update workflow.
        ladybirdVcpkg =
          if tracked == {} then "untracked"
          else (builtins.head (builtins.attrValues tracked)).vcpkg or "untracked";

        # lbenv new | lbenv use <key|hash> | lbenv list
        lbenv = pkgs.writeShellScriptBin "lbenv" ''
          set -euo pipefail
          export PATH="${pkgs.lib.makeBinPath (with pkgs; [ jq curl git coreutils ])}:$PATH"

          REPO="LadybirdBrowser/ladybird"
          FLAKE_REPO="Sm00shed/lbenv"

          # prefer a local clone next to the Ladybird source
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

          override() {
            exec nix develop "$FLAKE_REF" \
              --override-input ladybird "github:$REPO/$1"
          }

          case "''${1:-}" in
            new)
              hash=$(curl -fsSL "https://api.github.com/repos/$REPO/commits/HEAD" \
                       | jq -r .sha)
              echo "upstream HEAD is ''${hash:0:8}"
              override "$hash"
              ;;
            use)
              key="''${2:-}"
              [ -n "$key" ] || { echo "usage: lbenv use <key|hash>" >&2; exit 1; }
              v=$(versions)

              # exact key match
              entry=$(printf '%s' "$v" | jq -r --arg k "$key" '.[$k] // empty')

              # partial hash match against ladybird value
              if [ -z "$entry" ]; then
                entry=$(printf '%s' "$v" | jq -rc --arg k "$key" \
                  'to_entries[] | select(.value.ladybird | startswith($k)) | .value' \
                  | head -n1)
              fi

              [ -n "$entry" ] || { echo "not in versions.json: $key" >&2; exit 1; }

              LADYBIRD_HASH=$(printf '%s' "$entry" | jq -r '.ladybird')
              NIXPKGS_REV=$(printf '%s' "$entry"  | jq -r '.nixpkgs')
              FLAKE_REV=$(printf '%s' "$entry"    | jq -r '.flake // empty')

              if [ -n "$FLAKE_REV" ]; then
                # full freeze: pin the flake rev too, only override the source
                echo "using ladybird ''${LADYBIRD_HASH:0:8} + flake ''${FLAKE_REV:0:8} (frozen)"
                exec nix develop "github:$FLAKE_REPO/$FLAKE_REV" \
                  --override-input ladybird "github:$REPO/$LADYBIRD_HASH"
              else
                # no flake rev recorded: not a full freeze
                echo "warning: no flake rev recorded for $key — not a full freeze" >&2
                echo "using ladybird ''${LADYBIRD_HASH:0:8} + nixpkgs ''${NIXPKGS_REV:0:8}"
                exec nix develop "$FLAKE_REF" \
                  --override-input ladybird "github:$REPO/$LADYBIRD_HASH" \
                  --override-input nixpkgs  "github:NixOS/nixpkgs/$NIXPKGS_REV"
              fi
              ;;
            list)
              versions | jq -r 'to_entries[] | "\(.key) \(.value.ladybird) \(.value.nixpkgs) \(.value.vcpkg // "-") \(.value.flake // "-")"' \
                | while read -r k lh nh vh fh; do
                    mark=" "
                    [ "$lh" = "''${LADYBIRD_REV:-}" ] && mark="*"
                    printf ' %s %s  ladybird: %s  nixpkgs: %s  vcpkg: %s  flake: %s\n' \
                      "$mark" "$k" "''${lh:0:8}" "''${nh:0:8}" "$vh" "''${fh:0:8}"
                  done
              ;;
            *)
              echo "usage: lbenv {new | use <key|hash> | list}" >&2
              exit 1
              ;;
          esac
        '';

      in {
        devShells.default = pkgs.mkShell {
          name = "ladybird-dev";

          NIX_ENFORCE_NO_NATIVE = "0";

          packages = libPkgs
            ++ [ llvm.clang llvm.lld ]
            ++ [ lbenv ]
            ++ [ libtommath130 ]
            ++ (with pkgs; [
              cmake ninja pkg-config python3 perl cargo rustc ccache git coreutils
              curlFull.dev fast-float ffmpegPinned.dev fmt fmt.dev fontconfig.dev
              libavif.dev libjxl.dev opensslPinned.dev sdl3.dev simdutf brotli.dev lcms2.dev
              zstd.dev libidn2.dev woff2.dev icu78.dev simdjson mimalloc227.dev
              wuffsSinglefile cpptrace libedit libedit.dev libpsl libpsl.dev harfbuzzPinned.dev libjpegTurboPinned.dev
              libpngPinned.dev libxml2Pinned.dev sqlitePinned.dev zlibPinned.dev freetypePinned.dev
              unicode-character-database unicode-emoji unicode-idna publicsuffix-list
              dejavu_fonts liberation_ttf cacert
            ])
            ++ pkgs.lib.optionals isLinux (with pkgs; [
              patchelf
              # use_linker.cmake passes -fuse-ld=lld on Linux
              llvm.lld
              libdrm.dev vulkan-headers vulkan-loader.dev glslang
              libGL.dev libpulseaudio.dev qt6Packages.qtmultimedia qt6Packages.qtpositioning qt6Packages.qtwayland
            ]);

          # SDK 15 as buildInputs (target role) so only Ladybird itself compiles
          # against it; strchrnul needs deployment target 15.4.
          buildInputs = pkgs.lib.optionals isDarwin [
            pkgs.apple-sdk_15
            (pkgs.darwinMinVersionHook "15.4")
          ];

          shellHook = ''
            export LADYBIRD_REV=${ladybirdRev}
            export CC=${llvm.clang}/bin/clang
            export CXX=${llvm.clang}/bin/clang++
            export CMAKE_BUILD_TYPE=Release
            export CMAKE_PREFIX_PATH="${cmakePrefixPath}''${CMAKE_PREFIX_PATH:+:$CMAKE_PREFIX_PATH}"
            export ICU_ROOT=${pkgs.icu78.dev}
            export PKG_CONFIG_PATH="${ladybirdSkia}/lib/pkgconfig:${ladybirdAngle}/lib/pkgconfig''${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}"
            # VSyncScheduler.cpp deprecation, reported upstream (#10657)
            export CXXFLAGS="-Wno-deprecated-declarations''${CXXFLAGS:+ $CXXFLAGS}"
            # point the fontconfig include at the version-matched nix conf.d
            export FONTCONFIG_FILE=${pkgs.runCommand "ladybird-fonts.conf" { } ''
              substitute ${pkgs.makeFontsConf { fontDirectories = with pkgs; [ dejavu_fonts liberation_ttf ]; }} $out \
                --replace-fail '/etc/fonts/conf.d' '${pkgs.fontconfig.out}/etc/fonts/conf.d'
            ''}
            export CLANGD_PATH=${llvm.clang-unwrapped}/bin/clangd
            export SSL_CERT_FILE=${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt
            # Landlock blocks direct store paths for RequestServer, copy the cert
            if [ -f "$PWD/Meta/CMake/check_for_dependencies.cmake" ]; then
              mkdir -p "$PWD/Caches/CACERT"
              cp --no-preserve=mode ${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt \
                 "$PWD/Caches/CACERT/ca-bundle.crt"
            fi
            # apply tracked source patches (see patches/), skip if already applied
            if [ -f "$PWD/Meta/CMake/check_for_dependencies.cmake" ]; then
              PATCHES_DIR="${toString ./patches}"
              for p in "$PATCHES_DIR"/*.patch; do
                [ -f "$p" ] || continue
                if git -C "$PWD" apply --check "$p" 2>/dev/null; then
                  git -C "$PWD" apply "$p"
                  echo "applied: $(basename $p)"
                fi
              done
            fi
            LADYBIRD_SRC_DIR="$PWD"
            export LADYBIRD_CERTIFICATE="''${LADYBIRD_CERTIFICATE:-$PWD/Caches/CACERT/ca-bundle.crt}"
            unset VCPKG_ROOT
            unset CMAKE_TOOLCHAIN_FILE

            ${if isDarwin then ''
              # strchrnul is API_AVAILABLE(15.4)
              export MACOSX_DEPLOYMENT_TARGET="15.4"
              export SDKROOT="${pkgs.apple-sdk_15.sdkroot}"
              export LIBRARY_PATH="${pkgs.fontconfig.lib}/lib''${LIBRARY_PATH:+:$LIBRARY_PATH}"
              # x86_64 ld64 does not ad-hoc sign, the codesign step fails without
              # this; must go via LDFLAGS (cmake ignores CMAKE_*_LINKER_FLAGS env)
              export LDFLAGS="-framework CoreText -framework CoreFoundation -framework CoreGraphics -Wl,-adhoc_codesign''${LDFLAGS:+ $LDFLAGS}"
              export NIX_LDFLAGS="-framework CoreText -framework CoreFoundation -framework CoreGraphics''${NIX_LDFLAGS:+ $NIX_LDFLAGS}"
              # fallback path, not DYLD_LIBRARY_PATH: system libpng must keep
              # priority for Apple tools (iconutil/ImageIO crash otherwise)
              export DYLD_FALLBACK_LIBRARY_PATH="${pkgs.lib.makeLibraryPath libPkgs}''${DYLD_FALLBACK_LIBRARY_PATH:+:$DYLD_FALLBACK_LIBRARY_PATH}"
              Ladybird() { "$LADYBIRD_SRC_DIR/Build/release/bin/Ladybird.app/Contents/MacOS/Ladybird" --certificate="$LADYBIRD_CERTIFICATE" "$@"; }
            '' else ''
              export LD_LIBRARY_PATH="${pkgs.lib.makeLibraryPath libPkgs}''${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
              export CMAKE_EXE_LINKER_FLAGS="-lGL -lfontconfig''${CMAKE_EXE_LINKER_FLAGS:+ $CMAKE_EXE_LINKER_FLAGS}"
              export CMAKE_SHARED_LINKER_FLAGS="-lGL -lfontconfig''${CMAKE_SHARED_LINKER_FLAGS:+ $CMAKE_SHARED_LINKER_FLAGS}"
              Ladybird() { "$LADYBIRD_SRC_DIR/Build/release/bin/Ladybird" --certificate="$LADYBIRD_CERTIFICATE" "$@"; }
            ''}

            ${if isLinux then "ulimit -s unlimited" else "ulimit -s hard"}
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
            echo "   Source:  ${builtins.substring 0 8 ladybirdRev} (${builtins.head (pkgs.lib.splitString "_" ladybirdDate)})"
            echo "   nixpkgs: ${builtins.substring 0 8 nixpkgsSrc.rev}"
            echo "   vcpkg:   ${ladybirdVcpkg}"
            echo "   flake:   ${builtins.substring 0 8 (self.rev or self.dirtyRev or "unknown")}"
            echo ""
            echo "   Reproduce: nix develop github:Sm00shed/lbenv/${self.rev or self.dirtyRev or "unknown"}"
            echo ""
            echo "   lbenv new | lbenv use <key|hash> | lbenv list"
            echo ""
          '';
        };
      }
    );
}
