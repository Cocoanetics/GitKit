#!/usr/bin/env bash
# Repoint the pristine libgit2 submodule at an official release tag.
# GitKit's version always matches libgit2's, so after running this you'd
# typically: swift test && git commit -am "libgit2 X.Y.Z" && git tag X.Y.Z
#
# Usage: Scripts/update-libgit2.sh vX.Y.Z      (e.g. Scripts/update-libgit2.sh v1.9.4)
set -euo pipefail

tag="${1:-}"
if [[ -z "$tag" ]]; then
    echo "usage: $0 <libgit2-tag>   e.g. $0 v1.9.4" >&2
    exit 2
fi

root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root/vendor/libgit2"

git fetch --tags origin
if ! git rev-parse -q --verify "refs/tags/$tag" >/dev/null; then
    echo "error: libgit2 has no tag '$tag'" >&2
    exit 1
fi
git checkout -q "$tag"

echo "Submodule now at libgit2 $(git describe --tags)."
echo "Next: (cd $root && swift test) then commit + tag '${tag#v}'."
