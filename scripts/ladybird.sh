# SPDX-License-Identifier: GPL-2.0-only
# Ladybird [vulkan|lavapipe|cpu] [args…]  run the build in this worktree
# Ladybird --default <mode>               store the renderer in .lbenv.conf
#
# Renderer per start: mode as first argument, else LB_RENDER, else the
# .lbenv.conf default, else cpu. Standalone bash: @BINPATH@, @LAVAPIPE_ICD@ and
# @HW_ICD@ are substituted by flake.nix at build time.
set -euo pipefail
export PATH="@BINPATH@:$PATH"

if [ -z "${LADYBIRD_SRC_DIR:-}" ]; then
  echo "Ladybird: LADYBIRD_SRC_DIR is unset — run this inside the lbenv shell" >&2
  exit 1
fi
# without a selected version $PWD is just the shell cwd, no worktree in it
if [ ! -f "$LADYBIRD_SRC_DIR/Meta/CMake/check_for_dependencies.cmake" ]; then
  echo "Ladybird: no version selected — run lbenv, or lbenv switch <hash>" >&2
  exit 1
fi
conf="$LADYBIRD_SRC_DIR/.lbenv.conf"

if [ "${1:-}" = --default ]; then
  case "${2:-}" in
    vulkan|lavapipe|cpu) ;;
    *) echo "usage: Ladybird --default vulkan|lavapipe|cpu" >&2; exit 1 ;;
  esac
  { grep -v '^render[[:space:]]*=' "$conf" 2>/dev/null || true; echo "render = $2"; } > "$conf.tmp"
  mv "$conf.tmp" "$conf"
  echo "default renderer: $2"
  exit 0
fi

mode="${LB_RENDER:-}"
case "${1:-}" in vulkan|nvidia|lavapipe|cpu) mode="$1"; shift ;; esac
if [ -z "$mode" ] && [ -f "$conf" ]; then
  mode=$(sed -n 's/^render[[:space:]]*=[[:space:]]*//p' "$conf" | tail -n1)
fi

# helper processes keep only allowlisted vars, so VK_* never arrives there;
# the ICD travels via XDG_DATA_DIRS instead
unset VK_DRIVER_FILES VK_ICD_FILENAMES
args=()
case "${mode:-cpu}" in
  vulkan)   export XDG_DATA_DIRS="@HW_ICD@/share:${XDG_DATA_DIRS:-/usr/local/share:/usr/share}" ;;
  lavapipe) export XDG_DATA_DIRS="@LAVAPIPE_ICD@/share:${XDG_DATA_DIRS:-/usr/local/share:/usr/share}" ;;
  # the Compositor skips GPU init entirely here, so it needs no ICD
  cpu)      args+=(--force-cpu-painting) ;;
  nvidia)
    echo "render nvidia: placeholder — proprietary NVIDIA needs nixVulkanNvidia (impure), not implemented" >&2
    exit 1 ;;
  *) echo "Ladybird: unknown renderer '$mode' (vulkan|lavapipe|cpu)" >&2; exit 1 ;;
esac

if [ -f "${LADYBIRD_CERTIFICATE:-}" ]; then
  args+=(--certificate="$LADYBIRD_CERTIFICATE")
fi
# own runtime socket per version, else a new build attaches to a running old one
args+=(--profile-path "$LADYBIRD_SRC_DIR/.lbenv/profile")

bin="$LADYBIRD_SRC_DIR/${LADYBIRD_BUILD_DIR:-Build}/bin/Ladybird"
if [ ! -x "$bin" ]; then
  echo "Ladybird: not built yet — ninja -C ${LADYBIRD_BUILD_DIR:-Build}" >&2
  exit 1
fi
exec "$bin" "${args[@]}" "$@"
