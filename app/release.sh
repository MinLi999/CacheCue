#!/bin/bash
# Makes the next release and publishes it on GitHub, in one go:
# next version -> build -> sign -> DMG -> notarize -> staple -> signed appcast -> tag ->
# release with the DMG and the appcast.
#
#   NOTARY_PROFILE=<profile> ./release.sh            the next patch version
#   NOTARY_PROFILE=<profile> ./release.sh 1.1.0      a version of your choosing
#
# Run it from a clean checkout whose commits are pushed: the tag goes on the remote's HEAD.
set -euo pipefail
cd "$(dirname "$0")"
REPO="${REPO:-MinLi999/CacheCue}"

swift test
./build-app.sh --release "${1:-}"
VERSION="$(cat build/VERSION)"

# appcast.xml rides along: installed copies read it from the latest release to learn of this one.
gh release create "v$VERSION" "build/CacheCue_$VERSION.dmg" build/CacheCue.dmg build/appcast.xml \
    --repo "$REPO" --title "CacheCue $VERSION" --generate-notes
echo "published: https://github.com/$REPO/releases/tag/v$VERSION"
echo "download:  https://github.com/$REPO/releases/latest/download/CacheCue.dmg"
