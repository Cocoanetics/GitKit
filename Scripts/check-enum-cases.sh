#!/bin/bash
# Lists every case of GitKit's public enums from the module's symbol graph and
# compares the list with compat/public-enum-cases.txt. A client may switch
# exhaustively over any public enum, so adding a case breaks its source, as
# Level.layers did in 2.18.0: an added case is a major change, or is not made
# (put the new value in a property or a new type instead). A removed or renamed
# case breaks clients that name it. Either way the list differs and this exits 1;
# record the change with --update only together with that release
# classification. The compile probes in Scripts/check-source-compat.sh remain
# the evidence; this is the inventory that catches a case nobody probed.
#
#   Scripts/check-enum-cases.sh [--update]
#
# ENUM_CASES_SCRATCH sets the build directory (default: $TMPDIR/GitKit-enum-cases).
# Uses SwiftPM's native build system, whose dump-symbol-graph is the one that
# works for this package. Exits 0 when the cases match, 1 when they differ,
# 2 on a setup error. The Archive trait is enabled explicitly, so the
# trait-gated GitArchiveFormat, public API for its clients, is listed too.
set -uo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
inventory="$root/compat/public-enum-cases.txt"
scratch="${ENUM_CASES_SCRATCH:-${TMPDIR:-/tmp}/GitKit-enum-cases}"

# dump-symbol-graph covers every module and cannot load SwiftPM's synthesized
# GitKitPackageTests module; that one failure is expected, any other is not.
rm -rf "$scratch"/*/symbolgraph
swift package --package-path "$root" --scratch-path "$scratch" --build-system native \
    --traits Archive dump-symbol-graph --minimum-access-level public > "$scratch.log" 2>&1
if grep 'error:' "$scratch.log" | grep -qv "symbol graph for 'GitKitPackageTests'"; then
    grep 'error:' "$scratch.log" | head -20 >&2
    echo "symbol graph extraction failed (log: $scratch.log)" >&2
    exit 2
fi
graph="$(find "$scratch" -path '*symbolgraph/GitKit.symbols.json' | head -1)"
[ -n "$graph" ] || { echo "no GitKit.symbols.json under $scratch (log: $scratch.log)" >&2; exit 2; }

current="$(python3 -I - "$graph" <<'PY'
import json, sys
graph = json.load(open(sys.argv[1]))
cases = {".".join(s["pathComponents"]) for s in graph["symbols"]
         if s["kind"]["identifier"] == "swift.enum.case"}
print("\n".join(sorted(cases)))
PY
)" || exit 2

if [ "${1:-}" = --update ]; then
    printf '%s\n' "$current" > "$inventory"
    echo "wrote $(wc -l < "$inventory" | tr -d ' ') cases to compat/public-enum-cases.txt"
    exit 0
fi

if diff -u "$inventory" <(printf '%s\n' "$current"); then
    echo "public enum cases: unchanged ($(wc -l < "$inventory" | tr -d ' '))"
    exit 0
fi
echo "public enum cases differ from compat/public-enum-cases.txt: an added case breaks" >&2
echo "exhaustive switches (major), a removed one breaks clients naming it (major)." >&2
exit 1
