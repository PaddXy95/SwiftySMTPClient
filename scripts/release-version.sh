#!/usr/bin/env bash
# Works out the next release from the commits since the last one (SemVer from Conventional Commits).
#
# Prints `previous=<tag>` and `version=<next>` (GitHub Actions output format) and writes the commit list for the
# release notes to the file given as $1 (default: release-notes.md). Prints nothing if HEAD is already released.
#
#   0.x:  breaking change -> minor, everything else -> patch
#   1.x+: breaking change -> major, feat -> minor, everything else -> patch
#   A breaking change is `type!:` / `type(scope)!:` in the subject or a `BREAKING CHANGE:` footer.
set -euo pipefail

notes="${1:-release-notes.md}"

# Highest final version (no pre-release suffix) among the given tags, newest first.
highest() {
  local tag
  while IFS= read -r tag; do
    if [[ "$tag" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
      echo "$tag"
      return
    fi
  done <<< "$1"
}

released=$(highest "$(git tag --points-at HEAD --sort=-v:refname)")
if [[ -n "$released" ]]; then
  echo "HEAD is already released as $released" >&2
  exit 0
fi

previous=$(highest "$(git tag --merged HEAD --sort=-v:refname)")
if [[ -z "$previous" ]]; then
  version=0.1.0
  range=HEAD
else
  range="$previous..HEAD"
  IFS=. read -r major minor patch <<< "$previous"
  subjects=$(git log --format=%s "$range")
  bodies=$(git log --format=%b "$range")
  breaking=false
  feature=false
  if grep -qE '^[a-zA-Z]+(\([^)]*\))?!:' <<< "$subjects" || grep -qE '^BREAKING[ -]CHANGE:' <<< "$bodies"; then
    breaking=true
  fi
  if grep -qE '^feat(\([^)]*\))?:' <<< "$subjects"; then
    feature=true
  fi
  if (( major == 0 )); then
    if $breaking; then version="0.$((minor + 1)).0"; else version="0.$minor.$((patch + 1))"; fi
  elif $breaking; then
    version="$((major + 1)).0.0"
  elif $feature; then
    version="$major.$((minor + 1)).0"
  else
    version="$major.$minor.$((patch + 1))"
  fi
fi

{
  echo "## Changes"
  echo
  git log --no-merges --format='- %s (%h)' "$range"
} > "$notes"

echo "previous=$previous"
echo "version=$version"
