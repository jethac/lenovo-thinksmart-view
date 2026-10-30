#!/usr/bin/env bash
# Fetch sherpa-onnx model tarballs from the k2-fsa release tags. Verified
# against the SHA-256 digest GitHub publishes for the asset where there is one;
# older assets have none, so their SHA-256 is recorded in UNVERIFIED.sha256.
#   fetch-sherpa-models.sh DIR TAG:ASSET...
set -euo pipefail
D=$1; shift; mkdir -p "$D"; cd "$D"
for ta in "$@"; do
    tag=${ta%%:*} a=${ta#*:}
    id=$(gh api "repos/k2-fsa/sherpa-onnx/releases/tags/$tag" --jq .id)
    dig=$(gh api "repos/k2-fsa/sherpa-onnx/releases/$id/assets?per_page=100" --paginate \
        --jq ".[] | select(.name==\"$a\") | (.digest // \"none\")")
    [[ -n $dig ]] || { echo "no asset $a in $tag" >&2; exit 1; }
    if [[ ! -f $a ]]; then
        curl -sSL --retry 3 -o "$a.partial" "https://github.com/k2-fsa/sherpa-onnx/releases/download/$tag/$a"
        mv "$a.partial" "$a"
    fi
    if [[ $dig == sha256:* ]]; then
        echo "${dig#sha256:}  $a" | sha256sum -c
    else
        echo "WARNING: $a has no published digest"; sha256sum "$a" | tee -a UNVERIFIED.sha256
    fi
    tar xjf "$a"
done
