#!/usr/bin/env bash
# Decide whether the Nightly workflow should build and publish.
#
# "Application changes" are the paths that affect the source build Homebrew
# runs: Sources/, Package.swift, Package.resolved, and Resources/.
# Tests, docs, Formula, Makefile, and CI do not count. The formula invokes
# `swift build` itself, so a Makefile-only edit does not change the nightly.
# When no nightly-* tag exists yet, publish current main once so the formula
# has a snapshot to track.
set -euo pipefail

export LC_ALL=C

APP_PATHS=(Sources Package.swift Package.resolved Resources)

emit() {
  if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
    printf '%s\n' "$1" >> "${GITHUB_OUTPUT}"
  else
    printf '%s\n' "$1"
  fi
}

is_real_utc_date() {
  local spec="$1"
  [[ "${spec}" =~ ^([0-9]{4})\.([0-9]{2})\.([0-9]{2})$ ]] || return 1
  local y=$((10#${BASH_REMATCH[1]}))
  local m=$((10#${BASH_REMATCH[2]}))
  local d=$((10#${BASH_REMATCH[3]}))
  local max
  case "${m}" in
    1 | 3 | 5 | 7 | 8 | 10 | 12) max=31 ;;
    4 | 6 | 9 | 11) max=30 ;;
    2)
      if (( (y % 4 == 0 && y % 100 != 0) || y % 400 == 0 )); then
        max=29
      else
        max=28
      fi
      ;;
    *) return 1 ;;
  esac
  (( d >= 1 && d <= max ))
}

FORCE="${FORCE:-false}"
CALVER_DATE="${CALVER_DATE:-}"
TARGET_SHA="${TARGET_SHA:-HEAD}"

if [[ -n "${CALVER_DATE}" ]]; then
  if [[ ! "${CALVER_DATE}" =~ ^([0-9]{4}\.[0-9]{2}\.[0-9]{2})(-[A-Za-z0-9]{1,32})?$ ]]; then
    echo "calver_date must use YYYY.MM.DD or YYYY.MM.DD-[A-Za-z0-9]{1,32}" >&2
    exit 1
  fi
  date_part="${BASH_REMATCH[1]}"
  if ! is_real_utc_date "${date_part}"; then
    echo "calver_date must be a real calendar date in YYYY.MM.DD format" >&2
    exit 1
  fi
  tag_date="${CALVER_DATE}"
else
  tag_date="$(date -u +%Y.%m.%d)"
fi

sha="$(git rev-parse --verify "${TARGET_SHA}^{commit}")"

latest_tag=""
while IFS= read -r tag; do
  [[ "${tag}" =~ ^nightly-[0-9]{4}\.[0-9]{2}\.[0-9]{2}$ ]] || continue
  if [[ -z "${latest_tag}" || "${tag}" > "${latest_tag}" ]]; then
    latest_tag="${tag}"
  fi
done < <(git tag -l 'nightly-*')

changed_files=""
if [[ -z "${latest_tag}" ]]; then
  app_changed=true
  reason="no previous nightly tag; publishing current main"
else
  latest_sha="$(git rev-parse --verify "${latest_tag}^{commit}")"
  changed_files="$(git diff --name-only "${latest_sha}" "${sha}" -- "${APP_PATHS[@]}")"
  if [[ -n "${changed_files}" ]]; then
    app_changed=true
    reason="application paths changed since ${latest_tag}"
  else
    app_changed=false
    reason="no application path changes since ${latest_tag}"
  fi
fi

publish=false
if [[ "${FORCE}" == "true" ]]; then
  publish=true
  reason="workflow_dispatch force=true; ${reason}"
elif [[ "${app_changed}" == true ]]; then
  publish=true
fi

if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
  {
    echo "## Nightly decision"
    echo
    echo "- publish: \`${publish}\`"
    echo "- commit: \`${sha}\`"
    echo "- previous tag: \`${latest_tag:-none}\`"
    echo "- tag date: \`${tag_date}\`"
    echo "- reason: ${reason}"
    if [[ -n "${changed_files}" ]]; then
      echo
      echo "Application paths:"
      echo
      echo '```text'
      printf '%s\n' "${changed_files}"
      echo '```'
    fi
  } >> "${GITHUB_STEP_SUMMARY}"
fi

emit "publish=${publish}"
emit "sha=${sha}"
emit "tag_date=${tag_date}"
emit "previous_tag=${latest_tag}"
emit "reason=${reason}"
