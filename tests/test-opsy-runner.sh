#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
RUNNER=$ROOT/opsy/runner/run-region-relay.sh

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

new_fixture() {
  local fixture
  fixture=$(mktemp -d "${TMPDIR:-/tmp}/opsy-runner-test.XXXXXX")
  mkdir -p "$fixture/opsy/runner" "$fixture/scripts"
  cp "$RUNNER" "$fixture/opsy/runner/run-region-relay.sh"
  cat >"$fixture/scripts/region-relay.sh" <<'SCRIPT'
#!/usr/bin/env bash
set -euo pipefail
printf 'profile=%s\n' "${VPN_AWS_PROFILE-unset}" >"$CAPTURE_FILE"
printf 'account=%s\n' "${VPN_EXPECTED_ACCOUNT-unset}" >>"$CAPTURE_FILE"
printf 'args=' >>"$CAPTURE_FILE"
printf '<%s>' "$@" >>"$CAPTURE_FILE"
printf '\n' >>"$CAPTURE_FILE"
SCRIPT
  chmod +x "$fixture/opsy/runner/run-region-relay.sh" "$fixture/scripts/region-relay.sh"
  printf '%s\n' "$fixture"
}

run_valid() {
  local fixture=$1
  shift
  CAPTURE_FILE="$fixture/capture" \
    VPN_EXPECTED_ACCOUNT=123456789012 \
    "$@" "$fixture/opsy/runner/run-region-relay.sh"
}

test_up_uses_country_and_ambient_role() {
  local fixture
  fixture=$(new_fixture)
  trap 'rm -rf "$fixture"' RETURN

  CAPTURE_FILE="$fixture/capture" VPN_EXPECTED_ACCOUNT=123456789012 \
    OPSY_ACTION=up OPSY_COUNTRY=canada \
    "$fixture/opsy/runner/run-region-relay.sh"

  grep -Fx 'profile=' "$fixture/capture" >/dev/null || fail 'runner did not select ambient IAM credentials'
  grep -Fx 'account=123456789012' "$fixture/capture" >/dev/null || fail 'runner did not preserve the account guard'
  grep -Fx 'args=<--country><canada><--yes><up>' "$fixture/capture" >/dev/null || fail 'runner built the wrong up command'
}

test_down_is_global() {
  local fixture
  fixture=$(new_fixture)
  trap 'rm -rf "$fixture"' RETURN

  CAPTURE_FILE="$fixture/capture" VPN_EXPECTED_ACCOUNT=123456789012 \
    OPSY_ACTION=down OPSY_COUNTRY=uk \
    "$fixture/opsy/runner/run-region-relay.sh"

  grep -Fx 'args=<--yes><down>' "$fixture/capture" >/dev/null || fail 'down was not global'
}

test_hunt_passes_only_validated_prefixes_and_attempts() {
  local fixture
  fixture=$(new_fixture)
  trap 'rm -rf "$fixture"' RETURN

  CAPTURE_FILE="$fixture/capture" VPN_EXPECTED_ACCOUNT=123456789012 \
    OPSY_ACTION=hunt OPSY_COUNTRY=india OPSY_HUNT_ATTEMPTS=400 \
    OPSY_TARGET_PREFIXES='43.,65.0.' \
    "$fixture/opsy/runner/run-region-relay.sh"

  grep -Fx 'args=<--country><india><--yes><hunt-static-ip><--prefix><43.><--prefix><65.0.><--max-attempts><400>' "$fixture/capture" >/dev/null || fail 'runner built the wrong hunt command'
}

assert_rejected() {
  local label=$1 fixture
  shift
  fixture=$(new_fixture)
  if CAPTURE_FILE="$fixture/capture" "$@" "$fixture/opsy/runner/run-region-relay.sh" >/dev/null 2>&1; then
    rm -rf "$fixture"
    fail "$label was accepted"
  fi
  [[ ! -f $fixture/capture ]] || {
    rm -rf "$fixture"
    fail "$label reached RegionRelay"
  }
  rm -rf "$fixture"
}

test_invalid_inputs_are_rejected_before_region_relay() {
  assert_rejected 'missing expected account' env OPSY_ACTION=up OPSY_COUNTRY=india
  assert_rejected 'unknown action' env VPN_EXPECTED_ACCOUNT=123456789012 OPSY_ACTION='up;id' OPSY_COUNTRY=india
  assert_rejected 'unknown country' env VPN_EXPECTED_ACCOUNT=123456789012 OPSY_ACTION=up OPSY_COUNTRY=france
  assert_rejected 'zero attempts' env VPN_EXPECTED_ACCOUNT=123456789012 OPSY_ACTION=hunt OPSY_COUNTRY=india OPSY_HUNT_ATTEMPTS=0 OPSY_TARGET_PREFIXES=43.
  assert_rejected 'too many attempts' env VPN_EXPECTED_ACCOUNT=123456789012 OPSY_ACTION=hunt OPSY_COUNTRY=india OPSY_HUNT_ATTEMPTS=401 OPSY_TARGET_PREFIXES=43.
  assert_rejected 'non-numeric attempts' env VPN_EXPECTED_ACCOUNT=123456789012 OPSY_ACTION=hunt OPSY_COUNTRY=india OPSY_HUNT_ATTEMPTS=ten OPSY_TARGET_PREFIXES=43.
  assert_rejected 'shell prefix' env VPN_EXPECTED_ACCOUNT=123456789012 OPSY_ACTION=hunt OPSY_COUNTRY=india OPSY_HUNT_ATTEMPTS=10 'OPSY_TARGET_PREFIXES=43.;id'
  assert_rejected 'empty prefix list' env VPN_EXPECTED_ACCOUNT=123456789012 OPSY_ACTION=hunt OPSY_COUNTRY=india OPSY_HUNT_ATTEMPTS=10 OPSY_TARGET_PREFIXES=
}

test_up_uses_country_and_ambient_role
test_down_is_global
test_hunt_passes_only_validated_prefixes_and_attempts
test_invalid_inputs_are_rejected_before_region_relay

printf 'PASS: Region Relay Alexa CodeBuild runner tests\n'
