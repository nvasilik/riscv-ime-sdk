#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Openchip and Software Technologies, S.L.
# SPDX-License-Identifier: Apache-2.0
#
# check-refs.sh — the refs of components.yaml still resolve to sdk.lock.yaml.
#
# check-lock.sh compares files and needs no network. This script asks the
# component repos and Docker Hub. It fails when a tag no longer points at
# the commit in the lock, when a ref no longer resolves or now names both a
# branch and a tag, or when the lock records the wrong kind of ref. Either a
# tag was moved, deleted or shadowed in a component repo, or the lock was
# edited by hand. A branch that moved on is expected, and only reported.
# Run in CI on every PR, and by `make check-refs`.

set -uo pipefail

MANIFEST="${MANIFEST:-components.yaml}"
LOCK="${LOCK:-sdk.lock.yaml}"

command -v yq >/dev/null || { echo "check-refs: yq required" >&2; exit 1; }

# shellcheck source=scripts/resolve.sh
source "$(dirname "$0")/resolve.sh"

fail=0
note() { printf '  %s\n' "$*"; }
bad() {
    if [[ -n "${GITHUB_ACTIONS:-}" ]]; then
        printf '::error::%s\n' "$*"
    else
        printf 'FAIL: %s\n' "$*"
    fi
    fail=1
}

echo "==> component refs resolve to the lock"
for c in $(yq -r '.components | keys | .[]' "$MANIFEST"); do
    repo=$(yq -r ".components.\"$c\".repo" "$MANIFEST")
    ref=$(yq  -r ".components.\"$c\".ref"  "$MANIFEST")
    lock_kind=$(yq -r ".components.\"$c\".resolved_kind" "$LOCK")
    lock_sha=$(yq  -r ".components.\"$c\".commit"        "$LOCK")
    if ! resolved=$(resolve_ref "$repo" "$ref"); then
        bad "$c: $ref no longer resolves"
        continue
    fi
    read -r kind sha <<< "$resolved"
    if [[ "$kind" != "$lock_kind" ]]; then
        bad "$c: $ref is a $kind, the lock says $lock_kind — run 'make lock'"
    elif [[ "$sha" == "$lock_sha" ]]; then
        note "$c: $ref ($kind) at ${sha::12}"
    elif [[ "$kind" == branch ]]; then
        note "$c: $ref (branch) has moved on: lock ${lock_sha::12}, now ${sha::12}"
    else
        bad "$c: tag $ref was moved: lock ${lock_sha::12}, now ${sha::12}"
    fi
done

echo "==> base image resolves to the lock"
base=$(yq -r '.base_image' "$MANIFEST")
lock_pinned=$(yq -r '.base_image.pinned' "$LOCK")
if ! pinned=$(resolve_image "$base"); then
    bad "base_image: $base no longer resolves"
elif [[ "$pinned" == "$lock_pinned" ]]; then
    note "base_image: ${pinned##*/}"
    # Pinned by digest: report where the tag is now, for the next bump.
    if [[ "$base" == *@* ]] && now=$(resolve_image "${base%%@*}") \
       && [[ "$now" != "$pinned" ]]; then
        note "base_image: the tag ${base%%@*} has moved on to ${now#*@}"
    fi
elif [[ "$base" != *@* ]]; then
    note "base_image: the tag $base has moved on: lock ${lock_pinned#*@}, now ${pinned#*@}"
else
    bad "base_image: $base is pinned as $lock_pinned in the lock — run 'make lock'"
fi

exit "$fail"
