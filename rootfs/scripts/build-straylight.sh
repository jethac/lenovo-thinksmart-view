#!/usr/bin/env bash
# Build the Straylight voice assistant for the image and stage it as a root
# tree: straylight-voice at the commit pinned in straylight/pins.sh, built with
# that repository's own scripts (Slint fork, sysroot, fonts, transcribe.cpp,
# cargo), plus the listener's models. Every staged file is then checked against
# straylight/SHA256SUMS, so the image gets exactly the pinned build.
#
#   build-straylight.sh DL STAGE          DL: cache (rootfs/downloads/straylight)
#   build-straylight.sh --repin DL STAGE  build, then print the sums instead of checking
#
# DL keeps the source clones, the Python venv, the sysroots, the cargo and cmake
# build trees and the model products between runs, so a rebuild is incremental.
# STAGE is recreated: usr/local/bin, usr/local/share/straylight-listen,
# etc/systemd/system, etc/*.conf, the udev, polkit, D-Bus and sysusers files.
#
# Optional: SEED_STRAYLIGHT, SEED_VIEW_HAL, SEED_TRANSCRIBE name existing local
# clones to clone from instead of GitHub (objects only; the pinned commits are
# still checked out and verified). The Slint fork is a git dependency of
# straylight-voice, at the revision its Cargo.lock records: cargo fetches it
# over ssh into CARGO_HOME.
set -euo pipefail
REPIN=
[[ ${1:-} == --repin ]] && { REPIN=1; shift; }
DL=$(realpath -m "$1") STAGE=$(realpath -m "$2")
HERE=$(cd "$(dirname "$0")" && pwd)
TOP=$(cd "$HERE/.." && pwd)                     # rootfs/
PROJ=$(cd "$TOP/.." && pwd)                     # lenovo-8/
# shellcheck source=straylight/pins.sh
source "$HERE/straylight/pins.sh"
SUMS=$HERE/straylight/SHA256SUMS
INPUTS=$HERE/straylight/inputs.sha256
EXTRA=$HERE/straylight/extra-files.tsv
SRC=$DL/src
SV=$SRC/straylight-voice
mkdir -p "$DL" "$SRC" "$DL/models"
log() { echo "build-straylight: $*"; }

for t in git cargo rustup clang ld.lld llvm-ar cmake ninja bsdtar python3 curl patch; do
    command -v $t >/dev/null || { echo "build-straylight: missing tool: $t" >&2; exit 1; }
done
rustup target list --installed | grep -qx aarch64-unknown-linux-gnu ||
    { echo "build-straylight: rustup target add aarch64-unknown-linux-gnu" >&2; exit 1; }

# ---------------------------------------------------------------- sources
# checkout DIR URL SEED COMMIT: clone (from SEED if given), check out COMMIT
# detached, and make sure no tracked file differs from it.
checkout() {
    local dir=$1 url=$2 seed=$3 commit=$4
    if [[ ! -d $dir/.git ]]; then
        git clone -q --no-checkout "${seed:-$url}" "$dir"
        git -C "$dir" remote set-url origin "$url"
    fi
    git -C "$dir" cat-file -e "$commit^{commit}" 2>/dev/null || git -C "$dir" fetch -q origin
    git -C "$dir" checkout -q --detach "$commit"
    git -C "$dir" reset -q --hard "$commit"
    [[ $(git -C "$dir" rev-parse HEAD) == "$commit" ]] || { echo "build-straylight: $dir not at $commit" >&2; exit 1; }
    [[ -z $(git -C "$dir" status --porcelain --untracked-files=no) ]] ||
        { echo "build-straylight: tracked files differ in $dir" >&2; exit 1; }
}
log "straylight-voice $STRAYLIGHT_COMMIT, view-hal $VIEW_HAL_COMMIT"
checkout "$SV" "$STRAYLIGHT_REPO" "${SEED_STRAYLIGHT:-}" "$STRAYLIGHT_COMMIT"
checkout "$SRC/thinksmart-view-hal" "$VIEW_HAL_REPO" "${SEED_VIEW_HAL:-}" "$VIEW_HAL_COMMIT"
if [[ ! -d $SRC/transcribe.cpp/.git ]]; then
    git clone -q --no-checkout "${SEED_TRANSCRIBE:-$TRANSCRIBE_REPO}" "$SRC/transcribe.cpp"
    git -C "$SRC/transcribe.cpp" remote set-url origin "$TRANSCRIBE_REPO"
fi

# ---------------------------------------------------------------- tools
VENV=$DL/venv
if ! "$VENV/bin/python" -c "import fontTools, onnx, gguf, numpy" 2>/dev/null; then
    log "Python venv ${PY_PKGS[*]}"
    rm -rf "$VENV"
    python3 -m venv "$VENV"
    "$VENV/bin/pip" install -q --disable-pip-version-check "${PY_PKGS[@]}"
