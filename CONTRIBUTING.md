# Contributing

Thanks for considering a contribution to `terraform-google-n8n`.

## Before you start

- Open an [issue](https://github.com/n8n-io/terraform-google-n8n/issues)
  for anything non-trivial before opening a PR. Aligning on the
  approach first avoids wasted work on both sides.
- For security findings, **do not** open a public issue. See
  [`SECURITY.md`](./SECURITY.md).
- For general n8n questions (not specific to this module), use the
  [n8n community forum](https://community.n8n.io/) instead.

## Development setup

The deep guide for working in this repo lives in [`AGENTS.md`](./AGENTS.md);
read it before making changes. It covers the local validation loop,
the test framework, and the quality bar this module is held to.

The short version:

```bash
# Stub credentials so the veksh/godaddy-dns provider initializes during
# `terraform test`. Required once per shell session (only the godaddy
# example needs it; the others run without any credentials).
export GODADDY_API_KEY=stub GODADDY_API_SECRET=stub

terraform fmt -recursive
terraform init -backend=false
terraform validate
terraform test -verbose
tflint --init && tflint --format compact
terraform-docs --output-check .
```

Repeat the `init / validate / test / tflint / terraform-docs` block
under every `examples/*` directory, `modules/controllers`, and
`modules/controllers/examples/direct-use`. The two controller targets have
no local `.terraform-docs.yml`, so a bare `terraform-docs --output-check .`
there prints help and checks nothing; pass the root config explicitly
(`--config ../../.terraform-docs.yml` and
`--config ../../../../.terraform-docs.yml`). The exact per-target commands
are in `AGENTS.md` ("Local development loop") and mirror the CI matrix in
`.github/workflows/terraform-tests.yml`. CI will run the same matrix on
your PR.

If you have [`task`](https://taskfile.dev) installed (`brew install
go-task`), `task ci` runs the fmt/validate/test/lint/docs matrix plus
chart-rendering and markdown checks across the module root and every
example in one command. It needs Terraform, tflint, terraform-docs,
Helm, jq, Python 3, and markdownlint-cli2 on `PATH`; CI's pinned tool versions
and setup steps are in `.github/workflows/terraform-tests.yml`.
See
[`Taskfile.yml`](./Taskfile.yml) for the individual targets (`task fmt`,
`task validate`, `task test`, `task lint`, `task docs`,
`task docs-generate`), including `task checkov` and `task version-drift`,
which `task ci` deliberately does not run.

## Commit messages

We follow [Conventional Commits](https://www.conventionalcommits.org/):

```
<type>(<optional scope>): <imperative summary, <72 chars>

<optional body explaining the why>
```

Common types: `feat`, `fix`, `docs`, `refactor`, `test`, `chore`.
Scope is optional but useful (e.g. `feat(cloudsql): add read replica
option`). Use the imperative mood ("add", not "added" or "adds").

## Pull requests

- Open PRs against `main`. Don't push directly to `main`; it's
  protected.
- One logical change per PR. Smaller PRs review faster.
- If you add a new input, surface it through a `terraform-docs`
  regeneration (`terraform-docs .`); CI checks that the README is in
  sync.
- If you add a non-trivial new resource or behavior, add a plan-time
  assertion in `tests/defaults.tftest.hcl` (or the relevant example's
  test suite).
- All CI checks must be green before merge.

See [`AGENTS.md`](./AGENTS.md) for details on adding inputs, adding
resources, and what *not* to change.
