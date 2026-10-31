#!/usr/bin/env bash
# Builds /dev/null for Mac as a universal app, packs it in the DMG the website serves at /downloads/DevNull.dmg, and
# writes /downloads/DevNull.json beside it: the release that /apps shows and the app's update check compares with.
#
# Signing, from most to least trusted:
#   DEVELOPER_ID="Developer ID Application: …" NOTARY_PROFILE=<notarytool keychain profile>
#       Signs with the hardened runtime and a secure timestamp, notarizes the DMG with Apple and staples the ticket,
#       so the app opens on any Mac without a warning. Create the profile once with
#       `xcrun notarytool store-credentials <profile> --apple-id … --team-id …`.
#   SIGN_IDENTITY=<certificate name or SHA-1>
#       Any other certificate. It keeps the app's identity stable across builds, so the Keychain doesn't ask for the
#       device key again after each update, but macOS asks people to approve the app the first time they open it.
#   Neither: signed ad hoc, for trying a build on this Mac only.
#
# APP_STORE_PROFILE=<Mac App Store provisioning profile> builds for the Mac App Store instead: sandboxed, without the
# update check, signed with the Apple Distribution certificate and packed in .build/package/DevNull.pkg for Transporter.
# It leaves the DMG and the release file alone.
#
# Needs Xcode (actool compiles the icon), a git checkout (the build number comes from the commit count) and the website
# checked out beside this repository, at ../dev-null.sh.
set -euo pipefail

cd "$(dirname "$0")/.."

ROOT="$(pwd)"
BUILD="$ROOT/.build/package"
APP="$BUILD/DevNull.app"
DOWNLOADS="$ROOT/../dev-null.sh/public/downloads"
DMG="$DOWNLOADS/DevNull.dmg"
RELEASE="$DOWNLOADS/DevNull.json"
VOLUME="DevNull"

VERSION="$(plutil -extract CFBundleShortVersionString raw Info.plist)"
MINIMUM_SYSTEM_VERSION="$(plutil -extract LSMinimumSystemVersion raw Info.plist)"
# Builds up to 888 came from the website repository, so this one counts on from there and installed apps see an update.
BUILD_NUMBER="$((888 + $(git rev-list --count HEAD)))"
REVISION="$(git rev-parse --short=8 HEAD)"
if [[ -n "$(git status --porcelain -- "$ROOT")" ]]; then
    REVISION="$REVISION-dirty"
fi

if [[ -n "${NOTARY_PROFILE:-}" && -z "${DEVELOPER_ID:-}" ]]; then
    echo "NOTARY_PROFILE needs DEVELOPER_ID: Apple only notarizes apps signed with a Developer ID." >&2
    exit 1
fi

fail() {
    echo "error: $1" >&2
    exit 1
}

rm -rf "$BUILD"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/en.lproj" "$DOWNLOADS"

# MARK: App

SWIFT_FLAGS=(-c release --arch arm64 --arch x86_64)
if [[ -n "${APP_STORE_PROFILE:-}" ]]; then
    SWIFT_FLAGS+=(-Xswiftc -DAPP_STORE)
fi

swift build "${SWIFT_FLAGS[@]}"

# Where SwiftPM put the build depends on the toolchain's build system, so ask it rather than guess.
cp "$(swift build "${SWIFT_FLAGS[@]}" --show-bin-path)/DevNull" "$APP/Contents/MacOS/DevNull"
cp "$ROOT/Sources/DevNull/Resources/emoji-shortcodes.json" "$ROOT/Sources/DevNull/Resources/emoji-categories.json" "$ROOT/Sources/DevNull/Resources/remote.mp3" "$ROOT/Sources/DevNull/Resources/ping.mp3" "$ROOT/Sources/DevNull/Resources/ring.mp3" "$ROOT/Sources/DevNull/Resources/ringback.mp3" "$ROOT/Sources/DevNull/Resources/hangup.mp3" "$APP/Contents/Resources/"

cp "$ROOT/Info.plist" "$APP/Contents/Info.plist"
plutil -replace CFBundleVersion -string "$BUILD_NUMBER" "$APP/Contents/Info.plist"
plutil -replace DevNullRevision -string "$REVISION" "$APP/Contents/Info.plist"

