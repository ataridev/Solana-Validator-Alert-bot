#!/bin/bash
# ============================================================================
#  Run the whole test suite. Exits non-zero if anything failed.
#  Needs: bash 4+, jq, bc, python3. No network, no Telegram token.
# ============================================================================
set -uo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
rc=0

for suite in unit integration; do
    echo "=============================================="
    echo "  $suite"
    echo "=============================================="
    if bash "$TESTS_DIR/$suite.sh"; then
        echo ""
    else
        rc=1
        echo "  -> $suite FAILED"
        echo ""
    fi
done

if (( rc == 0 )); then
    echo "all suites passed"
else
    echo "some suites failed"
fi
exit "$rc"
