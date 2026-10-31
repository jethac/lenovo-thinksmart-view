#!/usr/bin/env bash
# The ai& sign-in and a real reply, end to end on the laptop builds against
# the real https://api.aiand.com: the screen off-screen (--live, a PPM each
# time it settles), straylight-aiand as the daemon, then the sign-in (code,
# address and a QR code in the terminal: scan or open it on a phone and
# approve), then two questions through straylight-listen's responder, then
# sign-out (the key is revoked) unless --keep.
#
#   streams/settings-auth/scripts/laptop-signin.sh [--keep]
#
# Builds first: in straylight-voice, cargo build --release, and the same with
# --manifest-path aiand/Cargo.toml and listen/Cargo.toml. Everything it writes
# is under streams/settings-auth/work/laptop-signin/ (git-ignored); the key
# is in state/credentials.json there (0600) while it exists.
set -euo pipefail
KEEP=
[[ ${1:-} == --keep ]] && KEEP=1
SV=${STRAYLIGHT_VOICE:-$HOME/Projects/straylight-voice}
W=$(cd "$(dirname "$0")/.." && pwd)/work/laptop-signin
export TMPDIR=$W/tmp
mkdir -p "$W/frames" "$W/state" "$TMPDIR"
UI=$W/ui.sock A=$W/aiand.sock
AIAND=$SV/aiand/target/release/straylight-aiand
"$SV/target/release/straylight-voice" --live "$W/frames" --socket "$UI" > "$W/ui.log" 2>&1 &
UIP=$!
sleep 2
"$AIAND" --state-dir "$W/state" --socket "$A" --ui-socket "$UI" > "$W/aiand.log" 2>&1 &
AP=$!
trap 'kill $AP $UIP 2>/dev/null || true' EXIT
sleep 4
"$AIAND" --socket "$A" status
echo "== sign in: approve on your phone (Ctrl-C cancels)"
"$AIAND" --socket "$A" sign-in
"$AIAND" --socket "$A" status
"$AIAND" --socket "$A" models | head -5
echo "== two questions through the listener's responder (one conversation)"
"$SV/listen/target/release/straylight-listen" --aiand-socket "$A" \
    --ask "What's a good name for a cat?" --ask "明日は何曜日？" 2>&1 | tee "$W/ask.log"
if [[ -z $KEEP ]]; then
    echo "== sign out (revokes the key)"
    "$AIAND" --socket "$A" sign-out
fi
grep -v -E 'live:' "$W/aiand.log" | tail -20
echo "frames: $W/frames"