# The file is DevNull.app; the menu bar, About, notifications, Finder, the Dock and Spotlight say "/dev/null".
plutil -replace LSHasLocalizedDisplayName -bool true "$APP/Contents/Info.plist"
cp "$ROOT/Sources/DevNull/Resources/en.lproj/InfoPlist.strings" "$APP/Contents/Resources/en.lproj/"

# The Icon Composer icon for macOS 26 and later, and the classic one, hinted for small sizes, for 14 and 15.
swift "$ROOT/scripts/make-icon.swift" "$BUILD/icon"
xcrun actool "$BUILD/icon/AppIcon.icon" --compile "$APP/Contents/Resources" --platform macosx \
    --minimum-deployment-target "$MINIMUM_SYSTEM_VERSION" --app-icon AppIcon \
    --output-partial-info-plist "$BUILD/icon/partial.plist" >/dev/null
iconutil -c icns "$BUILD/icon/AppIcon.iconset" -o "$APP/Contents/Resources/AppIcon.icns"

if [[ -n "${APP_STORE_PROFILE:-}" ]]; then
    cp "$APP_STORE_PROFILE" "$APP/Contents/embedded.provisionprofile"
    # The App Store rejects quarantined files, like the profile the browser downloaded.
    xattr -dr com.apple.quarantine "$APP"
    codesign --force --timestamp --entitlements "$ROOT/DevNull.AppStore.entitlements" --sign "Apple Distribution" "$APP"
elif [[ -n "${DEVELOPER_ID:-}" ]]; then
    codesign --force --options runtime --timestamp --entitlements "$ROOT/DevNull.entitlements" --sign "$DEVELOPER_ID" "$APP"
else
    codesign --force --options runtime --entitlements "$ROOT/DevNull.entitlements" --sign "${SIGN_IDENTITY:--}" "$APP"
fi

# MARK: Checks

codesign --verify --deep --strict "$APP" || fail "the app's signature doesn't verify"

for arch in arm64 x86_64; do
    [[ " $(lipo -archs "$APP/Contents/MacOS/DevNull") " == *" $arch "* ]] || fail "the binary has no $arch slice"
done

codesign -d --entitlements - --xml "$APP" 2>/dev/null | grep -q "com.apple.security.device.audio-input" \
    || fail "the microphone entitlement is missing, so voice notes can't record"
codesign -d --entitlements - --xml "$APP" 2>/dev/null | grep -q "com.apple.security.device.camera" \
    || fail "the camera entitlement is missing, so calls can't turn the camera on"

[[ "$(plutil -extract CFBundleVersion raw "$APP/Contents/Info.plist")" == "$BUILD_NUMBER" ]] || fail "the build number wasn't stamped"
[[ "$(plutil -extract CFBundleIdentifier raw "$APP/Contents/Info.plist")" == "sh.dev-null.mac" ]] || fail "the bundle identifier changed"

for resource in emoji-shortcodes.json emoji-categories.json remote.mp3 ping.mp3 ring.mp3 ringback.mp3 hangup.mp3 AppIcon.icns Assets.car en.lproj/InfoPlist.strings; do
    [[ -s "$APP/Contents/Resources/$resource" ]] || fail "$resource is missing from the app"
done

# The preview's made-up data and its commands are DEBUG-only and must never ship.
[[ "$(strings "$APP/Contents/MacOS/DevNull" | grep -c "preview.dev-null.invalid" || true)" == "0" ]] || fail "the release binary contains preview code"

# MARK: App Store

if [[ -n "${APP_STORE_PROFILE:-}" ]]; then
    codesign -d --entitlements - --xml "$APP" 2>/dev/null | grep -q "com.apple.security.app-sandbox" \
        || fail "the sandbox entitlement is missing, so the App Store rejects the build"
    [[ -z "$(xattr -lr "$APP" | grep com.apple.quarantine || true)" ]] || fail "a file in the app is quarantined, so the App Store rejects the build"

    productbuild --component "$APP" /Applications --sign "3rd Party Mac Developer Installer" "$BUILD/DevNull.pkg" >/dev/null

    echo "Built $BUILD/DevNull.pkg: /dev/null $VERSION ($BUILD_NUMBER, $REVISION) for the Mac App Store"
    exit 0
fi

# MARK: DMG

STAGE="$BUILD/dmg"
mkdir -p "$STAGE/.background"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
cp "$APP/Contents/Resources/AppIcon.icns" "$STAGE/.VolumeIcon.icns"

