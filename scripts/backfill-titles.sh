#!/usr/bin/env bash
# One-time backfill of `time` + `title` into versions.json for entries that
# predate the workflow recording them. Idempotent: only touches entries whose
# title is still missing. Needs curl + jq; set GITHUB_TOKEN to lift the 60
# req/h anonymous rate limit (1092 entries fit well under the 5000/h authed cap).
set -euo pipefail

cd "$(dirname "$0")/.."
FILE=versions.json
REPO=LadybirdBrowser/ladybird
API=https://api.github.com
MAXPAGES=40   # 40 * 100 = 4000 newest commits scanned before per-sha fallback

auth=()
[ -n "${GITHUB_TOKEN:-}" ] && auth=(-H "Authorization: Bearer $GITHUB_TOKEN")
gh() { curl -fsSL "${auth[@]}" -H "Accept: application/vnd.github+json" "$@"; }

# ladybird hashes still missing a title
mapfile -t need < <(jq -r 'to_entries[] | select((.value.title // "") == "") | .value.ladybird' "$FILE")
echo "entries needing time/title: ${#need[@]}"
[ "${#need[@]}" -gt 0 ] || { echo "nothing to backfill"; exit 0; }

declare -A wanted info
for s in "${need[@]}"; do wanted[$s]=1; done
remaining=${#need[@]}

# Cheap path: walk the commit list newest→old and pick up wanted shas in bulk.
page=1
while [ "$remaining" -gt 0 ] && [ "$page" -le "$MAXPAGES" ]; do
  json=$(gh "$API/repos/$REPO/commits?per_page=100&page=$page") || break
  [ "$(printf '%s' "$json" | jq 'length')" -gt 0 ] || break
  while IFS=$'\t' read -r sha t title; do
    if [ -n "${wanted[$sha]:-}" ] && [ -z "${info[$sha]:-}" ]; then
      info[$sha]=$(printf '%s\t%s' "$t" "$title")
      remaining=$((remaining - 1))
    fi
  done < <(printf '%s' "$json" \
    | jq -r '.[] | [.sha, (.commit.committer.date[11:16]), (.commit.message|split("\n")[0][0:100])] | @tsv')
  page=$((page + 1))
done
echo "matched via commit list: $(( ${#need[@]} - remaining )), remaining: $remaining"

# Fallback: fetch any leftovers individually.
for s in "${need[@]}"; do
  [ -n "${info[$s]:-}" ] && continue
  json=$(gh "$API/repos/$REPO/commits/$s") || { echo "  skip $s (fetch failed)" >&2; continue; }
  info[$s]=$(printf '%s' "$json" \
    | jq -r '[(.commit.committer.date[11:16]), (.commit.message|split("\n")[0][0:100])] | @tsv')
done

# Build a { "<ladybird-sha>": {time,title} } map, merge into versions.json.
tsv=$(mktemp); map=$(mktemp)
for s in "${!info[@]}"; do printf '%s\t%s\n' "$s" "${info[$s]}"; done > "$tsv"
jq -Rn '[inputs | split("\t") | {(.[0]): {time: .[1], title: (.[2] // "")}}] | add' "$tsv" > "$map"

jq --slurpfile mp "$map" '
  ($mp[0] // {}) as $m
  | with_entries(
      if ($m[.value.ladybird]) and ((.value.title // "") == "")
      then .value += $m[.value.ladybird]
      else . end)
' "$FILE" > "$FILE.tmp" && mv "$FILE.tmp" "$FILE"
rm -f "$tsv" "$map"

jq empty "$FILE" && echo "done — versions.json valid, filled $(( ${#need[@]} - remaining )) entries"
