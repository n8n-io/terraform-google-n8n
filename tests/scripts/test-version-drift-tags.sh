#!/usr/bin/env bash
# Offline, deterministic regression test for
# tests/scripts/lib/drift-tags.sh's latest_release_tag, the GHCR tag filter
# check-version-drift.sh's check_n8n_chart pipes live registry output
# through. No network, no credentials: every case feeds a fixed JSON string
# fixture to the function via stdin.
#
# Guards against a tag-parsing regression (picking a non-release tag, or
# sorting lexically instead of numerically) going unnoticed because the
# weekly/manual version-drift workflow that would otherwise catch it does
# not run on PRs (see .github/workflows/version-drift.yml).

set -uo pipefail

cd "$(dirname "$0")/../.."

# shellcheck source=lib/drift-tags.sh
source tests/scripts/lib/drift-tags.sh

FAILURES=0

fail() {
  echo "FAIL: $1" >&2
  FAILURES=$((FAILURES + 1))
}

pass() {
  echo "PASS: $1"
}

# assert_latest <case-name> <input-json> <expected-output-or-empty-for-failure>
assert_latest() {
  local name="$1" input="$2" expected="$3" actual rc
  actual="$(printf '%s' "$input" | latest_release_tag 2>/dev/null)"
  rc=$?
  if [ -n "$expected" ]; then
    if [ "$rc" -eq 0 ] && [ "$actual" = "$expected" ]; then
      pass "$name: latest_release_tag -> $actual"
    else
      fail "$name: expected '$expected', got rc=$rc output='$actual'"
    fi
  else
    if [ "$rc" -ne 0 ] && [ -z "$actual" ]; then
      pass "$name: latest_release_tag correctly failed with no output"
    else
      fail "$name: expected failure with no output, got rc=$rc output='$actual'"
    fi
  fi
}

# ── Case 1: real GHCR tag-list shape, mixing non-version tags ──────────────
# The exact shape https://ghcr.io/v2/n8n-io/n8n-helm-chart/n8n/tags/list
# returns: a 'name' field, release tags, 'artifacthub.io' metadata, a
# 'sha256-...' digest tag, and a prerelease tag.
REAL_SHAPE_FIXTURE='{"name":"n8n-io/n8n-helm-chart/n8n","tags":["1.0.0","1.1.0","1.2.0","1.3.0","1.4.0","1.5.0","1.6.0","1.7.0","1.8.0","1.9.0","1.10.0","1.11.0","1.12.0","1.13.0","1.14.0","artifacthub.io","1.15.0","sha256-768f9142e4f718894eb0c9fb8996a265d9f3c723309f25f0d99985fce5f2f3a8","1.11.0-preview.workerpools.1"]}'
assert_latest "real GHCR shape picks the highest release, ignoring non-version tags" \
  "$REAL_SHAPE_FIXTURE" "1.15.0"

# ── Case 2: numeric, not lexical, ordering ─────────────────────────────────
# Lexical string sort would put "1.9.0" after "1.10.0" (since '9' > '1'
# character-wise), making 1.9.0 look "latest". key() must sort on the
# integer tuple, not the raw string.
assert_latest "numeric ordering: 1.10.0 beats 1.9.0 despite lexical order" \
  '{"tags":["1.9.0","1.10.0"]}' "1.10.0"

# ── Case 3: prerelease-only tag list -> failure ─────────────────────────────
# No plain X.Y.Z tag exists; must fail with no output rather than pick the
# prerelease or raise an uncaught exception.
assert_latest "prerelease-only list fails cleanly" \
  '{"tags":["1.11.0-preview.workerpools.1","artifacthub.io"]}' ""

# ── Case 4: invalid JSON -> failure ────────────────────────────────────────
assert_latest "invalid JSON fails cleanly" \
  'not json at all' ""

# ── Case 5: missing "tags" key -> failure ──────────────────────────────────
assert_latest "JSON with no tags key fails cleanly" \
  '{"name":"n8n-io/n8n-helm-chart/n8n"}' ""