fi
# The ASR stream's glibc/libstdc++ sysroot (from the Debian .debs fetch-adbd.sh
# verified), the base straylight-voice's make-sysroot.sh extends.
ASR_SYSROOT=$DL/asr-sysroot
[[ -f $ASR_SYSROOT/usr/lib/aarch64-linux-gnu/libc.so.6 ]] ||
    "$PROJ/streams/asr/scripts/make-sysroot.sh" "$ASR_SYSROOT"

# ---------------------------------------------------------------- build
export LENOVO8=$PROJ                                    # the ALARM key for fetch-packages.sh
export STRAYLIGHT_WORDMARK=$TOP/assets/aiand-wordmark-white.svg
export TRANSCRIBE_GIT=$SRC/transcribe.cpp
(
    cd "$SV"
    scripts/fetch-packages.sh libinput systemd-libs libxkbcommon alsa-lib noto-fonts noto-fonts-cjk >/dev/null
    BASE=$ASR_SYSROOT scripts/make-sysroot.sh >/dev/null
    FONTTOOLS_PY=$VENV/bin/python scripts/make-fonts.sh >/dev/null
    listen/asr/build.sh aarch64 >/dev/null
    log "cargo: straylight-voice, -voicectl"
    scripts/build-aarch64.sh --release --locked
    log "cargo: straylight-listen (asr)"
    scripts/build-aarch64.sh --release --locked --manifest-path listen/Cargo.toml --features asr
    log "cargo: straylight-aiand"
    scripts/build-aarch64.sh --release --locked --manifest-path aiand/Cargo.toml
    log "cargo: straylight-wifi"
    scripts/build-aarch64.sh --release --locked --manifest-path wifi/Cargo.toml
)
# The build must not have touched a tracked file.
[[ -z $(git -C "$SV" status --porcelain --untracked-files=no) ]] ||
    { echo "build-straylight: the build changed tracked files in $SV" >&2; exit 1; }

# ---------------------------------------------------------------- models
# input NAME SRC URL: the stream's copy (fetched into the stream's downloads/
# when absent and a URL is known), checked against inputs.sha256.
input() {
    local name=$1 src=$PROJ/$2 url=${3:-} want
    want=$(awk -v n="$name" '$2 == n {print $1}' "$INPUTS")
    [[ -n $want ]] || { echo "build-straylight: $name not in $INPUTS" >&2; exit 1; }
    if [[ ! -f $src && -n $url ]]; then
        log "fetching $name" >&2
        mkdir -p "$(dirname "$src")"
        curl -fL --retry 3 -o "$src.partial" "$url" && mv "$src.partial" "$src"
    fi
    [[ -f $src ]] || { echo "build-straylight: missing $src" >&2; exit 1; }
    [[ $(sha256sum "$src" | cut -d' ' -f1) == "$want" ]] ||
        { echo "build-straylight: SHA-256 mismatch for $src" >&2; exit 1; }
    printf '%s\n' "$src"
}
QWEN=$(input Qwen3-ASR-0.6B-Q4_K_M.gguf "$QWEN_SRC" "$QWEN_URL")
SILERO=$(input silero-vad-v6.2-F32.gguf "$SILERO_SRC" "$SILERO_URL")
MEL=$(input melspectrogram.onnx "$MEL_SRC" "$MEL_URL")
EMB=$(input embedding_model.onnx "$EMB_SRC" "$EMB_URL")
WAKE=$(input hey-straylight.slt "$WAKE_SRC")
# Derived models, made with straylight-voice's scripts at the pinned commit;
# their sums are in SHA256SUMS (checked on the stage below).
M=$DL/models
want_of() { awk -v p="$1" '$2 == p {print $1}' "$SUMS" 2>/dev/null; }
CONVQ8=Qwen3-ASR-0.6B-Q4_K_M-convq8.gguf
if [[ ! -f $M/$CONVQ8 || $(sha256sum "$M/$CONVQ8" | cut -d' ' -f1) != "$(want_of "usr/local/share/straylight-listen/$CONVQ8")" ]]; then
    log "requant-conv.py: the conv stem as Q8_0"
    "$VENV/bin/python" -I "$SV/listen/scripts/requant-conv.py" "$QWEN" "$M/$CONVQ8.tmp" >/dev/null
    mv "$M/$CONVQ8.tmp" "$M/$CONVQ8"
fi
"$VENV/bin/python" -I "$SV/listen/scripts/export-frontend.py" "$MEL" "$EMB" "$M/frontend.slt" >/dev/null

