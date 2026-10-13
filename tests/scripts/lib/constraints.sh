#!/usr/bin/env bash
# Shared Terraform version-constraint evaluator for
# tests/scripts/check-version-drift.sh and its regression test,
# tests/scripts/test-version-drift-constraints.sh. Split into its own
# sourceable file because check-version-drift.sh runs network lookups at
# the top level and cannot itself be `source`d by a test.

# constraint_accepts <constraint> <version>
# Exit 0 when <version> satisfies the Terraform version constraint (comma
# separated; operators ~>, >=, >, <=, <, !=, = or none), 1 when it does not,
# 2 when the constraint cannot be parsed. Missing version parts count as 0.
constraint_accepts() {
  python3 - "$1" "$2" <<'PYEOF'
import re
import sys

constraint, version = sys.argv[1], sys.argv[2]


def parse(s):
    return tuple(int(x) for x in s.split("."))


def pad(t):
    return t + (0,) * (3 - len(t))


ver = pad(parse(version))
ok = True
for part in constraint.split(","):
    m = re.fullmatch(r"\s*(~>|>=|<=|!=|>|<|=)?\s*(\d+(?:\.\d+){0,2})\s*", part)
    if not m:
        sys.exit(2)
    op, lim = m.group(1) or "=", parse(m.group(2))
    p = pad(lim)
    if op == "=":
        ok = ok and ver == p
    elif op == "!=":
        ok = ok and ver != p
    elif op == ">=":
        ok = ok and ver >= p
    elif op == ">":
        ok = ok and ver > p
    elif op == "<=":
        ok = ok and ver <= p
    elif op == "<":
        ok = ok and ver < p
    else:  # ~>: the rightmost given component may grow, the one before it may not
        up = list(lim[: max(len(lim) - 1, 1)])
        up[-1] += 1
        ok = ok and ver >= p and ver < pad(tuple(up))
sys.exit(0 if ok else 1)
PYEOF
}