# ── Self-check: prove the harness can actually fail ─────────────────────────
# Runs one assertion with a deliberately wrong expected value in a subshell
# (so its FAILURES increment does not pollute the real run) and confirms
# assert_latest reports it as a failure, not a false pass. Follows the same
# pattern as tests/scripts/check-n8n-chart.sh's self-check.
SELFTEST_OUTPUT="$(
  FAILURES=0
  fail() { echo "FAIL: $1"; FAILURES=$((FAILURES + 1)); }
  pass() { echo "PASS: $1"; }
  assert_latest() {
    local name="$1" input="$2" expected="$3" actual rc
    actual="$(printf '%s' "$input" | latest_release_tag 2>/dev/null)"
    rc=$?
    if [ -n "$expected" ]; then
      if [ "$rc" -eq 0 ] && [ "$actual" = "$expected" ]; then
        pass "$name: latest_release_tag -> $actual"
      else
        fail "$name: expected '$expected', got rc=$rc output='$actual'"
      fi
    else
      if [ "$rc" -ne 0 ] && [ -z "$actual" ]; then
        pass "$name: latest_release_tag correctly failed with no output"
      else
        fail "$name: expected failure with no output, got rc=$rc output='$actual'"
      fi
    fi
  }
  assert_latest "self-check: intentionally wrong expected value" '{"tags":["1.15.0"]}' "9.9.9"
  echo "FAILURES=$FAILURES"
)"

if echo "$SELFTEST_OUTPUT" | grep -q "^FAILURES=1$"; then
  pass "self-check: an intentionally wrong expected value is correctly caught"
else
  fail "self-check: an intentionally wrong expected value was NOT caught; the assertion helper cannot be trusted. Output: ${SELFTEST_OUTPUT}"
fi

# ── Regression proof: the OLD inline filter would have failed case 1 ───────
# tests/scripts/check-version-drift.sh used to filter with
# `numbered = [t for t in tags if '-' not in t]` inline in the curl pipeline
# before this change moved the logic into latest_release_tag. That old
# filter keeps 'artifacthub.io' (no '-') and 'sha256-...' (has a '-', so it
# IS excluded by luck) but still lets 'artifacthub.io' through, then
# key() raises ValueError on it when split on '.' and int()-converted,
# turning the whole lookup into a silent "lookup failed" instead of
# resolving 1.15.0. This proves the new regression test actually has teeth
# against that old logic, not just against a hypothetical.
OLD_FILTER_WORKDIR="$(mktemp -d)"
trap 'rm -rf "$OLD_FILTER_WORKDIR"' EXIT
cat >"$OLD_FILTER_WORKDIR/old-latest-release-tag.sh" <<'EOF'
#!/usr/bin/env bash
latest_release_tag() {
  python3 -c "
import json, sys
try:
    tags = json.load(sys.stdin)['tags']
except (json.JSONDecodeError, KeyError, TypeError):
    sys.exit(1)
numbered = [t for t in tags if '-' not in t]
if not numbered:
    sys.exit(1)
def key(v):
    return tuple(int(x) for x in v.split('.'))
print(sorted(numbered, key=key)[-1])
"
}
EOF
# shellcheck source=/dev/null
source "$OLD_FILTER_WORKDIR/old-latest-release-tag.sh"
OLD_FILTER_OUTPUT="$(printf '%s' "$REAL_SHAPE_FIXTURE" | latest_release_tag 2>/dev/null)"
OLD_FILTER_RC=$?
if [ "$OLD_FILTER_RC" -ne 0 ] && [ -z "$OLD_FILTER_OUTPUT" ]; then
  pass "regression proof: the old '-' not in t filter fails on the real GHCR fixture (rc=$OLD_FILTER_RC), confirming this test would have caught the regression"
else
  fail "regression proof: the old filter unexpectedly succeeded with output='$OLD_FILTER_OUTPUT'; this test would NOT have caught the regression"
fi
# Restore the real latest_release_tag for anything running after this point.
# shellcheck source=lib/drift-tags.sh
source tests/scripts/lib/drift-tags.sh

echo ""
if [ "$FAILURES" -gt 0 ]; then
  echo "test-version-drift-tags.sh: ${FAILURES} check(s) failed" >&2
  exit 1
fi

echo "test-version-drift-tags.sh: all checks passed"
