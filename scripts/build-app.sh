#!/bin/bash
# PokeTokenBarExtended.app 번들 조립 + /Applications 설치
set -euo pipefail
cd "$(dirname "$0")/.."

# ── 버전 (이 저장소의 유일한 정의 지점) ──────────────────────────────────────
# PokeTokenBar Extended 는 상류(chattymin/PokeTokenBar)와 **별개로** 1.0.0 부터 버전을
# 매긴다(사용자 결정 2026-09-15). 개명으로 번들 ID·설치 경로가 갈라져 상류 기준점을 버전에
# 담아 둘 이유가 사라졌다 — 이전 표기 `2.5.3+mobius.1` 은 은퇴했다.
# 업데이트 배너는 이 저장소의 릴리스만 본다(`UpdateChecker.releaseRepo`). 상류를 보면 2.x 가
# 늘 "새 버전"이라 배너가 상시로 뜬다.
# CFBundleVersion 도 같은 값을 쓴다 — 숫자·마침표뿐이라 LaunchServices 비교에 그대로 맞는다.
# `release.sh` 가 이 한 줄(`VERSION=`)을 고친다.
VERSION="1.0.1"
BUNDLE_VERSION="$VERSION"
APP_NAME="PokeTokenBarExtended"
# Finder·메뉴·정보 창에 보이는 표시 이름만 다르게 한다 — CFBundleName(실행파일 이름과 결합돼
# 위 불변식에 걸림, 15자 제한도 있음)은 그대로 두고 CFBundleDisplayName 만 추가한다.
DISPLAY_NAME="PokeTokenBar Extended"
BUILD_DIR="build"
APP="$BUILD_DIR/$APP_NAME.app"

echo "==> swift build -c release"
swift build -c release

echo "==> $APP 조립"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp ".build/release/$APP_NAME" "$APP/Contents/MacOS/$APP_NAME"
# 심볼 strip — 릴리스 바이너리 1.84MB → 0.80MB(-57%). codesign 전에 수행(서명 무효화 방지).
strip -rSTx "$APP/Contents/MacOS/$APP_NAME" 2>/dev/null || strip -rSx "$APP/Contents/MacOS/$APP_NAME"
cp assets/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key><string>io.github.sun007021.poketokenbarextended</string>
    <key>CFBundleName</key><string>$APP_NAME</string>
    <key>CFBundleDisplayName</key><string>$DISPLAY_NAME</string>
    <key>CFBundleExecutable</key><string>$APP_NAME</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleVersion</key><string>$BUNDLE_VERSION</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>LSUIElement</key><true/>
    <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

# 크래시/OOM(exit≠0) 시 자동 재실행 LaunchAgent(KeepAlive) — SMAppService.agent 가 등록해 launchd 가
# 워치독으로 동작. 정상 종료(exit 0: 사용자 종료·업데이트)엔 재실행 안 함(SuccessfulExit=false).
# ProgramArguments 는 brew 설치 경로(/Applications) 고정. codesign 전에 생성해 서명 seal 에 포함.
mkdir -p "$APP/Contents/Library/LaunchAgents"
cat > "$APP/Contents/Library/LaunchAgents/io.github.sun007021.poketokenbarextended.login.plist" <<AGENT
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key><string>io.github.sun007021.poketokenbarextended.login</string>
    <key>ProgramArguments</key>
    <array>
        <string>/Applications/$APP_NAME.app/Contents/MacOS/$APP_NAME</string>
    </array>
    <key>RunAtLoad</key><true/>
    <key>KeepAlive</key>
    <dict>
        <key>SuccessfulExit</key><false/>
    </dict>
    <key>ThrottleInterval</key><integer>10</integer>
    <key>LimitLoadToSessionType</key><string>Aqua</string>
    <key>ProcessType</key><string>Interactive</string>
</dict>
</plist>
AGENT

echo "==> codesign"
SIGN_IDENTITY="${CODESIGN_IDENTITY:-PokeTokenBar Local}"
# 안정적 Keychain ACL 을 위해서는 인증서 존재가 아니라 유효한 codesigning identity 가 필요하다.
if security find-identity -v -p codesigning | grep -F "\"$SIGN_IDENTITY\"" >/dev/null; then
    # 안정적 서명 신원 → 재빌드해도 Keychain "항상 허용" 유지
    if [[ "$SIGN_IDENTITY" == "Developer ID Application:"* ]]; then
        # 배포(공증) 가능한 서명. Apple 공증은 hardened runtime(`--options runtime`)과 secure
        # timestamp 를 요구한다. 이 앱은 JIT·서명 안 된 dylib 로드·Apple Events 를 쓰지 않아
        # 추가 entitlement 없이 돈다(`security`·`claude`·`codex` 는 별도 프로세스라 무관).
        codesign --force --options runtime --timestamp -s "$SIGN_IDENTITY" "$APP"
    else
        codesign --force -s "$SIGN_IDENTITY" "$APP"
    fi
else
    # 인증서 없음 → ad-hoc (빌드마다 cdhash 변경 = Keychain 재프롬프트 가능)
    if [[ "${PTB_REQUIRE_STABLE_SIGN:-0}" == "1" ]]; then
        # 릴리스 경로(release.sh 가 세팅). ad-hoc 릴리스는 사용자 Keychain 승인을 깨므로 절대 금지.
        echo "   ✗ PTB_REQUIRE_STABLE_SIGN=1 인데 '$SIGN_IDENTITY' 유효 identity 없음 → ad-hoc 금지, 중단." >&2
        echo "     ./scripts/create-signing-cert.sh 실행 후 다시 시도하세요." >&2
        exit 1
    fi
    echo "   ('$SIGN_IDENTITY' 유효 codesigning identity 없음 → ad-hoc 서명 — 로컬 개발용)"
    echo "   반복 Keychain 허용 프롬프트를 줄이려면 ./scripts/create-signing-cert.sh 실행 후 다시 빌드하세요."
    codesign --force -s - "$APP"
fi

# 릴리스 패키징(release.sh)은 설치 없이 번들만 만든다 — 실행 중인 앱(계정 전환 중일 수
# 있다)을 죽이고 /Applications 를 갈아끼우는 건 배포 자산을 만드는 일과 무관하다.
if [[ "${PTB_SKIP_INSTALL:-0}" == "1" ]]; then
    echo "완료: $APP (설치 건너뜀 — PTB_SKIP_INSTALL=1)"
    exit 0
fi

echo "==> 기존 인스턴스 종료 + /Applications 설치"
pkill -x "$APP_NAME" 2>/dev/null || true
rm -rf "/Applications/$APP_NAME.app"
cp -R "$APP" /Applications/

echo "완료: open /Applications/$APP_NAME.app"
