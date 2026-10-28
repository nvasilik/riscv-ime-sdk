#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Openchip and Software Technologies, S.L.
# SPDX-License-Identifier: Apache-2.0
#
# check-lock.sh — components.yaml, sdk.lock.yaml and build/*/pins.hcl agree.
#
# `make lock` writes the lock from the manifest and renders the pins from
# the lock. This script fails when any of the three was edited without
# running it. Run in CI on every PR, and by `make check`.
#
#   check-lock.sh            the three files agree
#   check-lock.sh --release  and every component is pinned by a tag or a
#                            commit, not a branch. Run in CI on a release tag.

set -uo pipefail

MANIFEST="${MANIFEST:-components.yaml}"
LOCK="${LOCK:-sdk.lock.yaml}"

case "${1:-}" in
    "")        release=false ;;
    --release) release=true ;;
    *)         echo "usage: $0 [--release]" >&2; exit 2 ;;
esac

command -v yq >/dev/null || { echo "check-lock: yq required" >&2; exit 1; }

fail=0
bad() {
    if [[ -n "${GITHUB_ACTIONS:-}" ]]; then
        printf '::error::%s\n' "$*"
    else
        printf 'FAIL: %s\n' "$*"
    fi
    fail=1
}

# same <what> <manifest value> <lock value>
same() {
    [[ "$2" == "$3" ]] || bad "$1: manifest '$2' != lock '$3' — run 'make lock'"
}

echo "==> manifest and lock agree"
version=$(yq -r '.sdk_version' "$MANIFEST")
same sdk_version "$version" "$(yq -r '.sdk_version' "$LOCK")"
# A release is tagged openchip-v<sdk_version>, and the sdk workflow accepts
# only openchip-vYYYY.MM.DD.
[[ "$version" =~ ^[0-9]{4}\.[0-9]{2}\.[0-9]{2}$ ]] \
    || bad "sdk_version '$version' is not YYYY.MM.DD"
for c in $(yq -r '.components | keys | .[]' "$MANIFEST"); do
    same "$c ref"  "$(yq -r ".components.\"$c\".ref"  "$MANIFEST")" \
                   "$(yq -r ".components.\"$c\".resolved_from" "$LOCK")"
    same "$c repo" "$(yq -r ".components.\"$c\".repo" "$MANIFEST")" \
                   "$(yq -r ".components.\"$c\".repo" "$LOCK")"
    kind=$(yq -r ".components.\"$c\".resolved_kind" "$LOCK")
    case "$kind" in
        branch|tag) ;;
        commit)
            same "$c commit" "$(yq -r ".components.\"$c\".ref" "$MANIFEST")" \
                             "$(yq -r ".components.\"$c\".commit" "$LOCK")" ;;
        *)  bad "$c: resolved_kind '$kind' is not branch, tag or commit — run 'make lock'" ;;
    esac
    # A release must be rebuildable from components.yaml alone. A branch has
    # moved on by then.
    if [[ "$release" == true && "$kind" == branch ]]; then
        bad "$c: a release must pin a tag or a commit, not the branch '$(yq -r ".components.\"$c\".ref" "$MANIFEST")'"
    fi
done
same base_image "$(yq -r '.base_image' "$MANIFEST")" \
                "$(yq -r '.base_image.resolved_from' "$LOCK")"
base=$(yq -r '.base_image' "$MANIFEST")
if [[ "$base" == *@* ]]; then
    pinned=$(yq -r '.base_image.pinned' "$LOCK")
    same "base_image digest" "${base#*@}" "${pinned#*@}"
elif [[ "$release" == true ]]; then
    bad "base_image: a release must pin a digest, not the tag '$base'"
fi

# The component image tags are git tree hashes of build/<stage>, so the pins
# must be in those directories. Render them from the lock and compare with
# the files on disk, then put the files back.
echo "==> build/*/pins.hcl match the lock"
saved=$(mktemp -d)
trap 'rm -rf "$saved"' EXIT
for f in build/*/pins.hcl; do
    mkdir -p "$saved/$(dirname "$f")"
    cp "$f" "$saved/$f"
done
./scripts/make-lock.sh --render 2>/dev/null
for f in build/*/pins.hcl; do
    if ! diff -u "$saved/$f" "$f"; then
        bad "$f differs from $LOCK — run 'make pins'"
    fi
    cp "$saved/$f" "$f"
done

[[ "$fail" == 0 ]] && echo "  clean"
exit "$fail"
