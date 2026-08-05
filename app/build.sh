#!/usr/bin/env bash
# ==============================================================================
# build.sh - Xcode 없이 SwiftUI 앱을 .app 번들로 빌드합니다.
#   Command Line Tools 의 swiftc 만으로 컴파일하고, 번들을 직접 구성한 뒤
#   ad-hoc 코드서명을 붙입니다.
#
#   사용법:
#     ./build.sh              # 빌드 (app/build/Palworld 서버.app)
#     ./build.sh --install    # 빌드 후 /Applications 에 설치
#     ./build.sh --run        # 빌드 후 바로 실행
# ==============================================================================
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"

APP_NAME="Palworld 서버"
BUNDLE_ID="local.palworld.servercontrol"
MIN_MACOS="14.0"
BUILD_DIR="build"
APP_BUNDLE="$BUILD_DIR/$APP_NAME.app"
SCRIPTS_DIR="$(cd .. && pwd)"   # 상위 폴더 = 셸 스크립트들이 있는 곳

c_grn=$'\033[32m'; c_red=$'\033[31m'; c_blu=$'\033[34m'; c_rst=$'\033[0m'
info() { printf '%s==>%s %s\n' "$c_blu" "$c_rst" "$*"; }
ok()   { printf '%s ✔%s  %s\n' "$c_grn" "$c_rst" "$*"; }
die()  { printf '%s ✘%s  %s\n' "$c_red" "$c_rst" "$*" >&2; exit 1; }

command -v swiftc >/dev/null 2>&1 \
  || die "swiftc 가 없습니다. Xcode Command Line Tools 를 설치하세요: xcode-select --install"

info "Swift: $(swiftc --version 2>/dev/null | head -1)"

# ------------------------------------------------------------------ 컴파일
rm -rf "$BUILD_DIR"
mkdir -p "$APP_BUNDLE/Contents/MacOS" "$APP_BUNDLE/Contents/Resources"

info "컴파일 중..."
# -parse-as-library: 파일명이 main.swift 가 아닐 때 @main 을 쓰려면 필요합니다.
# -swift-version 5 : Swift 6 엄격 동시성 검사를 피해 빌드를 단순하게 유지합니다.
swiftc \
  -O \
  -parse-as-library \
  -swift-version 5 \
  -target "arm64-apple-macosx${MIN_MACOS}" \
  -framework SwiftUI -framework AppKit \
  -o "$APP_BUNDLE/Contents/MacOS/PalworldServer" \
  Sources/*.swift

ok "컴파일 완료"

# ------------------------------------------------------------------ 번들 구성
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
    <!-- 앱이 실행할 셸 스크립트들의 위치. 앱 설정에서 변경할 수 있습니다. -->
    <key>PWScriptsDirectory</key>          <string>${SCRIPTS_DIR}</string>
</dict>
</plist>
EOF

printf 'APPL????' > "$APP_BUNDLE/Contents/PkgInfo"

# ------------------------------------------------------------------ 지역화
# Xcode 없이 빌드하므로 String Catalog(.xcstrings)는 쓸 수 없습니다.
# 고전적인 .lproj/Localizable.strings 를 번들 Resources 에 그대로 복사합니다.
if [[ -d Resources ]]; then
  copied=0
  for d in Resources/*.lproj; do
    [[ -d "$d" ]] || continue
    cp -R "$d" "$APP_BUNDLE/Contents/Resources/"
    copied=$((copied + 1))
  done
  ok "지역화 리소스 ${copied}개 언어 포함"
fi

# ------------------------------------------------------------------ 코드서명
# 배포용 인증서가 없으므로 ad-hoc 서명합니다. 로컬 빌드라 quarantine 이
# 붙지 않아 Gatekeeper 경고 없이 실행됩니다.
info "ad-hoc 코드서명..."
codesign --force --deep --sign - "$APP_BUNDLE" 2>/dev/null \
  || die "코드서명 실패"
codesign --verify --deep "$APP_BUNDLE" 2>/dev/null \
  || die "코드서명 검증 실패"
ok "서명 검증 통과"

ok "빌드 완료: $PWD/$APP_BUNDLE"
info "스크립트 폴더: $SCRIPTS_DIR"

# ------------------------------------------------------------------ 후속 동작
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
