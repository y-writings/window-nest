#!/usr/bin/env bash
# Reuse published archives; recover missing uploads without replacing assets.
set -euo pipefail

release_flags=(--prerelease=false)
if [[ "$CHANNEL" == nightly ]]; then
  release_flags=(--prerelease --latest=false)
fi

if [[ "$RELEASE_EXISTS" == true ]]; then
  if [[ "$ASSET_EXISTS" != true ]]; then
    gh release upload "$RELEASE_TAG" .build/macos-release/WindowNest.zip
  fi
  if [[ "$IS_DRAFT" == true ]]; then
    gh release edit "$RELEASE_TAG" --draft=false "${release_flags[@]}"
  fi
else
  gh release create "$RELEASE_TAG" .build/macos-release/WindowNest.zip \
    --verify-tag --title "WindowNest $RELEASE_VERSION" \
    --notes 'Universal macOS app, signed with Developer ID and notarized by Apple.' \
    "${release_flags[@]}"
fi
