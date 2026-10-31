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

        # unstable, only for the libs 26.05 is behind on.
        # Must use the same glibc as 26.05 (2.42): unstable moved to 2.44 on 2026-09-28,
        # so the lock pins the last 2.42 commit and newer versions come via overrides.
        pkgsU = import nixpkgs-unstable {
          inherit system;
          config = { };
          overlays = [ ];
        };

        llvm = pkgs.llvmPackages_21;

        # ld.lld from the lld package is unwrapped, so nothing adds the pkg-config -L
        # store paths to RUNPATH and the binaries end up with no store path at all.
        # llvm.bintools ships a wrapped ld.lld; clang finds it via -B, not PATH.
        llvmClang = llvm.clang.override { bintools = llvm.bintools; };

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
          name = "wuffs-singlefile-0.3.5";
          src  = pkgs.fetchFromGitHub {
            owner = "google";
            repo  = "wuffs-mirror-release-c";
            rev   = "v0.3.5";
            hash  = "sha256-AMuAaCbNJYnSeac1B1IRSUh4rlE2KphT04/Ak4Pig5M=";
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

        # vcpkg 1.5.4 (drift #10), nixpkgs has 1.5.3
        dav1dPinned = pkgs.dav1d.overrideAttrs (_: rec {
          version = "1.5.4";
          src = pkgs.fetchFromGitHub {
            owner = "videolan";
            repo  = "dav1d";
            rev   = version;
            hash  = "sha256-L3a9MmPWJlxmRa19glWDLvkXHev5oiM5/fxtKOBPMxI=";
          };
        });

        # vcpkg 9.0.2; pinned unstable has 9.0.1. Hash as in later nixpkgs.
        # 9.0.2 already contains the loongarch yuv2plane1 fix (upstream fa97c9f046),
        # so drop nixpkgs' backport of it or the patch fails to apply.
        ffmpegPinned = (pkgsU.ffmpeg_9.override {
          version = "9.0.2";
          hash    = "sha256-/c6cVfMSF6JJxCuJs58bxBlmBXDJ+jbnC4pELB97Qb0=";
          dav1d   = dav1dPinned;
        }).overrideAttrs (prev: {
          patches = builtins.filter
            (p: !(builtins.isAttrs p && pkgs.lib.hasInfix "loongarch-fix-buffer-underflow" (p.name or "")))
            (prev.patches or [ ]);
          # FATE's seek-hls reference does not match the pinned 9.0.2 source
          doCheck = false;
        });

        # upstream pkg-config modules are now *-ladybird; alias our .pc files
        ffmpegLadybirdPc = pkgs.runCommand "ffmpeg-ladybird-pc" { } ''
          mkdir -p $out/lib/pkgconfig
          for m in avcodec avformat avutil swresample; do
            cp ${ffmpegPinned.dev}/lib/pkgconfig/lib$m.pc $out/lib/pkgconfig/lib$m-ladybird.pc
          done
        '';

        # vcpkg 3.6.5; pinned unstable has 3.6.4
        opensslPinned = pkgsU.openssl_3_6.overrideAttrs (_: rec {
          version = "3.6.5";
          src = pkgsU.fetchurl {
            url  = "https://github.com/openssl/openssl/releases/download/openssl-${version}/openssl-${version}.tar.gz";
            hash = "sha256-ohV8KDDv3sN4iTmwDJsGODBtPwu7dtxIMu5QO7OX35g=";
          };
        });

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

        # vcpkg 9.1.1, not in nixpkgs (26.05 9.0.0, unstable 9.2.1)
        simdutfPinned = pkgs.simdutf.overrideAttrs (_: rec {
          version = "9.1.1";
          src = pkgs.fetchFromGitHub {
            owner = "simdutf";
            repo  = "simdutf";
            rev   = "v${version}";
            hash  = "sha256-u0Ur/o2TRLqYisS7xQHBxN/742BzmbElNUeqgEzpw/I=";
          };
        });

        # vcpkg 5.0.2, nixpkgs has 4.6.x
        simdjsonPinned = pkgs.simdjson.overrideAttrs (_: rec {
          version = "5.0.2";
          src = pkgs.fetchFromGitHub {
            owner = "simdjson";
            repo  = "simdjson";
            rev   = "v${version}";
            hash  = "sha256-08ge7ZstT0mJczsFoahzxK3dtEFRdPXpJtJLFj5uVVA=";
          };
        });

        # vcpkg zmij 1.2 (drift #33); only in nixpkgs master so far, same recipe as there
        zmijPinned = pkgs.stdenv.mkDerivation (finalAttrs: {
          pname = "zmij";
          version = "1.2";
          src = pkgs.fetchFromGitHub {
            owner = "vitaut";
            repo  = "zmij";
            rev   = "v${finalAttrs.version}";
            hash  = "sha256-2tppKuONy9IS5IzGJF+4bqAav3aaQMZjiQCMoi5WscE=";
          };
          nativeBuildInputs = [ pkgs.cmake ];
          cmakeFlags = [
            "-DBUILD_SHARED_LIBS=ON"
            "-DZMIJ_TEST=OFF"
            "-DZMIJ_EXAMPLE=OFF"
          ];
        });

        # vcpkg 1.6.59; pinned unstable has 1.6.58. nixpkgs libpng has the apng patch on
        libpngPinned = pkgsU.libpng.overrideAttrs (_: {
          version = "1.6.59";
          src = pkgsU.fetchurl {
            url  = "mirror://sourceforge/libpng/libpng-1.6.59.tar.xz";
            hash = "sha256-2A3So4o3+APLm2rHsUvW503cO2VHgKg4C9+TUj/bQ4k=";
          };
        });

        zlibPinned = pkgs.zlib;

        # qtbase pulls its own harfbuzz; same SONAME, pin collided and crashed
        harfbuzzPinned = pkgs.harfbuzz;

        # vcpkg 2.15.3
        libxml2Pinned = pkgsU.libxml2;

        freetypePinned = pkgs.freetype;

        # vcpkg 3.4.18; pinned unstable has 3.4.16
        # vcpkg leaves libusb off; its event thread breaks WebContent's landlock check
        # SDL's suite checks haptic init, which needs libusb; Ladybird never uses it
        sdl3Pinned = (pkgsU.sdl3.override { libusbSupport = false; }).overrideAttrs (_: {
          version = "3.4.18";
          src = pkgsU.fetchFromGitHub {
            owner = "libsdl-org";
            repo  = "SDL";
            tag   = "release-3.4.18";
            hash  = "sha256-3dP4FJ5OvZI6UPykJpE3hTH6kdW+Nn7gUSf3yiPCobo=";
          };
          doCheck = false;
        });

        # vcpkg 1.4.2
        libavifPinned = pkgsU.libavif.override { dav1d = dav1dPinned; };

        # vcpkg 8.23.0 (drift #9), nixpkgs has 8.22.0
        curlPinned = (pkgsU.curl.override { websocketSupport = true; openssl = opensslPinned; }).overrideAttrs (_: rec {
          version = "8.23.0";
          src = pkgsU.fetchurl {
            urls = [
              "https://curl.se/download/curl-${version}.tar.xz"
              "https://github.com/curl/curl/releases/download/curl-${
                builtins.replaceStrings [ "." ] [ "_" ] version
              }/curl-${version}.tar.xz"
            ];
            hash = "sha256-ja3X0lNqMU+YKtBaZRtxP0Jr99Aswsds/7l5byIY5sU=";
          };
        });

        # vcpkg libdwarf 2.3.3 (drift #16); 26.05 has 2.3.1, unstable 2.3.3
        cpptracePinned = pkgsU.cpptrace;

        # these match the vcpkg pin exactly
        # vcpkg 8.3.1; pinned unstable has 8.3.0
        fastFloatPinned = pkgsU.fast-float.overrideAttrs (_: rec {
          version = "8.3.1";
          src = pkgsU.fetchFromGitHub {
            owner = "fastfloat";
            repo  = "fast_float";
            rev   = "v${version}";
            hash  = "sha256-cVDWNRaVSFLhl3wy9psLSCY/UwmuTm3QDS6l1se1Mjg=";
          };
        });
        # vulkan header/loader/mesa must stay from one nixpkgs, else vkCreateInstance
        # gives -9 (INCOMPATIBLE_DRIVER); keep the whole stack on stable
        vmaPinned = pkgs.vulkan-memory-allocator;           # 3.3.0
        vulkanHeadersPinned = pkgs.vulkan-headers;          # 1.4.341, matches loader + mesa

        # angle on clang 20
        ladybirdAngle = pkgs.angle.override { stdenv = pkgs.llvmPackages_20.stdenv; };

        # in-store mesa Vulkan ICDs; HW drivers (radeon/intel/…) and lavapipe (SW)
        mesaIcdDir = "${pkgs.mesa}/share/vulkan/icd.d";

        # one share dir per renderer; helper processes only see XDG_DATA_DIRS, not VK_*
        lavapipeIcdShare = pkgs.runCommand "lb-vulkan-icd-lavapipe" { } ''
          mkdir -p $out/share/vulkan/icd.d
          cp ${mesaIcdDir}/lvp_icd.*.json $out/share/vulkan/icd.d/
        '';

        hwIcdShare = pkgs.runCommand "lb-vulkan-icd-hw" { } ''
          mkdir -p $out/share/vulkan/icd.d
          for f in ${mesaIcdDir}/*_icd.*.json; do
            case "$(basename "$f")" in lvp_icd.*) continue ;; esac
            cp "$f" $out/share/vulkan/icd.d/
          done
          [ -n "$(ls -A $out/share/vulkan/icd.d)" ] || { echo "no mesa HW ICDs found" >&2; exit 1; }
        '';

        libPkgs = with pkgs; [
          curlPinned ffmpegPinned.lib fontconfig.lib libavifPinned ladybirdAngle libwebp libxcrypt
          opensslPinned sdl3Pinned brotli.lib lcms2 zstd libidn2 woff2.lib icu78
          mimalloc227 harfbuzzPinned libjpegTurboPinned libpngPinned libxml2Pinned sqlitePinned zlibPinned freetypePinned ladybirdSkia
          simdutfPinned simdjsonPinned libtommath libpsl libedit cpptracePinned zmijPinned
          libdrm vulkan-loader vmaPinned
          libGL libpulseaudio glib libxkbcommon qt6Packages.qtbase qt6Packages.qtmultimedia qt6Packages.qtpositioning qt6Packages.qtwayland
          stdenv.cc.cc.lib
        ];

        cmakePrefixParts = with pkgs; [
          icu78.dev harfbuzzPinned.dev opensslPinned.dev curlPinned.dev sdl3Pinned.dev
          fontconfig.dev expat.dev libavifPinned.dev libpngPinned.dev libxml2Pinned.dev zlibPinned.dev
          woff2.dev ffmpegPinned.dev ffmpegLadybirdPc libedit.dev libpsl.dev libjpegTurboPinned.dev sqlitePinned.dev
          freetypePinned.dev
          mimalloc227.dev
          # symbolized stacktraces
          cpptracePinned
          zmijPinned
          libtommath
          vulkan-loader.dev vulkanHeadersPinned vmaPinned
          libpulseaudio.dev libGL.dev libsysprof-capture
          qt6Packages.qtbase qt6Packages.qtmultimedia qt6Packages.qtpositioning qt6Packages.qtwayland
        ];

        cmakePrefixPath = pkgs.lib.concatStringsSep ":" (map toString cmakePrefixParts);

        # lib dirs baked into the binaries' RPATH
        libraryPath = pkgs.lib.makeLibraryPath libPkgs;

        nixpkgsSrc = nixpkgs;


        # lbenv: bash logic lives in ./scripts/lbenv.sh (plain, shellcheck-able).
        # @BINPATH@ and @DB_DIR@ are substituted in at build time.
        lbenv = pkgs.writeShellScriptBin "lbenv" (
          builtins.replaceStrings
            [ "@BINPATH@" "@DB_DIR@" ]
            [ "${pkgs.lib.makeBinPath (with pkgs; [ curl git coreutils gnugrep gnused ])}" "${lbdb}" ]
            (builtins.readFile ./scripts/lbenv.sh)
        );

        # Ladybird is an own binary, not a shellHook function: the renderer default
        # lives in .lbenv.conf and is read at every start, so nothing has to be
        # exported back into the calling shell.
        ladybirdCmd = pkgs.writeShellScriptBin "Ladybird" (
          builtins.replaceStrings
            [ "@BINPATH@" "@LAVAPIPE_ICD@" "@HW_ICD@" ]
            [ "${pkgs.lib.makeBinPath (with pkgs; [ coreutils gnugrep gnused ])}" "${lavapipeIcdShare}" "${hwIcdShare}" ]
            (builtins.readFile ./scripts/ladybird.sh)
        );

      in {
        # `nix run github:Sm00shed/lbenv` starts lbenv directly (banner -> shell),
        # no interactive nix-develop bash in between
        packages.default = lbenv;
        apps.default = {
          type = "app";
          program = "${lbenv}/bin/lbenv";
        };

        devShells.default = pkgs.mkShell {
          name = "lbdev";

          NIX_ENFORCE_NO_NATIVE = "0";

          packages = libPkgs
            ++ [ llvmClang lbenv ladybirdCmd ]
            ++ (with pkgs; [
              cmake ninja pkg-config python3 perl cargo rustc ccache git coreutils
              curlPinned.dev fastFloatPinned ffmpegPinned.dev fontconfig.dev expat.dev
              libavifPinned.dev opensslPinned.dev sdl3Pinned.dev simdutfPinned brotli.dev lcms2.dev
              zstd.dev libidn2.dev woff2.dev icu78.dev simdjsonPinned zmijPinned mimalloc227.dev
              wuffsSinglefile cpptracePinned libedit libedit.dev libpsl libpsl.dev harfbuzzPinned.dev libjpegTurboPinned.dev
              libpngPinned.dev libxml2Pinned.dev sqlitePinned.dev zlibPinned.dev freetypePinned.dev
              unicode-character-database unicode-emoji unicode-idna publicsuffix-list
              cacert
              patchelf glslang direnv
              libdrm.dev vulkanHeadersPinned vulkan-loader.dev
              libGL.dev libpulseaudio.dev glib.dev libsysprof-capture
              qt6Packages.qtmultimedia qt6Packages.qtpositioning qt6Packages.qtwayland
            ]);

          shellHook = ''
            export CC=${llvmClang}/bin/clang
            export CXX=${llvmClang}/bin/clang++
            export CMAKE_BUILD_TYPE=Release
            export CMAKE_PREFIX_PATH="${cmakePrefixPath}''${CMAKE_PREFIX_PATH:+:$CMAKE_PREFIX_PATH}"
            export ICU_ROOT=${pkgs.icu78.dev}
            export PKG_CONFIG_PATH="${ladybirdSkia}/lib/pkgconfig:${ladybirdAngle}/lib/pkgconfig''${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}"
            export CLANGD_PATH=${llvm.clang-unwrapped}/bin/clangd
            export SSL_CERT_FILE=${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt
            _sel=0; [ -n "''${LBENV_FLAKE_REV:-}" ] && _sel=1

            export LADYBIRD_SRC_DIR="$PWD"
            # CA cert only exists in a ladybird worktree; export only when created
            if [ -f "$PWD/Meta/CMake/check_for_dependencies.cmake" ]; then
              mkdir -p "$PWD/Caches/CACERT"
              cp --no-preserve=mode ${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt \
                 "$PWD/Caches/CACERT/ca-bundle.crt"
              export LADYBIRD_CERTIFICATE="$PWD/Caches/CACERT/ca-bundle.crt"

              # crash reports come from XDG_DATA_HOME, the profile from --profile-path
              export XDG_DATA_HOME="$PWD/.lbenv/data"
              mkdir -p "$XDG_DATA_HOME"
            fi
            unset VCPKG_ROOT
            unset CMAKE_TOOLCHAIN_FILE

            # CMake reads LDFLAGS from env, not CMAKE_*_LINKER_FLAGS directly
            export LDFLAGS="-lGL -lfontconfig -Wl,-rpath,${libraryPath}''${LDFLAGS:+ $LDFLAGS}"
            # build dir inside the per-hash worktree
            export LADYBIRD_BUILD_DIR="Build"

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
