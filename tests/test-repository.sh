#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

required_files=(
  README.md
  LICENSE
  CONTRIBUTING.md
  SECURITY.md
  .gitignore
  .env.example
  .github/workflows/test.yml
  scripts/region-relay.sh
  scripts/bootstrap-tailscale-exit-node.sh
  infra/scheduler.yaml
  docs/aws-account-prerequisites.md
  docs/operations.md
  tests/fake-aws
  tests/test-lifecycle.sh
)

for path in "${required_files[@]}"; do
  [[ -f "$ROOT/$path" ]] || fail "missing public repository file: $path"
done

for path in \
  scripts/region-relay.sh \
  scripts/bootstrap-tailscale-exit-node.sh \
  tests/fake-aws \
  tests/test-lifecycle.sh; do
  [[ -x "$ROOT/$path" ]] || fail "$path is not executable"
done

bash -n \
  "$ROOT/scripts/region-relay.sh" \
  "$ROOT/scripts/bootstrap-tailscale-exit-node.sh" \
  "$ROOT/tests/fake-aws" \
  "$ROOT/tests/test-lifecycle.sh"

for ignored in outputs/ work/ docs/superpowers/ AGENTS.md .env; do
  grep -Fx "$ignored" "$ROOT/.gitignore" >/dev/null || fail ".gitignore does not exclude $ignored"
done

public_paths=(
  "$ROOT/README.md"
  "$ROOT/CONTRIBUTING.md"
  "$ROOT/SECURITY.md"
  "$ROOT/.env.example"
  "$ROOT/scripts"
  "$ROOT/infra"
  "$ROOT/docs/aws-account-prerequisites.md"
  "$ROOT/docs/operations.md"
  "$ROOT/tests/fake-aws"
  "$ROOT/tests/test-lifecycle.sh"
)

forbidden_terms='hot''star|jio''hot''star|net''flix|fi''re[ -]?tv|streaming by''pass|geo.?block'
if rg -n -i "$forbidden_terms" "${public_paths[@]}"; then
  fail 'public repository contains service-specific or bypass-oriented wording'
fi

if rg -n '537022804654|520646130785|65\.2\.130\.170|15\.222\.240\.46' "${public_paths[@]}"; then
  fail 'public repository contains account-specific identifiers or observed public IPs'
fi

VPN_AWS_BIN=/bin/false "$ROOT/scripts/region-relay.sh" help >/dev/null

printf 'PASS: public repository checks\n'
