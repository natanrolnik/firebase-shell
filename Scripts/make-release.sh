#!/usr/bin/env bash
#
# make-release.sh
#
# Re-packages Google's monolithic Firebase.zip into one zip per xcframework so
# each can be consumed as an individual SwiftPM `.binaryTarget(url:checksum:)`,
# computes the SwiftPM checksums, regenerates Package.swift, and (optionally)
# uploads the per-framework zips as GitHub release assets.
#
# Why: Google ships the precompiled, vendor-signed xcframeworks only as one big
# Firebase.zip (a folder of many xcframeworks). SwiftPM's `.binaryTarget(url:)`
# requires each artifact to be a single xcframework, so we split + re-host.
#
# Usage:
#   Scripts/make-release.sh <firebase-version> [--source <dir-or-zip>] [--upload]
#
#   <firebase-version>   e.g. 12.14.0 (matches the firebase-ios-sdk release tag)
#   --source <path>      Use an already-downloaded Firebase.zip or unzipped dir
#                        instead of downloading. Defaults to downloading from the
#                        firebase-ios-sdk release.
#   --upload             Create/append the GitHub release <firebase-version> on
#                        this repo and upload every <name>.xcframework.zip asset
#                        (requires `gh` authenticated).
#
# The hosted asset URL scheme this produces (and Package.swift expects) is:
#   https://github.com/<owner>/<repo>/releases/download/<version>/<Name>.xcframework.zip

set -euo pipefail

# --- The Firebase PRODUCTS our app consumes -----------------------------------
# We list products, not individual xcframeworks. Google's distribution puts
# every xcframework a product needs inside that product's folder, so the full
# transitive set is derived by scanning these folders (see derive step below).
# Add a product here and its transitive xcframeworks come along automatically.
PRODUCTS=(
  FirebaseAnalytics      # also brings FirebaseCore + GoogleAppMeasurement + GoogleUtilities + ...
  FirebaseCrashlytics
  FirebaseMessaging
)

# --- Arg parsing --------------------------------------------------------------
if [[ $# -lt 1 ]]; then
  echo "usage: $0 <firebase-version> [--source <dir-or-zip>] [--upload]" >&2
  exit 2
fi

VERSION="$1"; shift
SOURCE=""
DO_UPLOAD=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --source) SOURCE="$2"; shift 2 ;;
    --upload) DO_UPLOAD=1; shift ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d)"
DIST="$REPO_ROOT/dist"          # gitignored: the per-framework zips
trap 'rm -rf "$WORK"' EXIT

# Prefer Xcode's swift: swiftly's toolchain breaks `swift package` here.
SWIFT="$(xcrun -f swift)"

echo "==> Firebase version: $VERSION"
echo "==> Work dir:         $WORK"
echo "==> Output zips:      $DIST"

# --- Obtain the unzipped Firebase distribution --------------------------------
FIREBASE_DIR=""
if [[ -n "$SOURCE" ]]; then
  if [[ -d "$SOURCE" ]]; then
    FIREBASE_DIR="$SOURCE"
  elif [[ -f "$SOURCE" ]]; then
    echo "==> Unzipping $SOURCE"
    ditto -x -k "$SOURCE" "$WORK/extracted"
    FIREBASE_DIR="$(find "$WORK/extracted" -maxdepth 2 -name "Firebase.h" -exec dirname {} \; | head -1)"
  else
    echo "source not found: $SOURCE" >&2; exit 1
  fi
else
  URL="https://github.com/firebase/firebase-ios-sdk/releases/download/${VERSION}/Firebase.zip"
  echo "==> Downloading $URL"
  curl -fsSL "$URL" -o "$WORK/Firebase.zip"
  ditto -x -k "$WORK/Firebase.zip" "$WORK/extracted"
  FIREBASE_DIR="$(find "$WORK/extracted" -maxdepth 2 -name "Firebase.h" -exec dirname {} \; | head -1)"
fi
[[ -d "$FIREBASE_DIR" ]] || { echo "could not locate unzipped Firebase dir" >&2; exit 1; }
echo "==> Firebase dir:     $FIREBASE_DIR"

