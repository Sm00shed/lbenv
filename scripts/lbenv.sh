# SPDX-License-Identifier: GPL-2.0-only
# lbenv (newest) | lbenv switch [key|hash] | lbenv new [hash] | lbenv dev
#
# Standalone bash: @BINPATH@ and @DB_DIR@ are substituted by flake.nix at build
# time (writeShellScriptBin via builtins.replaceStrings). Kept out of the flake
# so it stays plain, shellcheck-able bash.
set -euo pipefail
export PATH="@BINPATH@:$PATH"

REPO="LadybirdBrowser/ladybird"
FLAKE_REPO="Sm00shed/lbenv"
DB_REPO="Sm00shed/lbenv-db"
DB_DIR="@DB_DIR@"   # flake input checkout, always present (offline)

# local clone if present
FLAKE_DIR="${LADYBIRD_FLAKE_DIR:-$PWD/../lbenv}"
if [ -d "$FLAKE_DIR/.git" ]; then
  FLAKE_REF="$FLAKE_DIR"; LOCAL=1
else
  FLAKE_REF="github:$FLAKE_REPO"; LOCAL=0
fi

# strict single-line "key = "value"" TOML, from stdin
toml_get() { sed -n "s/^$1[[:space:]]*=[[:space:]]*\"\(.*\)\"/\1/p"; }

# newest ladybird sha: local input first, curl to refresh
db_latest() {
  if [ -f "$DB_DIR/latest" ]; then
    cat "$DB_DIR/latest"
  else
    curl -fsSL "https://raw.githubusercontent.com/$DB_REPO/main/latest"
  fi
}

# one commit's TOML to stdout: local input first, curl fallback
db_toml() {
  if [ -f "$DB_DIR/$1.toml" ]; then
    cat "$DB_DIR/$1.toml"
  else
    curl -fsSL "https://raw.githubusercontent.com/$DB_REPO/main/$1.toml"
  fi
}

# flake rev for the banner
flake_rev() {
  if [ "$LOCAL" = 1 ]; then
    git -C "$FLAKE_DIR" rev-parse HEAD 2>/dev/null || true
  else
    git ls-remote "https://github.com/$FLAKE_REPO" HEAD 2>/dev/null | cut -f1
  fi
}

wt_root()  { echo "${LBENV_WT:-$HOME/lbenv-wt}"; }
main_src() { echo "${LADYBIRD_SRC:-$HOME/ladybird}"; }

# worktree for a ladybird rev, one dir per hash; prints its path.
# $2 optional branch name: create/checkout that branch instead of detaching.
ensure_worktree() {
  local lh="$1" branch="${2:-}" src dir
  src=$(main_src); dir="$(wt_root)/$lh"
  [ -d "$src/.git" ] || git clone --quiet "https://github.com/$REPO" "$src" >&2
  mkdir -p "$(wt_root)"
  if [ ! -e "$dir" ]; then
    git -C "$src" cat-file -e "$lh^{commit}" 2>/dev/null \
      || git -C "$src" fetch --quiet origin "$lh" 2>/dev/null \
      || git -C "$src" fetch --quiet origin || true
    if [ -n "$branch" ]; then
      # reuse branch if it already exists, else create it at the target sha
      if git -C "$src" show-ref --verify --quiet "refs/heads/$branch"; then
        git -C "$src" worktree add --quiet "$dir" "$branch" >&2
      else
        git -C "$src" worktree add --quiet -b "$branch" "$dir" "$lh" >&2
      fi
    else
      git -C "$src" worktree add --quiet --detach "$dir" "$lh" >&2
    fi
  fi
  echo "$dir"
}

# .envrc so an IDE (via direnv) auto-loads this exact devShell on open
write_envrc() {
  local dir="$1"
  [ -n "${LBENV_NO_ENVRC:-}" ] && return 0
  [ -f "$dir/.envrc" ] && return 0
  printf 'use flake github:%s\n' "$FLAKE_REPO" > "$dir/.envrc"
  command -v direnv >/dev/null 2>&1 && direnv allow "$dir" >/dev/null 2>&1 || true
}

override() {
  local dir; dir=$(ensure_worktree "$1")   # detached, floating — no .envrc
  export LBENV_FLAKE_REV="$(flake_rev)"
  export LBENV_LADYBIRD="$1" LBENV_TITLE="(not recorded)" LBENV_WHEN="" LBENV_VCPKG="-"
  cd "$dir" || exit 1
  exec nix develop "$FLAKE_REF" --quiet
}

