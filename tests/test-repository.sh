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
  opsy/template.yaml
  opsy/deploy.sh
  opsy/interaction-models/en-US.json
  opsy/interaction-models/en-GB.json
  opsy/runner/buildspec.yml
  opsy/runner/run-region-relay.sh
  opsy/skill/handler.py
  opsy/skill/service.py
  docs/alexa-opsy.md
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
  opsy/deploy.sh \
  opsy/runner/run-region-relay.sh \
  tests/fake-aws \
  tests/test-opsy-runner.sh \
  tests/test-lifecycle.sh; do
  [[ -x "$ROOT/$path" ]] || fail "$path is not executable"
done

bash -n \
  "$ROOT/scripts/region-relay.sh" \
  "$ROOT/scripts/bootstrap-tailscale-exit-node.sh" \
  "$ROOT/opsy/deploy.sh" \
  "$ROOT/opsy/runner/run-region-relay.sh" \
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
  "$ROOT/opsy"
  "$ROOT/docs/alexa-opsy.md"
  "$ROOT/infra"
  "$ROOT/docs/aws-account-prerequisites.md"
  "$ROOT/docs/operations.md"
  "$ROOT/tests/fake-aws"
  "$ROOT/tests/test-opsy-runner.sh"
  "$ROOT/tests/test-lifecycle.sh"
)

forbidden_terms='hot''star|jio''hot''star|net''flix|fi''re[ -]?tv|streaming by''pass|geo.?block'
if rg -n -i "$forbidden_terms" "${public_paths[@]}"; then
  fail 'public repository contains service-specific or bypass-oriented wording'
fi

if rg -n '537022804654|520646130785|65\.2\.130\.170|15\.222\.240\.46' "${public_paths[@]}"; then
  fail 'public repository contains account-specific identifiers or observed public IPs'
fi

for model in "$ROOT/opsy/interaction-models/en-US.json" "$ROOT/opsy/interaction-models/en-GB.json"; do
  python3 -m json.tool "$model" >/dev/null
  python3 - "$model" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as source:
    model = json.load(source)["interactionModel"]
language = model["languageModel"]
assert language["invocationName"] == "region relay"
names = {intent["name"] for intent in language["intents"]}
required = {
    "StartExitNodeIntent",
    "StartIpHuntIntent",
    "RotatePublicIpIntent",
    "ExitNodeStatusIntent",
    "StopExitNodeIntent",
    "AMAZON.HelpIntent",
    "AMAZON.CancelIntent",
    "AMAZON.StopIntent",
}
assert required <= names
stop = next(item for item in model["dialog"]["intents"] if item["name"] == "StopExitNodeIntent")
assert stop["confirmationRequired"] is True
prompt_id = stop["prompts"]["confirmation"]
prompts = {item["id"]: item for item in model["prompts"]}
assert prompt_id in prompts
PY
done

ruby -e 'require "psych"; Psych.parse_file(ARGV.fetch(0))' "$ROOT/opsy/template.yaml"
grep -F 'AWSAgentToolkit: aws-cloudformation@3' "$ROOT/opsy/template.yaml" >/dev/null || fail 'Opsy template lacks the CloudFormation toolkit marker'
grep -F 'EventSourceToken: !Ref AlexaSkillId' "$ROOT/opsy/template.yaml" >/dev/null || fail 'Alexa invocation permission is not scoped to the Skill ID'
grep -F 'RetentionInDays: 30' "$ROOT/opsy/template.yaml" >/dev/null || fail 'Opsy logs do not have bounded retention'

VPN_AWS_BIN=/bin/false "$ROOT/scripts/region-relay.sh" help >/dev/null
"$ROOT/opsy/deploy.sh" --help >/dev/null

printf 'PASS: public repository checks\n'
