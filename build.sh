#!/bin/bash
# SquidToPullOverX 打包脚本 — roothide (隐根)
set -euo pipefail
cd "$(dirname "$0")"

SCHEME="${1:-roothide}"
CONFIG_ARG="${2:-release}"
case "$CONFIG_ARG" in
    debug|Debug)     CONFIGURATION="Debug" ;;
    release|Release) CONFIGURATION="Release" ;;
    *) echo "error: unknown config '$CONFIG_ARG'"; exit 1 ;;
esac

case "$SCHEME" in
    roothide)
        PREFIX=""
        DEB_ARCH="iphoneos-arm64e"
        ARCHS="arm64 arm64e"
        POP_SCHEME_DEFS="THEOS_PACKAGE_SCHEME_ROOTHIDE=1"
        POP_ROOTHIDE_LDFLAGS="-lroothide"
        POP_RPATHS=""
        ;;
    rootless)
        PREFIX="/var/jb"
        DEB_ARCH="iphoneos-arm64"
        ARCHS="arm64 arm64e"
        POP_SCHEME_DEFS="ROOTHIDE_USE_STUB=1"
        POP_ROOTHIDE_LDFLAGS=""
        POP_RPATHS="/var/jb/usr/lib /var/jb/Library/Frameworks @loader_path/.jbroot/usr/lib"
        ;;
    rootful)
        PREFIX=""
        DEB_ARCH="iphoneos-arm"
        ARCHS="arm64"
        POP_SCHEME_DEFS="ROOTHIDE_USE_STUB=1"
        POP_ROOTHIDE_LDFLAGS=""
        POP_RPATHS=""
        ;;
    *) echo "error: unknown scheme '$SCHEME'"; exit 1 ;;
esac
echo "==> Build SquidToPullOverX [scheme=$SCHEME arch=$ARCHS deb=$DEB_ARCH]"

BUILD_ROOT="$PWD/build"
BUILD_DIR="$BUILD_ROOT/$SCHEME"
PRODUCTS_DIR="$BUILD_DIR/products"
trap 'rm -rf "$BUILD_ROOT"' EXIT
rm -rf "$BUILD_DIR"; mkdir -p "$PRODUCTS_DIR"; DERIVED="$BUILD_DIR/derived"

xcodebuild -project SquidToPullOverX.xcodeproj -target SquidToPullOverX \
  -configuration "$CONFIGURATION" \
  -sdk iphoneos ARCHS="$ARCHS" VALID_ARCHS="$ARCHS" ONLY_ACTIVE_ARCH=NO \
  POP_SCHEME="$SCHEME" POP_ROOTHIDE_LDFLAGS="$POP_ROOTHIDE_LDFLAGS" \
  POP_SCHEME_DEFS="$POP_SCHEME_DEFS" \
  LD_RUNPATH_SEARCH_PATHS="$POP_RPATHS" \
  SYMROOT="$BUILD_DIR/build" OBJROOT="$BUILD_DIR/obj" \
  CONFIGURATION_BUILD_DIR="$PRODUCTS_DIR" \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO \
  build >/dev/null 2>&1 || {
    xcodebuild -project SquidToPullOverX.xcodeproj -target SquidToPullOverX \
      -configuration "$CONFIGURATION" \
      -sdk iphoneos ARCHS="$ARCHS" VALID_ARCHS="$ARCHS" ONLY_ACTIVE_ARCH=NO \
      POP_SCHEME="$SCHEME" POP_ROOTHIDE_LDFLAGS="$POP_ROOTHIDE_LDFLAGS" \
      POP_SCHEME_DEFS="$POP_SCHEME_DEFS" \
      SYMROOT="$BUILD_DIR/build" OBJROOT="$BUILD_DIR/obj" \
      CONFIGURATION_BUILD_DIR="$PRODUCTS_DIR" \
      CODE_SIGNING_ALLOWED=NO; exit 1;
  }

DYLIB="$PRODUCTS_DIR/SquidToPullOverX.dylib"
[ -f "$DYLIB" ] || { echo "error: $DYLIB not built"; exit 1; }
if command -v ldid >/dev/null 2>&1; then ldid -S "$DYLIB"; fi

STAGE="$BUILD_DIR/stage"; ROOT="$STAGE$PREFIX"
mkdir -p "$ROOT/Library/MobileSubstrate/DynamicLibraries"
cp "$DYLIB" "$ROOT/Library/MobileSubstrate/DynamicLibraries/SquidToPullOverX.dylib"
cp "SquidToPullOverX.plist" "$ROOT/Library/MobileSubstrate/DynamicLibraries/SquidToPullOverX.plist"

mkdir -p "$STAGE/DEBIAN"
sed -E "s/^Architecture:.*/Architecture: $DEB_ARCH/" control > "$STAGE/DEBIAN/control"

mkdir -p packages
VERSION="$(sed -n 's/^Version:[[:space:]]*//p' "$STAGE/DEBIAN/control" | tr -d '\r')"
PKGID="$(sed -n 's/^Package:[[:space:]]*//p' "$STAGE/DEBIAN/control" | tr -d '\r')"
DEB="packages/${PKGID}_${VERSION}_${DEB_ARCH}.deb"
chmod -R 0755 "$STAGE/DEBIAN"
dpkg-deb -Zgzip --root-owner-group -b "$STAGE" "$DEB"
echo "==> Done: $DEB"