# --- Derive the transitive xcframework set from the product folders -----------
FRAMEWORKS=()
for product in "${PRODUCTS[@]}"; do
  [[ -d "$FIREBASE_DIR/$product" ]] || { echo "no product folder: $product" >&2; exit 1; }
  while IFS= read -r xc; do
    name="$(basename "$xc" .xcframework)"
    [[ " ${FRAMEWORKS[*]:-} " == *" $name "* ]] || FRAMEWORKS+=("$name")
  done < <(find "$FIREBASE_DIR/$product" -maxdepth 1 -name '*.xcframework' | sort)
done
echo "==> Derived ${#FRAMEWORKS[@]} xcframeworks from ${#PRODUCTS[@]} products: ${FRAMEWORKS[*]}"

# --- Split + zip + checksum ---------------------------------------------------
rm -rf "$DIST"; mkdir -p "$DIST"
declare -a CHECKSUM_LINES=()
for name in "${FRAMEWORKS[@]}"; do
  src="$(find "$FIREBASE_DIR" -maxdepth 2 -name "$name.xcframework" | head -1)"
  [[ -d "$src" ]] || { echo "MISSING xcframework: $name" >&2; exit 1; }
  zip="$DIST/$name.xcframework.zip"
  # ditto preserves symlinks (required: README warns plain cp can break the
  # code signature) and packages the .xcframework at the zip root.
  ditto -c -k --sequesterRsrc --keepParent "$src" "$zip"
  sum="$("$SWIFT" package compute-checksum "$zip")"
  printf "    %-38s %s\n" "$name" "$sum"
  CHECKSUM_LINES+=("$name $sum")
done

# --- Regenerate Package.swift binaryTargets block -----------------------------
# Note: keep the git call out of a pipe so a missing `origin` (returns non-zero)
# doesn't abort the script under `set -o pipefail`.
ORIGIN_URL="$(git -C "$REPO_ROOT" remote get-url origin 2>/dev/null || true)"
OWNER_REPO="$(printf '%s' "$ORIGIN_URL" | sed -E 's#(git@github.com:|https://github.com/)##; s#\.git$##')"
OWNER_REPO="${OWNER_REPO:-natanrolnik/firebase-shell}"
BASE_URL="https://github.com/${OWNER_REPO}/releases/download/${VERSION}"

GEN="$WORK/binaryTargets.swift"
{
  echo "        // GENERATED by Scripts/make-release.sh for Firebase ${VERSION}."
  echo "        // Do not edit by hand; re-run the script to bump versions."
  for line in "${CHECKSUM_LINES[@]}"; do
    name="${line%% *}"; sum="${line##* }"
    echo "        .binaryTarget("
    echo "            name: \"${name}\","
    echo "            url: \"${BASE_URL}/${name}.xcframework.zip\","
    echo "            checksum: \"${sum}\""
    echo "        ),"
  done
} > "$GEN"

PKG="$REPO_ROOT/Package.swift"
if grep -q "// BINARY_TARGETS_BEGIN" "$PKG" 2>/dev/null; then
  awk -v genfile="$GEN" '
    /\/\/ BINARY_TARGETS_BEGIN/ { print; while ((getline l < genfile) > 0) print l; skip=1; next }
    /\/\/ BINARY_TARGETS_END/ { skip=0 }
    !skip { print }
  ' "$PKG" > "$PKG.tmp" && mv "$PKG.tmp" "$PKG"
  # Also bump the recorded version marker.
  sed -i '' -E "s#(let firebaseVersion = \")[^\"]*(\")#\1${VERSION}\2#" "$PKG" || true
  echo "==> Regenerated binaryTargets in $PKG"
else
  echo "!! Package.swift has no BINARY_TARGETS markers; writing block to $DIST/binaryTargets.swift for manual paste"
  cp "$GEN" "$DIST/binaryTargets.swift"
fi

# --- Optional upload ----------------------------------------------------------
if [[ "$DO_UPLOAD" == "1" ]]; then
  command -v gh >/dev/null || { echo "gh not found" >&2; exit 1; }
  if ! gh release view "$VERSION" >/dev/null 2>&1; then
    gh release create "$VERSION" --title "Firebase $VERSION" \
      --notes "Per-xcframework repackaging of Firebase $VERSION (firebase-ios-sdk)."
  fi
  echo "==> Uploading ${#FRAMEWORKS[@]} assets to release $VERSION"
  gh release upload "$VERSION" "$DIST"/*.xcframework.zip --clobber
fi

echo "==> Done. Firebase $VERSION."
