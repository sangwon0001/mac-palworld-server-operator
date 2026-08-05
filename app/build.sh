#!/usr/bin/env bash
# ==============================================================================
# build.sh - Build the SwiftUI app into a .app bundle without Xcode
#   Compiles with swiftc from the Command Line Tools, assembles the bundle by hand
#   and applies an ad-hoc code signature.
#
#   Usage:
#     ./build.sh              # build into app/build/
#     ./build.sh --install    # build, then install into /Applications
#     ./build.sh --run        # build, then launch
# ==============================================================================
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"

APP_NAME="Palworld 서버"
BUNDLE_ID="local.palworld.servercontrol"
MIN_MACOS="14.0"
BUILD_DIR="build"
APP_BUNDLE="$BUILD_DIR/$APP_NAME.app"
SCRIPTS_DIR="$(cd .. && pwd)"   # the parent folder holds the shell scripts

c_grn=$'\033[32m'; c_red=$'\033[31m'; c_blu=$'\033[34m'; c_rst=$'\033[0m'
info() { printf '%s==>%s %s\n' "$c_blu" "$c_rst" "$*"; }
ok()   { printf '%s ✔%s  %s\n' "$c_grn" "$c_rst" "$*"; }
die()  { printf '%s ✘%s  %s\n' "$c_red" "$c_rst" "$*" >&2; exit 1; }

command -v swiftc >/dev/null 2>&1 \
  || die "swiftc 가 없습니다. Xcode Command Line Tools 를 설치하세요: xcode-select --install"

info "Swift: $(swiftc --version 2>/dev/null | head -1)"

# ------------------------------------------------------------------ Compile
rm -rf "$BUILD_DIR"
mkdir -p "$APP_BUNDLE/Contents/MacOS" "$APP_BUNDLE/Contents/Resources"

info "컴파일 중..."
# -parse-as-library: required to use @main when the file isn't named main.swift.
# -swift-version 5 : avoids Swift 6 strict concurrency checking, keeping the build simple.
swiftc \
  -O \
  -parse-as-library \
  -swift-version 5 \
  -target "arm64-apple-macosx${MIN_MACOS}" \
  -framework SwiftUI -framework AppKit \
  -o "$APP_BUNDLE/Contents/MacOS/PalworldServer" \
  Sources/*.swift

ok "컴파일 완료"

# ------------------------------------------------------------------ Assemble bundle
cat > "$APP_BUNDLE/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>          <string>PalworldServer</string>
    <key>CFBundleIdentifier</key>          <string>${BUNDLE_ID}</string>
    <key>CFBundleName</key>                <string>${APP_NAME}</string>
    <key>CFBundleDisplayName</key>         <string>${APP_NAME}</string>
    <key>CFBundlePackageType</key>         <string>APPL</string>
    <key>CFBundleShortVersionString</key>  <string>1.0</string>
    <key>CFBundleVersion</key>             <string>1</string>
    <key>LSMinimumSystemVersion</key>      <string>${MIN_MACOS}</string>
    <key>NSHighResolutionCapable</key>     <true/>
    <key>CFBundleDevelopmentRegion</key>   <string>ko</string>
    <key>CFBundleLocalizations</key>
    <array>
        <string>ko</string>
        <string>en</string>
        <string>ja</string>
    </array>
    <!-- Where the shell scripts live; changeable from the app's settings. -->
    <key>PWScriptsDirectory</key>          <string>${SCRIPTS_DIR}</string>
</dict>
</plist>
EOF

printf 'APPL????' > "$APP_BUNDLE/Contents/PkgInfo"

# ------------------------------------------------------------------ Localization
# Building without Xcode rules out String Catalogs (.xcstrings), so the classic
# .lproj/Localizable.strings files are copied into the bundle's Resources.
if [[ -d Resources ]]; then
  copied=0
  for d in Resources/*.lproj; do
    [[ -d "$d" ]] || continue
    cp -R "$d" "$APP_BUNDLE/Contents/Resources/"
    copied=$((copied + 1))
  done
  ok "지역화 리소스 ${copied}개 언어 포함"
fi

# ------------------------------------------------------------------ Code signing
# No distribution certificate, so sign ad-hoc. A local build carries no quarantine
# attribute, so it launches without a Gatekeeper prompt.
info "ad-hoc 코드서명..."
codesign --force --deep --sign - "$APP_BUNDLE" 2>/dev/null \
  || die "코드서명 실패"
codesign --verify --deep "$APP_BUNDLE" 2>/dev/null \
  || die "코드서명 검증 실패"
ok "서명 검증 통과"

ok "빌드 완료: $PWD/$APP_BUNDLE"
info "스크립트 폴더: $SCRIPTS_DIR"

# ------------------------------------------------------------------ Follow-up
case "${1:-}" in
  --install)
    info "/Applications 에 설치 중..."
    rm -rf "/Applications/$APP_NAME.app"
    cp -R "$APP_BUNDLE" /Applications/
    ok "설치 완료: /Applications/$APP_NAME.app"
    ;;
  --run)
    info "실행 중..."
    open "$APP_BUNDLE"
    ;;
esac
