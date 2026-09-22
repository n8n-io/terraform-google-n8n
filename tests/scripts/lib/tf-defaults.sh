#!/usr/bin/env bash
# Shared helpers for reading a pin straight out of this module's own .tf
# source, so tests/scripts/check-version-drift.sh,
# tests/scripts/check-helm-chart-coverage.sh, and
# tests/scripts/chart-values-diff.sh each read the same value the module
# actually uses instead of three copies of the same regex drifting apart.
#
# Both functions print to stdout and return nonzero (with nothing printed)
# if the pattern is not found, so callers can distinguish "not found" from
# "found, empty string".

# tf_var_default <file> <variable_name>
# Reads the `default = "..."` (or bare, unquoted) value of a top-level
# `variable "<variable_name>" { ... }` block. Only handles a single-line
# string/bare default, which is every pin this module reads this way
# (n8n_chart_version, keda_chart_version, postgres_version).
tf_var_default() {
  local file="$1" name="$2"
  python3 - "$file" "$name" <<'PYEOF'
import re
import sys

path, name = sys.argv[1], sys.argv[2]
with open(path) as f:
    text = f.read()

# Find the variable block by brace-matching from `variable "<name>" {`.
m = re.search(r'variable\s+"' + re.escape(name) + r'"\s*\{', text)
if not m:
    sys.exit(1)

start = m.end() - 1  # index of the opening brace
depth = 0
end = None
for i in range(start, len(text)):
    if text[i] == "{":
        depth += 1
    elif text[i] == "}":
        depth -= 1
        if depth == 0:
            end = i
            break
if end is None:
    sys.exit(1)

block = text[start:end]
dm = re.search(r'^\s*default\s*=\s*"([^"]*)"', block, re.MULTILINE)
if not dm:
    sys.exit(1)
print(dm.group(1))
PYEOF
}

# tf_provider_version <file> <provider_source_name>
# Reads the `version = "..."` constraint of a `required_providers` entry,
# e.g. `tf_provider_version versions.tf kubernetes` for
# `kubernetes = { source = "hashicorp/kubernetes", version = "~> 3.0" }`.
tf_provider_version() {
  local file="$1" name="$2"
  python3 - "$file" "$name" <<'PYEOF'
import re
import sys

path, name = sys.argv[1], sys.argv[2]
with open(path) as f:
    text = f.read()

m = re.search(r'\b' + re.escape(name) + r'\s*=\s*\{', text)
if not m:
    sys.exit(1)

start = m.end() - 1
depth = 0
end = None
for i in range(start, len(text)):
    if text[i] == "{":
        depth += 1
    elif text[i] == "}":
        depth -= 1
        if depth == 0:
            end = i
            break
if end is None:
    sys.exit(1)

block = text[start:end]
vm = re.search(r'version\s*=\s*"([^"]*)"', block)
if not vm:
    sys.exit(1)
print(vm.group(1))
PYEOF
}
