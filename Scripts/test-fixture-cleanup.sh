#!/bin/sh
# Compare fixture directories before and after a test run. SwiftPM's own
# temporary files are excluded; preexisting fixtures are left alone.
# Usage: Scripts/test-fixture-cleanup.sh swift test ...
set -eu

test_tmp=${TMPDIR:-/tmp}
snapshot_dir=$(mktemp -d "$test_tmp/GitKitFixtureCheck.XXXXXX")
trap 'rm -rf "$snapshot_dir"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

snapshot() {
    # Legacy prefixes also make this check catch the original regression.
    find "$test_tmp" -mindepth 1 -maxdepth 1 -type d \( \
        -name 'GitKitTests-*' -o -name 'GitRemote*' -o -name 'Octopus*' -o \
        -name 'GitSSH*' -o -name 'SSHExec*' \) -print | LC_ALL=C sort
}

snapshot > "$snapshot_dir/before"
status=0
"$@" || status=$?
snapshot > "$snapshot_dir/after"

leftovers=$(LC_ALL=C comm -13 "$snapshot_dir/before" "$snapshot_dir/after")
if [ -n "$leftovers" ]; then
    printf 'Tests left temporary fixtures behind:\n%s\n' "$leftovers" >&2
    status=1
fi

exit "$status"
