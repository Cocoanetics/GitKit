#!/bin/bash
# Builds the external clients in compat/clients against GitKit revisions, each
# in the Swift 5 and Swift 6 language modes, as an ordinary SwiftPM dependency
# (no library evolution), and checks every outcome against
# compat/expectations.txt. A revision other than HEAD is the working tree with
# Package.swift, Sources and Tests taken from that tag or commit (the vendored
# libgit2 is reused); HEAD is the working tree itself.
#
#   Scripts/check-source-compat.sh [revision ...]    # default: every revision in the file
#
# COMPAT_SCRATCH sets the build directory (default: $TMPDIR/GitKit-compat).
# Exits 0 when every outcome matches, 1 when one does not, 2 on a setup error.
set -uo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
compat="$root/compat"
scratch="${COMPAT_SCRATCH:-${TMPDIR:-/tmp}/GitKit-compat}"
expectations="$compat/expectations.txt"

revisions=("$@")
if [ ${#revisions[@]} -eq 0 ]; then
    while read -r rev; do revisions+=("$rev"); done < <(grep -v '^#' "$expectations" | awk 'NF { print $2 }' | awk '!seen[$0]++')
fi

clients=()
for dir in "$compat"/clients/*/; do clients+=("$(basename "$dir")"); done

# The GitKit checkout a revision is built from.
prepare_gitkit() {
    local rev="$1" dest="$2"
    rm -rf "$dest" && mkdir -p "$dest"
    rsync -a --exclude .git --exclude .build --exclude .swiftpm --exclude compat "$root/" "$dest/" || return 1
    if [ "$rev" != HEAD ]; then
        rm -rf "$dest/Package.swift" "$dest/Sources" "$dest/Tests"
        git -C "$root" archive "$rev" -- Package.swift Sources Tests | tar -x -C "$dest" || return 1
    fi
}

# A client package with one target per client and language mode.
prepare_client() {
    local gitkit="$1" dest="$2"
    rm -rf "$dest" && mkdir -p "$dest/Sources"
    {
        echo '// swift-tools-version: 6.0'
        echo 'import PackageDescription'
        echo 'let gitKit: Target.Dependency = .product(name: "GitKit", package: "GitKit")'
        echo 'let package = Package('
        echo '    name: "GitKitCompatClients",'
        echo '    platforms: [.macOS(.v13), .iOS(.v16)],'
        echo "    dependencies: [.package(name: \"GitKit\", path: \"$gitkit\")],"
        echo '    targets: ['
        for client in "${clients[@]}"; do
            for mode in 5 6; do
                mkdir -p "$dest/Sources/${client}_swift$mode"
                cp "$compat/clients/$client/"*.swift "$dest/Sources/${client}_swift$mode/"
                echo "        .executableTarget(name: \"${client}_swift$mode\", dependencies: [gitKit],"
                echo "                          swiftSettings: [.swiftLanguageMode(.v$mode)]),"
            done
        done
        echo '    ]'
        echo ')'
    } > "$dest/Package.swift"
}

mismatches=0
summary=()
for rev in "${revisions[@]}"; do
    work="$scratch/$rev"
    prepare_gitkit "$rev" "$work/gitkit" || { echo "cannot prepare GitKit at $rev" >&2; exit 2; }
    prepare_client "$work/gitkit" "$work/client"
    for client in "${clients[@]}"; do
        line="$(grep -v '^#' "$expectations" | awk -v c="$client" -v r="$rev" '$1 == c && $2 == r')"
        if [ -z "$line" ]; then
            echo "no expectation for $client at $rev" >&2
            mismatches=$((mismatches + 1))
            continue
        fi
        expected="$(echo "$line" | awk '{ print $3 }')"
        diagnostic="$(echo "$line" | awk '{ $1 = $2 = $3 = ""; sub(/^ +/, ""); print }')"
        for mode in 5 6; do
            log="$work/${client}_swift$mode.log"
            swift build --package-path "$work/client" --scratch-path "$work/build" \
                --target "${client}_swift$mode" 2>&1 | sed $'s/\x1b\\[[0-9;]*m//g' > "$log"
            code=${PIPESTATUS[0]}
            actual=pass
            [ $code -ne 0 ] && actual=fail
            verdict=ok
            if [ "$actual" != "$expected" ]; then
                verdict=MISMATCH
            elif [ "$actual" = fail ] && [ -n "$diagnostic" ] && ! grep 'error:' "$log" | grep -qF "$diagnostic"; then
                verdict="MISMATCH (no error naming '$diagnostic')"
            fi
            [ "$verdict" != ok ] && mismatches=$((mismatches + 1))
            summary+=("$(printf '%-22s %-8s swift%s  exit %-3s expected %-4s %s' "$client" "$rev" "$mode" "$code" "$expected" "$verdict")")
            if [ "$verdict" != ok ] || [ "$actual" = fail ]; then
                grep -m 3 'error:' "$log" | sed 's/^/    /' | while read -r l; do summary+=("$l"); done
            fi
            echo "${summary[${#summary[@]}-1]}"
            if [ "$actual" = fail ]; then
                grep -m 1 -E '\.swift:[0-9]+:[0-9]+: error:' "$log" | sed "s|^$work/client/||; s/^/        /"
            fi
        done
    done
done

echo
if [ $mismatches -eq 0 ]; then
    echo "source compatibility: every outcome matches compat/expectations.txt"
    exit 0
fi
echo "source compatibility: $mismatches outcome(s) differ from compat/expectations.txt" >&2
exit 1
