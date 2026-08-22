#!/bin/sh
set -eu

EXPECTED_ORIGIN="https://github.com/blazncloud/blazn-computer-use.git"
EXPECTED_UPSTREAM="https://github.com/minghinmatthewlam/computer-use-mcp.git"
CONFIGURE=0
FETCH=0

for arg in "$@"; do
  case "$arg" in
    --configure) CONFIGURE=1 ;;
    --fetch) FETCH=1 ;;
    --check) ;;
    *) echo "Usage: scripts/upstream_sync.sh [--configure] [--fetch] [--check]" >&2; exit 2 ;;
  esac
done

ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT"

if [ -n "$(git status --porcelain=v1 --untracked-files=normal)" ]; then
  echo "Refusing upstream check: worktree is dirty." >&2
  exit 2
fi

if [ "$CONFIGURE" -eq 1 ]; then
  if git remote get-url origin >/dev/null 2>&1; then
    git remote set-url origin "$EXPECTED_ORIGIN"
  else
    git remote add origin "$EXPECTED_ORIGIN"
  fi
  if git remote get-url upstream >/dev/null 2>&1; then
    git remote set-url upstream "$EXPECTED_UPSTREAM"
  else
    git remote add upstream "$EXPECTED_UPSTREAM"
  fi
fi

ORIGIN=$(git remote get-url origin 2>/dev/null || true)
UPSTREAM=$(git remote get-url upstream 2>/dev/null || true)
if [ "$ORIGIN" != "$EXPECTED_ORIGIN" ]; then
  echo "origin must be $EXPECTED_ORIGIN (found: ${ORIGIN:-missing})" >&2
  exit 2
fi
if [ "$UPSTREAM" != "$EXPECTED_UPSTREAM" ]; then
  echo "upstream must be $EXPECTED_UPSTREAM (found: ${UPSTREAM:-missing})" >&2
  exit 2
fi

if [ "$FETCH" -eq 1 ]; then
  git fetch --no-tags origin main
  git fetch --no-tags upstream main
fi

git show-ref --verify --quiet refs/remotes/origin/main || {
  echo "origin/main is missing; rerun with --fetch" >&2
  exit 2
}
git show-ref --verify --quiet refs/remotes/upstream/main || {
  echo "upstream/main is missing; rerun with --fetch" >&2
  exit 2
}

COUNTS=$(git rev-list --left-right --count origin/main...upstream/main)
ORIGIN_ONLY=$(printf '%s\n' "$COUNTS" | awk '{print $1}')
UPSTREAM_ONLY=$(printf '%s\n' "$COUNTS" | awk '{print $2}')
HEAD_SHA=$(git rev-parse HEAD)
ORIGIN_SHA=$(git rev-parse origin/main)
UPSTREAM_SHA=$(git rev-parse upstream/main)

printf '{\n'
printf '  "head": "%s",\n' "$HEAD_SHA"
printf '  "originMain": "%s",\n' "$ORIGIN_SHA"
printf '  "upstreamMain": "%s",\n' "$UPSTREAM_SHA"
printf '  "originOnlyCommits": %s,\n' "$ORIGIN_ONLY"
printf '  "upstreamOnlyCommits": %s\n' "$UPSTREAM_ONLY"
printf '}\n'

if [ "$UPSTREAM_ONLY" -ne 0 ]; then
  echo "Fork is behind upstream; create a dedicated sync branch before mutation." >&2
  exit 3
fi
