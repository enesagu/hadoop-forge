#!/usr/bin/env bash
#
# Verify that every relative link in the Markdown resolves to a file that exists.
#
#   bash tests/check-links.sh
#   make lint-links
#
# Deliberately local and offline. External URLs are not checked: they break for
# reasons that have nothing to do with this repository, and a check that fails on
# somebody else's outage is one people learn to ignore. This replaces a
# third-party link-checking action that was itself rate-limited out of running.
#
# Covers Markdown links and images, plus HTML href/src attributes, since the
# READMEs use both. Fenced code blocks are excluded — Kerberos auth_to_local
# rules such as RULE:[2:$1@$0](nn/.*@EXAMPLE.COM) are indistinguishable from a
# Markdown link by shape, and are not links.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)"
cd "${REPO_ROOT}"

if [[ -t 1 ]]; then
  R=$'\033[31m'; G=$'\033[32m'; B=$'\033[1m'; Z=$'\033[0m'
else
  R=''; G=''; B=''; Z=''
fi

BROKEN=0
CHECKED=0

printf '%shadoop-forge link check%s\n\n' "$B" "$Z"

mapfile -t MD_FILES < <(git ls-files '*.md' | sort)
(( ${#MD_FILES[@]} > 0 )) || { printf '%sNo Markdown files tracked%s\n' "$R" "$Z"; exit 1; }

# Everything outside ``` fences.
prose_only() {
  awk '
    /^[[:space:]]*```/ { in_fence = !in_fence; next }
    !in_fence
  ' "$1"
}

for file in "${MD_FILES[@]}"; do
  dir="$(dirname "$file")"
  prose="$(prose_only "$file")"

  # Markdown [text](target) and ![alt](target), plus HTML href="" / src="".
  # grep -o emits one match per line, so several links on one line are all seen.
  {
    grep -o '\[[^]]*\]([^)]*)' <<<"$prose" | sed 's/.*(\(.*\))/\1/'
    grep -o 'href="[^"]*"'     <<<"$prose" | sed 's/href="\(.*\)"/\1/'
    grep -o 'src="[^"]*"'      <<<"$prose" | sed 's/src="\(.*\)"/\1/'
  } 2>/dev/null | while IFS= read -r target; do
    [[ -n "$target" ]] || continue

    case "$target" in
      # Not ours to verify.
      http://*|https://*|mailto:*|tel:*|ftp://*) continue ;;
      # Pure in-page anchor.
      \#*) continue ;;
      # Template placeholders in issue/PR bodies.
      '<'*) continue ;;
    esac

    # Drop any #fragment and ?query before resolving the path.
    path="${target%%#*}"
    path="${path%%\?*}"
    [[ -n "$path" ]] || continue

    if [[ "$path" == /* ]]; then
      resolved="${REPO_ROOT}${path}"
    else
      resolved="${dir}/${path}"
    fi

    if [[ -e "$resolved" ]]; then
      printf 'ok %s -> %s\n' "$file" "$target"
    else
      printf 'BROKEN %s -> %s\n' "$file" "$target"
    fi
  done
done > /tmp/forge-links.$$ 2>&1

# The while loop above runs in a subshell because of the pipe, so counting has
# to happen out here rather than inside it.
CHECKED="$(grep -c '^ok ' /tmp/forge-links.$$ || true)"
BROKEN="$(grep -c '^BROKEN ' /tmp/forge-links.$$ || true)"

if (( BROKEN > 0 )); then
  printf '%sBroken links:%s\n' "$R" "$Z"
  while IFS= read -r line; do
    file="$(awk '{print $2}' <<<"$line")"
    target="$(awk '{print $4}' <<<"$line")"
    printf '  %s✗%s %s → %s\n' "$R" "$Z" "$file" "$target"
  done < <(grep '^BROKEN ' /tmp/forge-links.$$)
  printf '\n'
fi

rm -f /tmp/forge-links.$$

if (( BROKEN > 0 )); then
  printf '%s%d broken, %d resolved.%s\n\n' "$R" "$BROKEN" "$CHECKED" "$Z"
  exit 1
fi
printf '%sAll %d relative links resolve.%s\n\n' "$G" "$CHECKED" "$Z"
