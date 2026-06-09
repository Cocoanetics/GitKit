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

# Re-vendor libgit2's public headers into the CGitKit module. SwiftPM's C-module
# build only searches a target's publicHeadersPath (never cSettings header
# paths), so the headers the Swift importer needs must physically live there.
# The submodule stays pristine; these are byte copies of the pinned tag's
# include/ tree. The .c are still compiled from the submodule itself.
vendor="$root/Sources/CGitKit/include"
rm -rf "$vendor/git2" "$vendor/git2.h"
cp "$root/vendor/libgit2/include/git2.h" "$vendor/git2.h"
cp -R "$root/vendor/libgit2/include/git2" "$vendor/git2"

# Regenerate the curated umbrella's git2/sys/* include list (between the
# BEGIN/END sys markers) so a new libgit2 release adding a sys header is picked
# up. git2.h doesn't include these, but consumers use complete types from them.
python3 - "$vendor" <<'PY'
import sys, glob, os, re
vendor = sys.argv[1]
headers = sorted(os.path.basename(p) for p in glob.glob(os.path.join(vendor, "git2/sys/*.h")))
block = "\n".join('#include "git2/sys/%s"' % h for h in headers)
path = os.path.join(vendor, "gitkit_libgit2.h")
text = open(path).read()
text = re.sub(r"/\* BEGIN sys \*/.*?/\* END sys \*/",
              "/* BEGIN sys */\n%s\n/* END sys */" % block, text, flags=re.S)
open(path, "w").write(text)
print("Regenerated umbrella with %d git2/sys headers." % len(headers))
PY

echo "Submodule now at libgit2 $(git describe --tags); re-vendored $(find "$vendor/git2" -name '*.h' | wc -l | tr -d ' ')+1 public headers."
echo "Next: (cd $root && swift test) then commit + tag '${tag#v}'."
