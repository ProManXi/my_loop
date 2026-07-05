#!/usr/bin/env bash
#
# Ratcheting coverage gate. Compares measured line coverage against the
# committed floor in .github/coverage/thresholds.json and fails (exit 1) if the
# measurement is below the floor. The floor only ever moves up: when a PR adds
# tests that raise coverage, it bumps thresholds.json in the same PR.
#
# Usage:
#   scripts/coverage/check.sh backend <path-to-coverage.cobertura.xml>
#   scripts/coverage/check.sh mobile  <path-to-lcov.info>
#
set -euo pipefail

stack="${1:?usage: check.sh <backend|mobile> <report-path>}"
report="${2:?missing report path}"
thresholds="$(git rev-parse --show-toplevel)/.github/coverage/thresholds.json"

if [[ ! -f "$report" ]]; then
  echo "::error::coverage report not found: $report" >&2
  exit 1
fi

floor="$(python3 -c "import json; print(json.load(open('$thresholds'))['$stack'])")"

case "$stack" in
  backend)
    # Cobertura: the root <coverage line-rate="0.xx" ...> is the overall ratio.
    # Parse with python to avoid SIGPIPE from a grep|head pipeline under pipefail.
    pct="$(python3 - "$report" <<'PY'
import re, sys
text = open(sys.argv[1]).read()
m = re.search(r'line-rate="([0-9.]+)"', text)
print(f"{float(m.group(1)) * 100:.2f}" if m else "0")
PY
)"
    ;;
  mobile)
    # lcov: sum LF (found) and LH (hit) across all records.
    pct="$(awk -F: '/^LF:/{f+=$2} /^LH:/{h+=$2} END{if(f>0) printf "%.2f", h/f*100; else print "0"}' "$report")"
    ;;
  *)
    echo "::error::unknown stack '$stack' (expected backend|mobile)" >&2
    exit 1
    ;;
esac

echo "[$stack] line coverage: ${pct}%   floor: ${floor}%"

if awk "BEGIN{exit (${pct}+0 >= ${floor}+0) ? 0 : 1}"; then
  echo "[$stack] coverage gate passed"
else
  echo "::error::[$stack] coverage ${pct}% is below the floor ${floor}%. Add tests or, if this is intentional, lower the floor in .github/coverage/thresholds.json." >&2
  exit 1
fi
