#!/usr/bin/env bash
# Shared tag-selection helper for tests/scripts/check-version-drift.sh's
# GHCR-backed chart checks, split out so tests/scripts/test-version-drift-tags.sh
# can exercise the exact filtering/ordering logic offline, with no network
# call and no inline python embedded in a curl pipeline.

# latest_release_tag
# Reads a GHCR tag-list response (the `{"name": ..., "tags": [...]}` JSON
# `GET /v2/<repo>/tags/list` returns) on stdin and prints the highest plain
# X.Y.Z release tag to stdout. The registry also lists prereleases (e.g.
# '1.11.0-preview.workerpools.1') and non-version tags such as
# 'artifacthub.io' and 'sha256-...' (artifact metadata); none of them is a
# "latest numbered release", and a non-numeric tag would raise in key() and
# turn into a bogus "lookup failed" if not filtered out first.
# Exits nonzero with nothing printed on invalid JSON or when no tag matches
# the X.Y.Z shape.
latest_release_tag() {
  python3 -c "
import json, re, sys
try:
    tags = json.load(sys.stdin)['tags']
except (json.JSONDecodeError, KeyError, TypeError):
    sys.exit(1)
numbered = [t for t in tags if re.fullmatch(r'[0-9]+\.[0-9]+\.[0-9]+', t)]
if not numbered:
    sys.exit(1)
def key(v):
    return tuple(int(x) for x in v.split('.'))
print(sorted(numbered, key=key)[-1])
"
}
