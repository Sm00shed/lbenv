# SPDX-License-Identifier: GPL-2.0-only
{
  description = "Ladybird browser development environment";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";

    # libs where 26.05 lags Ladybird's vcpkg pins
    nixpkgs-unstable.url = "github:NixOS/nixpkgs/nixpkgs-unstable";

    flake-utils.url = "github:numtide/flake-utils";

    # lbenv overrides this at runtime
    ladybird = {
      url = "github:LadybirdBrowser/ladybird/94a55b0e9045b1e96307c5e4f0242309c589ecd4";
      flake = false;
    };

    # version database: one <ladybird-sha>.toml per commit, plus `latest`
    lbdb = {
      url = "github:Sm00shed/lbdb";
      flake = false;
    };
  };

  outputs = { self, nixpkgs, nixpkgs-unstable, flake-utils, ladybird, lbdb }:
    flake-utils.lib.eachSystem [ "x86_64-linux" "aarch64-linux" ] (system:
      let
        pkgs = import nixpkgs {
          inherit system;
          config = { };
          overlays = [ ];
        };

        # unstable, only for the libs 26.05 is behind on
        pkgsU = import nixpkgs-unstable {
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

        # pin to a concrete chromium commit; 'main' drifts off the fixed hash
        hstsPreload = pkgs.fetchurl {
          url  = "https://raw.githubusercontent.com/chromium/chromium/7be0edc636b0e7b0143e2700ecf5c8af750d09ec/net/http/transport_security_state_static.json";
          hash = "sha256-ObT9lWtjw/V0UGY552pEWJ6KbfF0izB/zJ7v+00IFB8=";
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

        # vcpkg 3.6.3
        opensslPinned = pkgsU.openssl;

        # vcpkg 3.53.3
        sqlitePinned = pkgsU.sqlite;

        # vcpkg 3.2.0, not in nixpkgs yet
        libjpegTurboPinned = pkgs.libjpeg_turbo.overrideAttrs (_: rec {
          version = "3.2.0";
          src = pkgs.fetchFromGitHub {
            owner = "libjpeg-turbo";
            repo  = "libjpeg-turbo";
            rev   = version;
            hash  = "sha256-SPxWCDt9hFQ8uRaaKLkpWp9oPhfcRkDBm5MarTgdmV4=";
          };
        });

        libpngPinned = pkgs.libpng;

        zlibPinned = pkgs.zlib;

        harfbuzzPinned = pkgs.harfbuzz.overrideAttrs (prev: rec {
          version = "10.2.0";
          src = pkgs.fetchurl {
            url  = "https://github.com/harfbuzz/harfbuzz/releases/download/${version}/harfbuzz-${version}.tar.xz";
            hash = "sha256-Yg40aPrsLqhoXTLEalhGm4UO9jBAs1Zc3gWVmCW0gic=";
          };
          patches = [];
          # drop the exact flag; throw if it's gone (renamed upstream)
          mesonFlags =
            let
              drop = "-Draster=disabled";
              kept = builtins.filter (f: f != drop) prev.mesonFlags;
            in if kept == prev.mesonFlags
               then throw "harfbuzz: expected meson flag '${drop}' not found — renamed upstream?"
               else kept;
        });

        # vcpkg 2.15.3
        libxml2Pinned = pkgsU.libxml2;

        freetypePinned = pkgs.freetype;

        # pin to nixos-26.05, no point-bump drift
        sdl3Pinned = pkgs.sdl3.overrideAttrs (_: rec {
          version = "3.4.10";
          src = pkgs.fetchFromGitHub {
            owner = "libsdl-org";
            repo  = "SDL";
            rev   = "refs/tags/release-${version}";
            hash  = "sha256-6Dph2eLiJUmpQzPWe8EuY5LrWhrFwde2f2dwfgCcWNw=";
          };
        });

        # vcpkg 1.4.2
        libavifPinned = pkgsU.libavif;

        # these match the vcpkg pin exactly
        curlPinned = pkgsU.curlFull;                        # 8.21.0
        fmtPinned = pkgsU.fmt;                              # 12.2.0
        libhwyPinned = pkgsU.libhwy;                        # 1.4.0
        fastFloatPinned = pkgsU.fast-float;                 # 8.2.10
        vmaPinned = pkgsU.vulkan-memory-allocator;          # 3.4.0
        # vcpkg 1.4.350, unstable 1.4.357, additive only
        vulkanHeadersPinned = pkgsU.vulkan-headers;

        # angle on clang 20
        ladybirdAngle = pkgs.angle.override { stdenv = pkgs.llvmPackages_20.stdenv; };

        # in-store mesa Vulkan ICDs; HW drivers (radeon/intel/…) and lavapipe (SW)
        mesaIcdDir = "${pkgs.mesa}/share/vulkan/icd.d";
        lavapipeIcd = "${mesaIcdDir}/lvp_icd.${pkgs.stdenv.hostPlatform.parsed.cpu.name}.json";

        libPkgs = with pkgs; [
          curlPinned ffmpegPinned.lib fontconfig.lib libavifPinned ladybirdAngle libjxl libwebp libxcrypt
          opensslPinned sdl3Pinned brotli.lib libhwyPinned lcms2 zstd libidn2 woff2.lib icu78
          mimalloc227 harfbuzzPinned libjpegTurboPinned libpngPinned libxml2Pinned sqlitePinned zlibPinned freetypePinned ladybirdSkia
          fmtPinned simdutf simdjson libtommath libpsl libedit cpptrace
          libdrm vulkan-loader vmaPinned
          libGL libpulseaudio glib libxkbcommon qt6Packages.qtbase qt6Packages.qtmultimedia qt6Packages.qtpositioning qt6Packages.qtwayland
          stdenv.cc.cc.lib
        ];

        cmakePrefixParts = with pkgs; [
          icu78.dev harfbuzzPinned.dev opensslPinned.dev curlPinned.dev sdl3Pinned.dev fmtPinned.dev
          fontconfig.dev libavifPinned.dev libjxl.dev libpngPinned.dev libxml2Pinned.dev zlibPinned.dev
          woff2.dev ffmpegPinned.dev libedit.dev libpsl.dev libjpegTurboPinned.dev sqlitePinned.dev
          freetypePinned.dev
          mimalloc227.dev
          # symbolized stacktraces
          cpptrace
          libtommath
          vulkan-loader.dev vulkanHeadersPinned vmaPinned
          libpulseaudio.dev libGL.dev
          qt6Packages.qtbase qt6Packages.qtmultimedia qt6Packages.qtpositioning qt6Packages.qtwayland
        ];

        cmakePrefixPath = pkgs.lib.concatStringsSep ":" (map toString cmakePrefixParts);

        nixpkgsSrc = nixpkgs;


        # lbenv: bash logic lives in ./scripts/lbenv.sh (plain, shellcheck-able).
        # @BINPATH@ and @DB_DIR@ are substituted in at build time.
        lbenv = pkgs.writeShellScriptBin "lbenv" (
          builtins.replaceStrings
            [ "@BINPATH@" "@DB_DIR@" ]
            [ "${pkgs.lib.makeBinPath (with pkgs; [ curl git coreutils ])}" "${lbdb}" ]
            (builtins.readFile ./scripts/lbenv.sh)
        );

      in {
        devShells.default = pkgs.mkShell {
          name = "lbdev";

          NIX_ENFORCE_NO_NATIVE = "0";

          packages = libPkgs
            ++ [ llvm.clang llvm.lld lbenv ]
            ++ (with pkgs; [
              cmake ninja pkg-config python3 perl cargo rustc ccache git coreutils
              curlPinned.dev fastFloatPinned ffmpegPinned.dev fmtPinned.dev fontconfig.dev
              libavifPinned.dev libjxl.dev opensslPinned.dev sdl3Pinned.dev simdutf brotli.dev lcms2.dev
              zstd.dev libidn2.dev woff2.dev icu78.dev simdjson mimalloc227.dev
              wuffsSinglefile cpptrace libedit libedit.dev libpsl libpsl.dev harfbuzzPinned.dev libjpegTurboPinned.dev
              libpngPinned.dev libxml2Pinned.dev sqlitePinned.dev zlibPinned.dev freetypePinned.dev
              unicode-character-database unicode-emoji unicode-idna publicsuffix-list
              dejavu_fonts liberation_ttf cacert
              patchelf glslang
              libdrm.dev vulkanHeadersPinned vulkan-loader.dev
              libGL.dev libpulseaudio.dev glib.dev sysprof.dev
              qt6Packages.qtmultimedia qt6Packages.qtpositioning qt6Packages.qtwayland
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

            LADYBIRD_SRC_DIR="$PWD"
            # CA cert only exists in a ladybird worktree; export only when created
            if [ -f "$PWD/Meta/CMake/check_for_dependencies.cmake" ]; then
              mkdir -p "$PWD/Caches/CACERT"
              cp --no-preserve=mode ${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt \
                 "$PWD/Caches/CACERT/ca-bundle.crt"
              export LADYBIRD_CERTIFICATE="$PWD/Caches/CACERT/ca-bundle.crt"
            fi
            unset VCPKG_ROOT
            unset CMAKE_TOOLCHAIN_FILE

            # shell-wide: generated host tools link libstdc++ from stdenv at build time
            export LD_LIBRARY_PATH="${pkgs.lib.makeLibraryPath libPkgs}''${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
            export CMAKE_EXE_LINKER_FLAGS="-lGL -lfontconfig''${CMAKE_EXE_LINKER_FLAGS:+ $CMAKE_EXE_LINKER_FLAGS}"
            export CMAKE_SHARED_LINKER_FLAGS="-lGL -lfontconfig''${CMAKE_SHARED_LINKER_FLAGS:+ $CMAKE_SHARED_LINKER_FLAGS}"
            # build dir inside the per-hash worktree
            export LADYBIRD_BUILD_DIR="Build"
            # renderer cpu | lavapipe (SW) | vulkan (HW); default in .lbenv.conf,
            # overridable via LB_RENDER or Ladybird <mode>
            _lb_conf="$LADYBIRD_SRC_DIR/.lbenv.conf"
            _lb_render_default=cpu
            [ -f "$_lb_conf" ] && _lb_render_default=$(sed -n 's/^render[[:space:]]*=[[:space:]]*//p' "$_lb_conf" | tail -n1)
            export LB_RENDER="''${LB_RENDER:-''${_lb_render_default:-cpu}}"
            _lb_render_env() {
              unset VK_DRIVER_FILES VK_ICD_FILENAMES
              LB_RENDER_ARGS=()
              case "$1" in
                lavapipe)
                  export VK_DRIVER_FILES="${lavapipeIcd}" VK_ICD_FILENAMES="${lavapipeIcd}" ;;
                vulkan)
                  # all in-store mesa HW drivers, minus lavapipe; loader picks the present GPU
                  local icds; icds=$(ls "${mesaIcdDir}"/*_icd.*.json 2>/dev/null | grep -v lvp_icd | paste -sd:)
                  [ -n "$icds" ] || { echo "render vulkan: no mesa HW ICDs found" >&2; return 1; }
                  export VK_DRIVER_FILES="$icds" VK_ICD_FILENAMES="$icds" ;;
                nvidia)
                  echo "render nvidia: placeholder — proprietary NVIDIA needs nixVulkanNvidia (impure), not implemented" >&2
                  return 1 ;;
                cpu) LB_RENDER_ARGS=(--force-cpu-painting) ;;
                *) echo "render: unknown mode '$1' (vulkan|nvidia|lavapipe|cpu)" >&2; return 1 ;;
              esac
            }
            render() {   # set the persistent default in .lbenv.conf
              _lb_render_env "$1" || return 1
              export LB_RENDER="$1"
              { grep -v '^render[[:space:]]*=' "$_lb_conf" 2>/dev/null; echo "render = $1"; } \
                > "$_lb_conf.tmp" && mv "$_lb_conf.tmp" "$_lb_conf"
              echo "default renderer: $1"
            }
            Ladybird() {
              local mode="$LB_RENDER"
              case "''${1:-}" in vulkan|nvidia|lavapipe|cpu) mode="$1"; shift ;; esac
              _lb_render_env "$mode" || return 1
              local args=("''${LB_RENDER_ARGS[@]}")
              [ -f "''${LADYBIRD_CERTIFICATE:-}" ] && args+=(--certificate="$LADYBIRD_CERTIFICATE")
              "$LADYBIRD_SRC_DIR/$LADYBIRD_BUILD_DIR/bin/Ladybird" "''${args[@]}" "$@"
            }

            ulimit -s unlimited
            export RUST_MIN_STACK=16777216

            if [ -f "$PWD/Meta/CMake/check_for_dependencies.cmake" ]; then
              if [ ! -f "$PWD/Caches/HSTSPreload/transport_security_state_static.json" ]; then
                mkdir -p "$PWD/Caches/HSTSPreload"
                cp --no-preserve=mode ${hstsPreload} "$PWD/Caches/HSTSPreload/transport_security_state_static.json"
              fi
              # refill when the cached version differs
              if [ "$(cat "$PWD/Caches/UCD/version.txt" 2>/dev/null || true)" != '${pkgs.unicode-character-database.version}' ]; then
                rm -rf "$PWD/Caches/UCD"
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
              _vcpkg="''${LBENV_VCPKG:--}"; echo "     vcpkg    ''${_vcpkg:0:8}"
              _flakeRev="''${LBENV_FLAKE_REV:-${self.rev or self.dirtyRev or ""}}"
              [ -n "$_flakeRev" ] || _flakeRev="unknown"
              echo "     flake    ''${_flakeRev:0:8}"
              echo "     dir      $PWD"
              echo ""
              echo "   Reproduce: lbenv switch $LBENV_LADYBIRD"
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
