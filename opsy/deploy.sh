#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
REGION=eu-west-1
STACK_NAME=region-relay-opsy
PROFILE=
ARTIFACT_BUCKET=
SKILL_ID=
ACCOUNT_ID=
TARGET_PREFIXES=

usage() {
  cat <<'EOF'
Usage: ./opsy/deploy.sh \
  --artifact-bucket BUCKET \
  --skill-id amzn1.ask.skill.UUID \
  --account-id 123456789012 \
  --target-prefixes 43.,65.0. \
  [--region eu-west-1] [--stack-name region-relay-opsy] [--profile PROFILE]

The artifact bucket must already exist in the deployment Region. The script
uploads a private runner zip, packages the Alexa Lambda, and deploys the stack.
EOF
}

die() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 2
}

aws_cli() {
  if [[ -n $PROFILE ]]; then
    aws "$@" --profile "$PROFILE"
  else
    aws "$@"
  fi
}

while (($#)); do
  case "$1" in
    --artifact-bucket) shift; (($#)) || die '--artifact-bucket requires a value'; ARTIFACT_BUCKET=$1 ;;
    --skill-id) shift; (($#)) || die '--skill-id requires a value'; SKILL_ID=$1 ;;
    --account-id) shift; (($#)) || die '--account-id requires a value'; ACCOUNT_ID=$1 ;;
    --target-prefixes) shift; (($#)) || die '--target-prefixes requires a value'; TARGET_PREFIXES=$1 ;;
    --region) shift; (($#)) || die '--region requires a value'; REGION=$1 ;;
    --stack-name) shift; (($#)) || die '--stack-name requires a value'; STACK_NAME=$1 ;;
    --profile) shift; (($#)) || die '--profile requires a value'; PROFILE=$1 ;;
    -h|--help) usage; exit 0 ;;
    *) die "Unknown argument: $1" ;;
  esac
  shift
done

[[ -n $ARTIFACT_BUCKET ]] || die '--artifact-bucket is required'
[[ $SKILL_ID =~ ^amzn1\.ask\.skill\.[A-Za-z0-9-]+$ ]] || die 'invalid Alexa Skill ID'
[[ $ACCOUNT_ID =~ ^[0-9]{12}$ ]] || die 'account ID must contain exactly 12 digits'
[[ $TARGET_PREFIXES =~ ^[0-9.]+(,[0-9.]+)*$ ]] || die 'target prefixes must be comma-separated digits and dots with no spaces'
[[ $REGION =~ ^[a-z]{2}(-gov)?-[a-z]+-[0-9]$ ]] || die 'invalid AWS Region'
[[ $STACK_NAME =~ ^[A-Za-z][A-Za-z0-9-]{0,127}$ ]] || die 'invalid CloudFormation stack name'

aws --version >/dev/null
python3 - "$(aws --version 2>&1)" <<'PY'
import re
import sys

match = re.search(r"aws-cli/(\d+)\.(\d+)\.(\d+)", sys.argv[1])
if not match or tuple(map(int, match.groups())) < (2, 32, 0):
    raise SystemExit("AWS CLI 2.32.0 or newer is required")
PY

caller_account=$(aws_cli sts get-caller-identity --region "$REGION" --query Account --output text --no-cli-pager)
[[ $caller_account == "$ACCOUNT_ID" ]] || die "authenticated to account $caller_account, expected $ACCOUNT_ID"
aws_cli s3api head-bucket --bucket "$ARTIFACT_BUCKET" >/dev/null

TEMP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/region-relay-opsy.XXXXXX")
trap 'rm -rf "$TEMP_DIR"' EXIT INT TERM

RUNNER_ZIP=$TEMP_DIR/runner.zip
(
  cd "$ROOT"
  zip -q -r "$RUNNER_ZIP" scripts/region-relay.sh opsy/runner
)
runner_digest=$(shasum -a 256 "$RUNNER_ZIP" | awk '{print substr($1,1,16)}')
runner_key="$STACK_NAME/runner-$runner_digest.zip"

aws_cli s3 cp "$RUNNER_ZIP" "s3://$ARTIFACT_BUCKET/$runner_key" \
  --region "$REGION" --sse AES256 --only-show-errors

aws_cli cloudformation package \
  --region "$REGION" \
  --template-file "$ROOT/opsy/template.yaml" \
  --s3-bucket "$ARTIFACT_BUCKET" \
  --s3-prefix "$STACK_NAME/lambda" \
  --output-template-file "$TEMP_DIR/packaged.yaml"

aws_cli cloudformation deploy \
  --region "$REGION" \
  --stack-name "$STACK_NAME" \
  --template-file "$TEMP_DIR/packaged.yaml" \
  --capabilities CAPABILITY_IAM \
  --no-fail-on-empty-changeset \
  --parameter-overrides \
    AlexaSkillId="$SKILL_ID" \
    ExpectedAwsAccountId="$ACCOUNT_ID" \
    TargetIpPrefixes="$TARGET_PREFIXES" \
    RunnerSourceBucket="$ARTIFACT_BUCKET" \
    RunnerSourceKey="$runner_key"

aws_cli cloudformation describe-stacks \
  --region "$REGION" \
  --stack-name "$STACK_NAME" \
  --query 'Stacks[0].Outputs[].[OutputKey,OutputValue]' \
  --output table \
  --no-cli-pager
