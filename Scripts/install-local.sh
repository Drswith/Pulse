#!/bin/bash
#
# Builds Pulse for this Mac only and puts it in /Applications, replacing the
# copy there: quit it, swap it, open the new one. For a Pulse you build for
# yourself; releases go through bundle.sh, which builds both architectures.
#
#   ./Scripts/install-local.sh
#   PULSE_SIGN_IDENTITY="<name or SHA-1>" ./Scripts/install-local.sh
#
# Signed with the keychain's one valid Apple Development identity, or with
# PULSE_SIGN_IDENTITY ("-" keeps ad-hoc). Nothing is touched if the build or
# the signing fails — the installed copy keeps running.

set -euo pipefail

cd "$(dirname "$0")/.."

# The hardware's architecture, not the shell's: uname -m says x86_64 under Rosetta.
if [ "$(sysctl -in hw.optional.arm64)" = 1 ]; then ARCH=arm64; else ARCH=x86_64; fi
APP="build.noindex/Pulse.app"
DEST="/Applications/Pulse.app"

# bundle.sh with its one pair of --arch flags swapped for this Mac's own,
# rather than a second copy of it to keep in step. The Xcode build system is
# forced because a single --arch otherwise gets SwiftPM's native one, whose
# Bundle.module looks beside the .app and then in .build — never in
# Contents/Resources — so the installed app would crash at launch as soon as
# .build was cleaned.
UNIVERSAL="--arch arm64 --arch x86_64"
if ! grep -q -- "$UNIVERSAL" Scripts/bundle.sh; then
    echo "Scripts/bundle.sh no longer builds with '$UNIVERSAL'; update this script to match." >&2
    exit 1
fi

# Its SDK stamp check reads the stamp back off both slices after linking. A
# build for this Mac has one, and the slice that is not there reads as
# "sdk none" — the check's own way of saying the stamp never took — so it
# would refuse the bundle it was just asked to make. Swapped the same way as
# the flags above, and guarded the same way.
SLICES="for arch in arm64 x86_64; do"
if ! grep -q -- "$SLICES" Scripts/bundle.sh; then
    echo "Scripts/bundle.sh no longer checks the SDK stamp with '$SLICES'; update this script to match." >&2
    exit 1
fi

bash -c "$(sed -e "s/$UNIVERSAL/--arch $ARCH --build-system xcode/" \
               -e "s/$SLICES/for arch in $ARCH; do/" \
               -e "s/(universal)/($ARCH)/" Scripts/bundle.sh)" Scripts/bundle.sh

# A certificate rather than bundle.sh's ad-hoc signature, which is the binary's
# own hash: every rebuild is then a stranger to the keychain's "Always Allow"
# list and to privacy grants such as Full Disk Access. Which certificate is
# looked up here, never written down: PULSE_SIGN_IDENTITY if set, otherwise
# the one valid Apple Development identity. More than one is not guessed
# between — a pick that changed from run to run would bring the prompts back.
IDENTITY="${PULSE_SIGN_IDENTITY:-}"
if [ -z "$IDENTITY" ]; then
    FOUND="$(security find-identity -v -p codesigning | awk '/"Apple Development: / {print $2}' | sort -u)"
    if [ -z "$FOUND" ]; then
        IDENTITY="-"
        echo "No Apple Development identity: keeping the ad-hoc signature, so the keychain will ask again."
    elif [ "$(printf '%s\n' "$FOUND" | wc -l | tr -d ' ')" -gt 1 ]; then
        echo "More than one Apple Development identity; set PULSE_SIGN_IDENTITY to one of:" >&2
        security find-identity -v -p codesigning | grep '"Apple Development: ' >&2
        exit 1
    else
        IDENTITY="$FOUND"
    fi
fi
if [ "$IDENTITY" != "-" ]; then
    # Inside out, as bundle.sh signs: Sparkle's nested bundles before the app.
    codesign --force --deep --timestamp=none --sign "$IDENTITY" "$APP/Contents/Frameworks/Sparkle.framework"
    codesign --force --deep --timestamp=none --sign "$IDENTITY" "$APP"
    codesign --verify --deep --strict "$APP"
    echo "Signed by $(codesign -dvv "$APP" 2>&1 | awk -F= '/^Authority=/ {print $2; exit}')"
fi

# Pulse does no work on quit, so SIGTERM loses nothing — and unlike asking it
# to quit over Apple events, needs no permission to script another app. Wait
# for it to go before swapping the bundle out from under it.
if pkill -f "$DEST/Contents/MacOS/Pulse"; then
    for _ in {1..50}; do
        pgrep -qf "$DEST/Contents/MacOS/Pulse" || break
        sleep 0.1
    done
fi

rm -rf "$DEST"
ditto "$APP" "$DEST"
open "$DEST"
echo "→ $DEST ($ARCH)"
