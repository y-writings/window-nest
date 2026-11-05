#!/usr/bin/env bash
# Tag the built commit and pin Formula/window-nest-nightly.rb to that tag.
#
# Tag names follow y-writings/calver-beacon-action: canonical nightly-YYYY.MM.DD
# (UTC), optional same-day suffix nightly-YYYY.MM.DD-<alnum>, lightweight and
# immutable. This script tags the commit that was built, which that action
# cannot do because it only resolves a branch tip. A canonical tag is not
# created when that commit is already the latest canonical nightly tag.
# Creating the tag and then failing the download is safe: the next run sees
# the existing tag and continues with the formula pin.
set -euo pipefail

export LC_ALL=C

emit() {
  if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
    printf '%s\n' "$1" >> "${GITHUB_OUTPUT}"
  else
    printf '%s\n' "$1"
  fi
}

: "${GH_TOKEN:?GH_TOKEN is required}"
: "${REPO:?REPO is required}"
: "${TARGET_SHA:?TARGET_SHA is required}"
: "${TAG_DATE:?TAG_DATE is required}"

if [[ ! "${TARGET_SHA}" =~ ^[0-9a-f]{40}$ ]]; then
  echo "TARGET_SHA must be a full lowercase commit sha" >&2
  exit 1
fi
if [[ ! "${TAG_DATE}" =~ ^[0-9]{4}\.[0-9]{2}\.[0-9]{2}(-[A-Za-z0-9]{1,32})?$ ]]; then
  echo "TAG_DATE must use YYYY.MM.DD or YYYY.MM.DD-[A-Za-z0-9]{1,32}" >&2
  exit 1
fi

repo_root="$(git rev-parse --show-toplevel)"
cd "${repo_root}"

desired="nightly-${TAG_DATE}"
canonical=false
if [[ "${desired}" =~ ^nightly-[0-9]{4}\.[0-9]{2}\.[0-9]{2}$ ]]; then
  canonical=true
fi

latest_tag=""
latest_sha=""
list_err="$(mktemp)"
set +e
refs="$(gh api --paginate "repos/${REPO}/git/matching-refs/tags/nightly-" \
  --jq '.[] | [.ref, .object.type, .object.sha] | @tsv' 2>"${list_err}")"
refs_status=$?
set -e
if [[ "${refs_status}" -ne 0 ]]; then
  # No nightly tags yet is a 404 from the matching-refs API.
  if grep -Eq '404|Not Found' "${list_err}"; then
    refs=""
  else
    cat "${list_err}" >&2
    rm -f "${list_err}"
    echo "failed to list nightly tags" >&2
    exit 1
  fi
fi
rm -f "${list_err}"

while IFS=$'\t' read -r ref type object_sha; do
  [[ -n "${ref}" ]] || continue
  tag="${ref#refs/tags/}"
  [[ "${tag}" =~ ^nightly-[0-9]{4}\.[0-9]{2}\.[0-9]{2}$ ]] || continue
  sha="${object_sha}"
  if [[ "${type}" == "tag" ]]; then
    sha="$(gh api "repos/${REPO}/git/tags/${object_sha}" --jq '.object.sha')"
  fi
  sha="${sha,,}"
  if [[ -z "${latest_tag}" || "${tag}" > "${latest_tag}" ]]; then
    latest_tag="${tag}"
    latest_sha="${sha}"
  fi
done <<< "${refs}"

lookup_tag() {
  local name="$1"
  local response=""
  if ! response="$(gh api "repos/${REPO}/git/ref/tags/${name}" \
    --jq '[.object.type, .object.sha] | @tsv' 2>/dev/null)"; then
    return 1
  fi
  local type="${response%%$'\t'*}"
  local sha="${response#*$'\t'}"
  if [[ "${type}" == "tag" ]]; then
    sha="$(gh api "repos/${REPO}/git/tags/${sha}" --jq '.object.sha')"
  fi
  printf '%s\n' "${sha,,}"
}

created=false
chosen=""
if existing_sha="$(lookup_tag "${desired}")"; then
  if [[ "${existing_sha}" != "${TARGET_SHA}" ]]; then
    echo "tag ${desired} already exists and points to ${existing_sha}, expected ${TARGET_SHA}." >&2
    echo "Pass calver_date with a suffix, such as ${TAG_DATE}-2, to publish another snapshot." >&2
    exit 1
  fi
  chosen="${desired}"
  echo "tag ${desired} already points at ${TARGET_SHA}"
elif [[ "${canonical}" == true && -n "${latest_sha}" && "${latest_sha}" == "${TARGET_SHA}" ]]; then
  chosen="${latest_tag}"
  echo "commit ${TARGET_SHA} is already ${latest_tag}; not creating another canonical tag"
else
  if ! gh api --method POST "repos/${REPO}/git/refs" \
    -f ref="refs/tags/${desired}" \
    -f sha="${TARGET_SHA}" >/dev/null; then
    if existing_sha="$(lookup_tag "${desired}")" && [[ "${existing_sha}" == "${TARGET_SHA}" ]]; then
      chosen="${desired}"
      echo "tag ${desired} was created concurrently at ${TARGET_SHA}"
    else
      echo "failed to create tag ${desired}" >&2
      exit 1
    fi
  else
    chosen="${desired}"
    created=true
    echo "created ${desired} at ${TARGET_SHA}"
  fi
fi

url="https://github.com/${REPO}/archive/refs/tags/${chosen}.tar.gz"
tmp="$(mktemp)"
trap 'rm -f "${tmp}"' EXIT
downloaded=false
for attempt in 1 2 3 4 5 6 7 8 9 10; do
  if curl -fsSL "${url}" -o "${tmp}"; then
    downloaded=true
    break
  fi
  echo "archive download failed (attempt ${attempt}); retrying ${url}" >&2
  sleep $((attempt < 5 ? attempt * 3 : 15))
done
if [[ "${downloaded}" != true ]]; then
  echo "failed to download ${url}" >&2
  exit 1
fi
if ! gzip -t "${tmp}"; then
  echo "downloaded archive is not gzip: ${url}" >&2
  exit 1
fi
# `grep -q` exits at the first match and SIGPIPEs tar. With pipefail that
# status is 141, so a valid archive is rejected after the tag exists.
if ! tar -tzf "${tmp}" | grep '/Package.swift$' >/dev/null; then
  echo "archive is missing Package.swift: ${url}" >&2
  exit 1
fi

sha256="$(sha256sum "${tmp}" | awk '{print $1}')"
version="${chosen#nightly-}"

NIGHTLY_URL="${url}" NIGHTLY_VERSION="${version}" NIGHTLY_SHA256="${sha256}" \
  python3 .github/scripts/nightly-update-formula.py

emit "tag=${chosen}"
emit "created=${created}"
emit "version=${version}"
emit "sha256=${sha256}"
