#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Openchip and Software Technologies, S.L.
# SPDX-License-Identifier: Apache-2.0
#
# check-release.sh — every component of sdk.lock.yaml is pinned to a tag
# that points at its locked commit.
#
# A branch can be rebased or force-pushed. A tag keeps the commit of a release reachable, so that the
# release can be rebuilt from source.
# A commit SHA as ref is rejected: the release names a tag. So is a
# tag whose name is also a branch of the repo: `make lock` resolves the
# branch first, so the lock would not record the tag.
#
# Run in CI on every release tag, and by `make check-release`.

set -uo pipefail

LOCK="${LOCK:-sdk.lock.yaml}"

command -v yq >/dev/null || { echo "check-release: yq required" >&2; exit 1; }

export GIT_TERMINAL_PROMPT=0

fail=0
bad() {
    if [[ -n "${GITHUB_ACTIONS:-}" ]]; then
        printf '::error::%s\n' "$*"
    else
        printf 'FAIL: %s\n' "$*"
    fi
    fail=1
}

# A lock that cannot be read must not pass as "no components".
components=$(yq -e -r '.components | keys | .[]' "$LOCK") \
    || { echo "check-release: cannot read .components of $LOCK" >&2; exit 1; }

echo "==> every component is pinned to a tag at its locked commit"
for c in $components; do
    repo=$(yq -r ".components.\"$c\".repo"          "$LOCK")
    commit=$(yq -r ".components.\"$c\".commit"        "$LOCK")
    ref=$(yq -r ".components.\"$c\".resolved_from" "$LOCK")

    if [[ -z "$commit" || "$commit" == null || -z "$ref" || "$ref" == null ]]; then
        bad "$c: no commit or resolved_from in $LOCK — run 'make lock'"
        continue
    fi
    if [[ "$ref" =~ ^[0-9a-f]{40}$ ]]; then
        bad "$c: ref '$ref' is a commit SHA, not a tag"
        continue
    fi
    # --heads --tags keeps the query to those namespaces: the forks carry
    # thousands of pull request refs.
    if ! out=$(git ls-remote --heads --tags "$repo" \
                   "refs/heads/${ref}" "refs/tags/${ref}" "refs/tags/${ref}^{}"); then
        bad "$c: cannot list the refs of $repo"
        continue
    fi
    # ls-remote matches patterns by tail, so compare the full ref name.
    sha_of() { awk -v t="$1" '$2 == t {print $1; exit}' <<< "$out"; }
    # An annotated tag lists the tag object and, as <tag>^{}, its commit.
    # A lightweight tag lists only the commit.
    tagged=$(sha_of "refs/tags/${ref}^{}")
    [[ -n "$tagged" ]] || tagged=$(sha_of "refs/tags/${ref}")
    if [[ -z "$tagged" ]]; then
        bad "$c: ref '$ref' is not a tag of $repo"
    elif [[ -n "$(sha_of "refs/heads/${ref}")" ]]; then
        bad "$c: '$ref' is both a branch and a tag of $repo, and 'make lock' resolves the branch" \
            "— tag the release under another name"
    elif [[ "$tagged" != "$commit" ]]; then
        bad "$c: tag '$ref' points at $tagged, not at the locked commit $commit — run 'make lock'"
    else
        echo "  $c: $ref = $commit"
    fi
done

[[ "$fail" == 0 ]] && echo "  clean"
exit "$fail"
