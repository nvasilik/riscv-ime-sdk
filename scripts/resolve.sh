# SPDX-FileCopyrightText: 2026 Openchip and Software Technologies, S.L.
# SPDX-License-Identifier: Apache-2.0
#
# resolve.sh — resolve component refs and the base image. Sourced by
# make-lock.sh, which writes what they resolve to into the lock, and by
# check-refs.sh, which checks that they still resolve to the lock.
#
# Refs are resolved with `git ls-remote`, so no clone is needed. The
# component repos are public, so git needs no credentials. The base image
# digest is read from the Docker Hub registry API with curl.

# Component ref -> "<kind> <commit>", kind being branch, tag or commit.
#
#   refs/heads/<name>   the branch <name>
#   refs/tags/<name>    the tag <name>, peeled to its commit
#   <40 hex digits>     that commit
#   <name>              the branch or the tag <name>; fails if both exist,
#                       so that a branch cannot shadow a release tag
resolve_ref() {
    local repo="$1" ref="$2" out branch tag peeled kind
    if [[ "$ref" =~ ^[0-9a-f]{40}$ ]]; then
        echo "commit ${ref}"
        return
    fi
    case "$ref" in
        refs/heads/*|refs/tags/*) ;;
        refs/*) echo "FATAL: ${ref}: only refs/heads/ and refs/tags/ can be pinned" >&2; return 1 ;;
    esac
    local name="${ref#refs/heads/}"
    name="${name#refs/tags/}"
    out=$(git ls-remote "$repo" "refs/heads/${name}" "refs/tags/${name}" "refs/tags/${name}^{}") \
        || { echo "FATAL: cannot list refs of ${repo}" >&2; return 1; }
    # ls-remote matches patterns against the tail of a ref name. Keep exact
    # matches only.
    branch=$(awk -v r="refs/heads/${name}"    '$2 == r {print $1}' <<< "$out")
    tag=$(awk    -v r="refs/tags/${name}"     '$2 == r {print $1}' <<< "$out")
    peeled=$(awk -v r="refs/tags/${name}^{}"  '$2 == r {print $1}' <<< "$out")
    tag="${peeled:-$tag}"
    case "$ref" in
        refs/heads/*) kind=branch ;;
        refs/tags/*)  kind=tag ;;
        *)
            if [[ -n "$branch" && -n "$tag" ]]; then
                echo "FATAL: ${ref} is both a branch and a tag in ${repo};" \
                     "write refs/heads/${name} or refs/tags/${name}" >&2
                return 1
            fi
            if [[ -n "$branch" ]]; then kind=branch; else kind=tag; fi
            ;;
    esac
    if [[ "$kind" == branch && -n "$branch" ]]; then
        echo "branch ${branch}"
    elif [[ "$kind" == tag && -n "$tag" ]]; then
        echo "tag ${tag}"
    else
        echo "FATAL: cannot resolve ${ref} in ${repo}" >&2
        return 1
    fi
}

# Docker Hub image reference -> "docker.io/<repo>:<tag>@sha256:...".
#
#   name:tag            the digest the tag points at now, which is that of
#                       the multi-platform index, as `docker pull` uses it
#   name:tag@sha256:... that digest, after checking that the registry has it;
#                       the tag is kept for readers only
resolve_image() {
    local ref="$1" name tag digest want="" repo token got
    if [[ "$ref" == *@* ]]; then
        want="${ref#*@}"
        ref="${ref%%@*}"
        [[ "$want" =~ ^sha256:[0-9a-f]{64}$ ]] \
            || { echo "FATAL: ${want}: not a sha256 digest" >&2; return 1; }
    fi
    name="${ref%%:*}"
    tag="${ref#*:}"
    [[ "$tag" != "$ref" ]] || { echo "FATAL: ${ref}: no tag" >&2; return 1; }
    [[ "$name" == */* ]] && repo="$name" || repo="library/${name}"
    token=$(curl -fsSL "https://auth.docker.io/token?service=registry.docker.io&scope=repository:${repo}:pull" \
            | yq -p json -r '.token') || return 1
    got=$(curl -fsSI \
              -H "Authorization: Bearer ${token}" \
              -H 'Accept: application/vnd.oci.image.index.v1+json' \
              -H 'Accept: application/vnd.docker.distribution.manifest.list.v2+json' \
              -H 'Accept: application/vnd.oci.image.manifest.v1+json' \
              -H 'Accept: application/vnd.docker.distribution.manifest.v2+json' \
              "https://registry-1.docker.io/v2/${repo}/manifests/${want:-$tag}" \
          | tr -d '\r' | awk -F': ' 'tolower($1) == "docker-content-digest" {print $2}')
    digest="${want:-$got}"
    if [[ ! "$got" =~ ^sha256:[0-9a-f]{64}$ || "$got" != "$digest" ]]; then
        echo "FATAL: cannot resolve ${ref}${want:+@$want} on Docker Hub" >&2
        return 1
    fi
    echo "docker.io/${repo}:${tag}@${digest}"
}
