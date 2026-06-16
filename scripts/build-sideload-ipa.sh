#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT_PATH="$ROOT_DIR/winston.xcodeproj"
SCHEME="${SCHEME:-winston}"
CONFIGURATION="${CONFIGURATION:-Release}"
DESTINATION="${DESTINATION:-generic/platform=iOS}"
SDK="${SDK:-iphoneos}"
XCODE_APP="${XCODE_APP:-}"
BUILD_ROOT="${BUILD_ROOT:-$ROOT_DIR/build/sideload-ipa}"
DERIVED_DATA_PATH="$BUILD_ROOT/DerivedData"
PACKAGE_DIR="$BUILD_ROOT/package"
OUTPUT_IPA="${OUTPUT_IPA:-$ROOT_DIR/build/winston-sideload.ipa}"
CLEAN=1

if [[ -z "${DEVELOPER_DIR:-}" && -z "$XCODE_APP" && -d /Applications/Xcode-beta.app ]]; then
  XCODE_APP=/Applications/Xcode-beta.app
fi

usage() {
  cat <<'USAGE'
Build an unsigned iOS IPA suitable for tools like Sideloadly.

Usage:
  scripts/build-sideload-ipa.sh [options]

Options:
  --scheme NAME          Xcode scheme to build. Default: winston
  --configuration NAME   Build configuration. Default: Release
  --sdk SDK              Xcode SDK. Default: iphoneos
  --xcode PATH           Xcode app or Developer dir. Default: Xcode-beta.app when present
  --output PATH          IPA output path. Default: build/winston-sideload.ipa
  --destination VALUE    Xcode destination. Default: generic/platform=iOS
  --no-clean             Do not clean before building.
  -h, --help             Show this help.

Environment overrides:
  SCHEME, CONFIGURATION, SDK, DESTINATION, XCODE_APP, DEVELOPER_DIR,
  BUILD_ROOT, OUTPUT_IPA
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --scheme)
      SCHEME="$2"
      shift 2
      ;;
    --configuration)
      CONFIGURATION="$2"
      shift 2
      ;;
    --sdk)
      SDK="$2"
      shift 2
      ;;
    --xcode)
      XCODE_APP="$2"
      shift 2
      ;;
    --output)
      OUTPUT_IPA="$2"
      shift 2
      ;;
    --destination)
      DESTINATION="$2"
      shift 2
      ;;
    --no-clean)
      CLEAN=0
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

if [[ ! -d "$PROJECT_PATH" ]]; then
  echo "Missing Xcode project: $PROJECT_PATH" >&2
  exit 1
fi

if [[ -n "$XCODE_APP" ]]; then
  if [[ "$XCODE_APP" == */Contents/Developer ]]; then
    export DEVELOPER_DIR="$XCODE_APP"
  else
    export DEVELOPER_DIR="$XCODE_APP/Contents/Developer"
  fi
fi

mkdir -p "$(dirname "$OUTPUT_IPA")" "$BUILD_ROOT"

build_action=(build)
if [[ "$CLEAN" -eq 1 ]]; then
  build_action=(clean build)
fi

echo "Using developer dir: ${DEVELOPER_DIR:-$(xcode-select -p)}"
echo "Building $SCHEME ($CONFIGURATION) for $SDK without code signing..."
xcodebuild \
  -project "$PROJECT_PATH" \
  -scheme "$SCHEME" \
  -configuration "$CONFIGURATION" \
  -sdk "$SDK" \
  -destination "$DESTINATION" \
  -derivedDataPath "$DERIVED_DATA_PATH" \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGN_IDENTITY="" \
  "${build_action[@]}"

PRODUCTS_DIR="$DERIVED_DATA_PATH/Build/Products/$CONFIGURATION-iphoneos"
APP_PATH="$(find "$PRODUCTS_DIR" -maxdepth 1 -name '*.app' -type d -print -quit)"

if [[ -z "$APP_PATH" ]]; then
  echo "No .app bundle found in $PRODUCTS_DIR" >&2
  exit 1
fi

rm -rf "$PACKAGE_DIR" "$OUTPUT_IPA"
mkdir -p "$PACKAGE_DIR/Payload"

APP_NAME="$(basename "$APP_PATH")"
ditto "$APP_PATH" "$PACKAGE_DIR/Payload/$APP_NAME"

echo "Packaging $OUTPUT_IPA..."
(
  cd "$PACKAGE_DIR"
  zip -qry "$OUTPUT_IPA" Payload
)

echo "Created: $OUTPUT_IPA"