# enter one lbenv-db entry (by ladybird sha), in its worktree.
# $2 optional: ladybird sha to check out INSTEAD of the recorded one
#    (dev: own commit inherits the recorded pin). $3 optional branch name.
freeze_sha() {
  local sha="$1" checkout="${2:-}" branch="${3:-}"
  local toml lh lbrev npkgs title vcpkg date time dir
  toml="$(db_toml "$sha")" || { echo "not in lbenv-db: $sha" >&2; exit 1; }
  [ -n "$toml" ] || { echo "not in lbenv-db: $sha" >&2; exit 1; }
  lh="$(printf '%s\n' "$toml" | toml_get ladybird)"; lh="${lh:-$sha}"
  lbrev="$(printf '%s\n' "$toml" | toml_get lbenv)"    # build logic (flake.nix), pins overrides
  npkgs="$(printf '%s\n' "$toml" | toml_get nixpkgs)"  # nixpkgs branch floats, pin it
  title="$(printf '%s\n' "$toml" | toml_get title)"
  vcpkg="$(printf '%s\n' "$toml" | toml_get vcpkg)"
  date="$(printf '%s\n' "$toml" | toml_get date)"
  time="$(printf '%s\n' "$toml" | toml_get time)"
  # dev: sit on our own (unrecorded) commit, keep the inherited pin/banner
  [ -n "$checkout" ] && lh="$checkout"
  export LBENV_LADYBIRD="$lh"
  export LBENV_TITLE="${title:-(no title)}"
  export LBENV_VCPKG="${vcpkg:--}"
  export LBENV_WHEN="${date}${time:+ $time}"
  dir=$(ensure_worktree "$lh" "$branch")
  write_envrc "$dir"
  cd "$dir" || exit 1

  local dev=()
  [ -n "$npkgs" ] && dev+=(--override-input nixpkgs "github:NixOS/nixpkgs/$npkgs")

  if [ -n "$lbrev" ]; then
    export LBENV_FLAKE_REV="$lbrev"
    exec nix develop "github:$FLAKE_REPO/$lbrev" "${dev[@]}" --quiet
  else
    echo "warning: no recorded lbenv rev — using current flake, not frozen" >&2
    export LBENV_FLAKE_REV="$(flake_rev)"
    exec nix develop "$FLAKE_REF" "${dev[@]}" --quiet
  fi
}

case "${1:-}" in
  "")
    # newest recorded (lbenv-db `latest`)
    sha=$(db_latest | tr -d '[:space:]')
    [ -n "$sha" ] || { echo "lbenv-db: cannot read latest" >&2; exit 1; }
    freeze_sha "$sha"
    ;;
  dev)
    # develop on top of newest recorded: own branch to commit onto,
    # but inherit that recorded entry's frozen nixpkgs/lbenv pin.
    base=$(db_latest | tr -d '[:space:]')
    [ -n "$base" ] || { echo "lbenv-db: cannot read latest" >&2; exit 1; }
    # resolve the actual ladybird sha of `latest` for the branch name
    lh="$(db_toml "$base" | toml_get ladybird)"; lh="${lh:-$base}"
    branch="lbenv-dev/${lh:0:8}"
    echo "dev on ${lh:0:8} — branch $branch, inheriting recorded pin"
    # checkout = recorded sha (fresh branch there); pin inherited from same entry
    freeze_sha "$base" "$lh" "$branch"
    ;;
  new)
    hash="${2:-}"
    if [ -z "$hash" ]; then
      hash=$(git ls-remote "https://github.com/$REPO" HEAD 2>/dev/null | cut -f1)
      echo "upstream HEAD ${hash:0:8} — floating placeholder, not recorded"
    else
      echo "${hash:0:8} — floating placeholder, not recorded"
    fi
    override "$hash"
    ;;
  switch)
    key="${2:-}"
    [ -n "$key" ] || { echo "usage: lbenv switch <sha>" >&2; exit 1; }

    # exact sha file, else prefix match against local db; else curl fallback in freeze_sha
    sha="$key"
    if [ ! -f "$DB_DIR/$key.toml" ]; then
      match=$(cd "$DB_DIR" && ls -1 ./*.toml 2>/dev/null \
        | sed 's,^\./,,; s,\.toml$,,' | grep -E "^$key" | head -n1 || true)
      [ -n "$match" ] && sha="$match"
    fi
    freeze_sha "$sha"
    ;;
  *)
    echo "usage:" >&2
    echo "  lbenv                  newest recorded version" >&2
    echo "  lbenv switch <hash>    pick a recorded version by sha (prefix ok)" >&2
    echo "  lbenv dev              develop on newest recorded (own branch, inherited pin)" >&2
    echo "  lbenv new [hash]       floating, unrecorded commit" >&2
    exit 1
    ;;
esac
