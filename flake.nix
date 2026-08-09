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

    # version database: one <ladybird-sha>.toml per commit, plus `latest`
    lbenv-db = {
      url = "github:Sm00shed/lbenv-db";
      flake = false;
    };
  };

  outputs = { self, nixpkgs, flake-utils, ladybird, lbenv-db }:
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

        # pin to a concrete chromium commit; 'main' is a moving ref and drifts
        # away from the fixed hash, breaking the build on any cache-cold machine
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

        opensslPinned = pkgs.openssl_3_5;

        sqlitePinned = pkgs.sqlite.overrideAttrs (_: rec {
          version = "3.52.0";
          src = pkgs.fetchurl {
            url  = "https://sqlite.org/2026/sqlite-src-3520000.zip";
            hash = "sha256-ZSqYyoM+1jiAmlK+wiWn83eZ9xqZV3j5zLaK0DvR/BE=";
          };
          # nixpkgs' sqlite patches target the packaged version; they may not
          # apply to 3.52.0. Clear them, like the other version-bumped pins.
          patches = [];
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
          # drop the exact flag, not a fragile hasInfix "raster"; throw if it is
          # gone (renamed upstream) instead of silently filtering nothing
          mesonFlags =
            let
              drop = "-Draster=disabled";
              kept = builtins.filter (f: f != drop) prev.mesonFlags;
            in if kept == prev.mesonFlags
               then throw "harfbuzz: expected meson flag '${drop}' not found — renamed upstream?"
               else kept;
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

        libavifPinned = pkgs.libavif.overrideAttrs (_: rec {
          version = "1.4.1";
          src = pkgs.fetchFromGitHub {
            owner = "AOMediaCodec";
            repo  = "libavif";
            rev   = "v${version}";
            hash  = "sha256-035SoxHfN121mp3LGwGykReCi1WJbl2/nZH8c/VwABU=";
          };
        });

        # angle on clang 20
        ladybirdAngle = pkgs.angle.override { stdenv = pkgs.llvmPackages_20.stdenv; };

        libPkgs = with pkgs; [
          curlFull ffmpegPinned.lib fontconfig.lib libavifPinned ladybirdAngle libjxl libwebp libxcrypt
          opensslPinned sdl3Pinned brotli.lib libhwy lcms2 zstd libidn2 woff2.lib icu78
          mimalloc227 harfbuzzPinned libjpegTurboPinned libpngPinned libxml2Pinned sqlitePinned zlibPinned freetypePinned ladybirdSkia
          fmt simdutf simdjson libtommath libpsl libedit cpptrace
          libdrm vulkan-loader vulkan-memory-allocator
          libGL libpulseaudio qt6Packages.qtbase qt6Packages.qtmultimedia qt6Packages.qtpositioning qt6Packages.qtwayland
          stdenv.cc.cc.lib
        ];

        cmakePrefixParts = with pkgs; [
          icu78.dev harfbuzzPinned.dev opensslPinned.dev curlFull.dev sdl3Pinned.dev fmt.dev
          fontconfig.dev libavifPinned.dev libjxl.dev libpngPinned.dev libxml2Pinned.dev zlibPinned.dev
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


        # lbenv: bash logic lives in ./scripts/lbenv.sh (plain, shellcheck-able).
        # @BINPATH@ and @DB_DIR@ are substituted in at build time.
        lbenv = pkgs.writeShellScriptBin "lbenv" (
          builtins.replaceStrings
            [ "@BINPATH@" "@DB_DIR@" ]
            [ "${pkgs.lib.makeBinPath (with pkgs; [ curl git coreutils ])}" "${lbenv-db}" ]
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
              curlFull.dev fast-float ffmpegPinned.dev fmt.dev fontconfig.dev
              libavifPinned.dev libjxl.dev opensslPinned.dev sdl3Pinned.dev simdutf brotli.dev lcms2.dev
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

            LADYBIRD_SRC_DIR="$PWD"
            # CA cert into the tree — only exists inside a ladybird worktree, so
            # export the path only when we actually created it (else it would
            # point at a non-existent file)
            if [ -f "$PWD/Meta/CMake/check_for_dependencies.cmake" ]; then
              mkdir -p "$PWD/Caches/CACERT"
              cp --no-preserve=mode ${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt \
                 "$PWD/Caches/CACERT/ca-bundle.crt"
              # per-worktree, not an inherited path
              export LADYBIRD_CERTIFICATE="$PWD/Caches/CACERT/ca-bundle.crt"
            fi
            unset VCPKG_ROOT
            unset CMAKE_TOOLCHAIN_FILE

            export CMAKE_EXE_LINKER_FLAGS="-lGL -lfontconfig''${CMAKE_EXE_LINKER_FLAGS:+ $CMAKE_EXE_LINKER_FLAGS}"
            export CMAKE_SHARED_LINKER_FLAGS="-lGL -lfontconfig''${CMAKE_SHARED_LINKER_FLAGS:+ $CMAKE_SHARED_LINKER_FLAGS}"
            # build dir inside the per-hash worktree
            export LADYBIRD_BUILD_DIR="Build"
            # scope LD_LIBRARY_PATH to running Ladybird only; setting it shell-wide
            # makes unrelated tools pick up these libs
            Ladybird() {
              local args=()
              [ -f "''${LADYBIRD_CERTIFICATE:-}" ] && args+=(--certificate="$LADYBIRD_CERTIFICATE")
              LD_LIBRARY_PATH="${pkgs.lib.makeLibraryPath libPkgs}''${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}" \
                "$LADYBIRD_SRC_DIR/$LADYBIRD_BUILD_DIR/bin/Ladybird" "''${args[@]}" "$@"
            }

            ulimit -s unlimited
            export RUST_MIN_STACK=16777216

            if [ -f "$PWD/Meta/CMake/check_for_dependencies.cmake" ]; then
              if [ ! -f "$PWD/Caches/HSTSPreload/transport_security_state_static.json" ]; then
                mkdir -p "$PWD/Caches/HSTSPreload"
                cp --no-preserve=mode ${hstsPreload} "$PWD/Caches/HSTSPreload/transport_security_state_static.json"
              fi
              # refill on version mismatch, not just when missing — otherwise a
              # nixpkgs bump leaves stale Unicode data forever
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