swift "$ROOT/scripts/make-dmg-background.swift" "$BUILD/background" "$([[ -n "${NOTARY_PROFILE:-}" ]] && echo 1 || echo 0)"
tiffutil -cathidpicheck "$BUILD/background/background.png" "$BUILD/background/background@2x.png" -out "$STAGE/.background/background.tiff" >/dev/null 2>&1

# Finder lays the window out from a writable copy: size, icon positions and the background, saved in its .DS_Store.
if [[ -d "/Volumes/$VOLUME" ]]; then
    hdiutil detach "/Volumes/$VOLUME" -force -quiet
fi
hdiutil create -volname "$VOLUME" -srcfolder "$STAGE" -fs HFS+ -format UDRW -ov "$BUILD/DevNull-rw.dmg" >/dev/null 2>&1
DEVICE="$(hdiutil attach -readwrite -noverify -noautoopen "$BUILD/DevNull-rw.dmg" 2>/dev/null | awk '/Apple_HFS/ { print $1 }')"
MOUNT="/Volumes/$VOLUME"

# The volume shows the app's icon.
xattr -wx com.apple.FinderInfo "0000000000000000040000000000000000000000000000000000000000000000" "$MOUNT"

# Finder learns about the new volume a moment after it mounts; asking before then fails with "Can't get disk".
for _ in {1..20}; do
    osascript -e "tell application \"Finder\" to exists disk \"$VOLUME\"" 2>/dev/null | grep -q true && break
    sleep 0.5
done

osascript <<APPLESCRIPT
tell application "Finder"
    tell disk "$VOLUME"
        open
        set current view of container window to icon view
        set toolbar visible of container window to false
        set statusbar visible of container window to false
        set the bounds of container window to {200, 120, 840, 548}
        set options to the icon view options of container window
        set arrangement of options to not arranged
        set icon size of options to 128
        set text size of options to 13
        set background picture of options to file ".background:background.tiff"
        set position of item "DevNull.app" of container window to {170, 190}
        set position of item "Applications" of container window to {470, 190}
        update without registering applications
        delay 1
        close
    end tell
end tell
APPLESCRIPT

[[ -f "$MOUNT/.DS_Store" ]] || fail "Finder didn't save the window layout"
rm -rf "$MOUNT/.fseventsd" "$MOUNT/.Trashes"
sync
hdiutil detach "$DEVICE" -quiet

rm -f "$DMG"
hdiutil convert "$BUILD/DevNull-rw.dmg" -format ULFO -o "$DMG" >/dev/null 2>&1

if [[ -n "${DEVELOPER_ID:-}" ]]; then
    codesign --force --timestamp --sign "$DEVELOPER_ID" "$DMG"
elif [[ -n "${SIGN_IDENTITY:-}" ]]; then
    codesign --force --sign "$SIGN_IDENTITY" "$DMG"
fi

NOTARIZED=false
if [[ -n "${NOTARY_PROFILE:-}" ]]; then
    xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
    xcrun stapler staple "$DMG"
    xcrun stapler validate "$DMG"
    spctl --assess --type open --context context:primary-signature --verbose=2 "$DMG" || fail "Gatekeeper rejects the DMG"
    NOTARIZED=true
fi

# Gatekeeper's verdict on the app as a downloaded copy would get it: accepted only for a notarized Developer ID build.
if [[ "$NOTARIZED" == true ]]; then
    spctl --assess --type execute --verbose=2 "$APP" || fail "Gatekeeper rejects the app"
else
    spctl --assess --type execute --verbose=2 "$APP" 2>&1 | sed 's/^/gatekeeper: /' || true
fi

# MARK: Release

cat > "$RELEASE" <<JSON
{
    "version": "$VERSION",
    "build": $BUILD_NUMBER,
    "revision": "$REVISION",
    "released_at": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
    "minimum_system_version": "$MINIMUM_SYSTEM_VERSION",
    "notarized": $NOTARIZED,
    "size": $(stat -f%z "$DMG"),
    "sha256": "$(shasum -a 256 "$DMG" | awk '{ print $1 }')"
}
JSON

echo "Built $DMG: /dev/null $VERSION ($BUILD_NUMBER, $REVISION)$([[ "$NOTARIZED" == true ]] && echo ", notarized")"