# ---------------------------------------------------------------- stage
rm -rf "$STAGE"
inst() { install -D -m "$1" "$2" "$STAGE/$3"; }
R=target/aarch64-unknown-linux-gnu/release
P=$SV/packaging LP=$SV/listen/packaging AP=$SV/aiand/packaging WP=$SV/wifi/packaging
inst 0755 "$SV/$R/straylight-voice"            usr/local/bin/straylight-voice
inst 0755 "$SV/$R/straylight-voicectl"         usr/local/bin/straylight-voicectl
inst 0755 "$SV/listen/$R/straylight-listen"    usr/local/bin/straylight-listen
inst 0755 "$SV/aiand/$R/straylight-aiand"      usr/local/bin/straylight-aiand
inst 0755 "$SV/wifi/$R/straylight-wifi"        usr/local/bin/straylight-wifi
S=usr/local/share/straylight-listen
inst 0644 "$M/frontend.slt"                    $S/frontend.slt
inst 0644 "$WAKE"                              $S/hey-straylight.slt
inst 0644 "$M/$CONVQ8"                         $S/$CONVQ8
inst 0644 "$SILERO"                            $S/silero-vad-v6.2-F32.gguf
inst 0644 "$P/straylight-voice.service"        etc/systemd/system/straylight-voice.service
inst 0644 "$P/straylight-voice.conf"           etc/straylight-voice.conf
inst 0644 "$P/91-straylight-voice.rules"       etc/udev/rules.d/91-straylight-voice.rules
inst 0644 "$LP/straylight-listen.service"      etc/systemd/system/straylight-listen.service
inst 0644 "$LP/straylight-listen.conf"         etc/straylight-listen.conf
inst 0644 "$AP/straylight-aiand.service"       etc/systemd/system/straylight-aiand.service
inst 0644 "$AP/straylight-aiand.conf"          etc/straylight-aiand.conf
inst 0644 "$WP/straylight-wifi.service"        etc/systemd/system/straylight-wifi.service
inst 0644 "$WP/straylight-wifi.sysusers"       usr/lib/sysusers.d/straylight-wifi.conf
inst 0644 "$WP/50-straylight-wifi.rules"       etc/polkit-1/rules.d/50-straylight-wifi.rules
inst 0644 "$WP/straylight-wifi-wpas.conf"      etc/dbus-1/system.d/straylight-wifi-wpas.conf
# The hook for files not built here (speech output's model and voices).
n_extra=0
while IFS=$'\t' read -r sha src dst mode; do
    [[ -z $sha || $sha == \#* ]] && continue
    [[ $src == /* ]] || src=$PROJ/$src
    [[ -f $src && $(sha256sum "$src" | cut -d' ' -f1) == "$sha" ]] ||
        { echo "build-straylight: missing or wrong $src (extra-files.tsv)" >&2; exit 1; }
    inst "$mode" "$src" "$dst"
    n_extra=$((n_extra + 1))
done < "$EXTRA"

# Check (or, with --repin, print) the sums of everything staged except BUILDINFO.
LIST=$(cd "$STAGE" && find . -type f -printf '%P\n' | LC_ALL=C sort)
if [[ -n $REPIN ]]; then
    (cd "$STAGE" && sha256sum $LIST) > "$DL/SHA256SUMS.new"
    log "new sums in $DL/SHA256SUMS.new (copy to $SUMS after checking them)"
else
    [[ -f $SUMS ]] || { echo "build-straylight: no $SUMS (run with --repin)" >&2; exit 1; }
    pinned=$(grep -v '^#' "$SUMS" | awk 'NF {print $2}' | LC_ALL=C sort)
    [[ $pinned == "$LIST" ]] ||
        { echo "build-straylight: staged files differ from $SUMS:" >&2; diff <(echo "$pinned") <(echo "$LIST") >&2; exit 1; }
    (cd "$STAGE" && grep -v '^#' "$SUMS" | sha256sum -c --quiet --strict) ||
        { echo "build-straylight: staged files do not match $SUMS" >&2; exit 1; }
fi

# Build record, like /opt/adbd/BUILDINFO.
{
    echo "straylight-voice $STRAYLIGHT_COMMIT ($STRAYLIGHT_REPO)"
    echo "thinksmart-view-hal $VIEW_HAL_COMMIT ($VIEW_HAL_REPO)"
    echo "slint $(sed -n 's|^source = "git+ssh://git@github.com/jethac/slint.git?rev=\([0-9a-f]*\)#.*|\1|p' "$SV/Cargo.lock" | sort -u) ($SLINT_REPO, straylight-voice's Cargo.lock)"
    echo "transcribe.cpp $(cut -d' ' -f1 "$SV/out/listen/asr-aarch64/STAMP") + listen/asr/patches/"
    echo "rustc $(rustc --version | cut -d' ' -f2), clang $(clang --version | sed -n 's/.*version \([0-9.]*\).*/\1/p;q')"
    echo "extra files: $n_extra"
    echo
    (cd "$STAGE" && sha256sum $LIST)
} > "$DL/BUILDINFO"
install -D -m 0644 "$DL/BUILDINFO" "$STAGE/usr/local/share/straylight/BUILDINFO"
log "staged $(echo "$LIST" | wc -l) files, $(du -sh "$STAGE" | cut -f1), in $STAGE"
