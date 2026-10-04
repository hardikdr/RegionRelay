#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
SCRIPT="$ROOT/scripts/region-relay.sh"
FAKE_AWS="$ROOT/tests/fake-aws"

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

assert_contains() {
  local file=$1 expected=$2
  grep -F -- "$expected" "$file" >/dev/null || fail "expected '$expected' in $file"
}

assert_not_contains() {
  local file=$1 unexpected=$2
  if grep -F -- "$unexpected" "$file" >/dev/null; then
    fail "did not expect '$unexpected' in $file"
  fi
}

assert_before() {
  local file=$1 first=$2 second=$3 first_line second_line
  first_line=$(grep -nF -- "$first" "$file" | head -n1 | cut -d: -f1)
  second_line=$(grep -nF -- "$second" "$file" | head -n1 | cut -d: -f1)
  [[ -n $first_line && -n $second_line && $first_line -lt $second_line ]] || \
    fail "expected '$first' before '$second' in $file"
}

new_state() {
  mktemp -d "${TMPDIR:-/tmp}/vpn-exit-test.XXXXXX"
}

region_state() {
  printf '%s/regions/%s\n' "$1" "$2"
}

seed_region() {
  local path
  path=$(region_state "$1" "$2")
  mkdir -p "$path"
  : >"$path/static-ip"
  : >"$path/allocated-static-ips"
  : >"$path/snapshots"
  : >"$path/candidate-ips"
}

run_script() {
  FAKE_STATE_DIR=$1 \
    VPN_AWS_BIN="$FAKE_AWS" \
    VPN_NOW_UTC="2026-10-04T10:00:00Z" \
    VPN_RUN_ID="test-run" \
    VPN_POLL_SECONDS=0 \
    VPN_HUNT_DELAY_SECONDS=0 \
    VPN_MAX_POLLS=3 \
    "$SCRIPT" "${@:2}"
}

test_down_reuses_ready_snapshot_and_releases_ip() {
  local state output
  state=$(new_state)
  trap 'rm -rf "$state"' RETURN
  printf 'running\n' >"$state/instance"
  printf '43.204.243.85\n' >"$state/public-ip"
  printf 'india-exit-mumbai-ip-2\n' >"$state/static-ip"
  printf 'india-exit-mumbai-lifecycle-old\n' >"$state/snapshots"

  output=$(run_script "$state" --yes down)

  [[ ! -f $state/instance ]] || fail 'down left the instance running'
  [[ $(<"$state/snapshots") == 'india-exit-mumbai-lifecycle-old' ]] || fail 'down replaced the ready snapshot'
  assert_not_contains "$state/aws.log" 'create-instance-snapshot'
  assert_not_contains "$state/aws.log" 'delete-instance-snapshot'
  assert_contains "$state/aws.log" 'detach-static-ip --static-ip-name india-exit-mumbai-ip-2'
  assert_contains "$state/aws.log" 'release-static-ip --static-ip-name india-exit-mumbai-ip-2'
  assert_before "$state/aws.log" 'get-instance-snapshots' 'delete-instance --instance-name india-exit-mumbai'
  printf '%s\n' "$output" | grep -F 'Exit node is down' >/dev/null || fail 'down did not report completion'
}

test_up_restores_latest_snapshot_without_static_ip_and_closes_ports() {
  local state output
  state=$(new_state)
  trap 'rm -rf "$state"' RETURN
  : >"$state/static-ip"
  printf 'india-exit-mumbai-lifecycle-20261002T200000Z\n' >"$state/snapshots"
  printf '203.0.113.20\n' >"$state/next-public-ip"

  output=$(run_script "$state" --yes up)

  [[ -f $state/instance ]] || fail 'up did not create the instance'
  assert_contains "$state/aws.log" 'create-instances-from-snapshot'
  assert_contains "$state/aws.log" '--instance-snapshot-name india-exit-mumbai-lifecycle-20261002T200000Z'
  assert_contains "$state/aws.log" 'close-instance-public-ports --instance-name india-exit-mumbai --port-info'
  assert_not_contains "$state/aws.log" 'allocate-static-ip'
  assert_not_contains "$state/aws.log" 'attach-static-ip'
  printf '%s\n' "$output" | grep -F '203.0.113.20' >/dev/null || fail 'up did not report the public IP'
}

test_rotate_releases_static_ip_and_changes_dynamic_ip() {
  local state output
  state=$(new_state)
  trap 'rm -rf "$state"' RETURN
  printf 'running\n' >"$state/instance"
  printf '43.204.243.85\n' >"$state/public-ip"
  printf 'india-exit-mumbai-ip-2\n' >"$state/static-ip"
  printf '203.0.113.44\n' >"$state/next-public-ip"
  : >"$state/snapshots"

  output=$(run_script "$state" --yes rotate)

  assert_before "$state/aws.log" 'detach-static-ip' 'stop-instance'
  assert_before "$state/aws.log" 'stop-instance' 'start-instance'
  assert_contains "$state/aws.log" 'release-static-ip --static-ip-name india-exit-mumbai-ip-2'
  printf '%s\n' "$output" | grep -F '203.0.113.44' >/dev/null || fail 'rotate did not report the new IP'
}

test_expired_session_runs_aws_login_then_rechecks_identity() {
  local state
  state=$(new_state)
  trap 'rm -rf "$state"' RETURN
  touch "$state/auth-fails"
  printf 'running\n' >"$state/instance"
  printf '203.0.113.44\n' >"$state/public-ip"
  : >"$state/static-ip"
  printf 'india-exit-mumbai-lifecycle-20261002T200000Z\n' >"$state/snapshots"

  run_script "$state" --yes status >/dev/null

  assert_contains "$state/aws.log" 'login --profile region-relay'
  [[ $(grep -c 'sts get-caller-identity' "$state/aws.log") -eq 2 ]] || fail 'AWS identity was not rechecked after login'
}

test_toggle_defaults_to_down_when_instance_exists() {
  local state
  state=$(new_state)
  trap 'rm -rf "$state"' RETURN
  printf 'running\n' >"$state/instance"
  printf '203.0.113.44\n' >"$state/public-ip"
  : >"$state/static-ip"
  printf 'india-exit-mumbai-lifecycle-20261002T200000Z\n' >"$state/snapshots"

  run_script "$state" --yes >/dev/null

  [[ ! -f $state/instance ]] || fail 'no-argument toggle did not bring an existing instance down'
}

test_down_without_ready_snapshot_never_deletes_instance_or_releases_ip() {
  local state
  state=$(new_state)
  trap 'rm -rf "$state"' RETURN
  printf 'running\n' >"$state/instance"
  printf '43.204.243.85\n' >"$state/public-ip"
  printf 'india-exit-mumbai-ip-2\n' >"$state/static-ip"
  : >"$state/snapshots"

  if run_script "$state" --yes down >/dev/null 2>&1; then
    fail 'down succeeded without a ready snapshot'
  fi

  [[ -f $state/instance ]] || fail 'missing snapshot deleted the instance'
  assert_not_contains "$state/aws.log" 'delete-instance --instance-name india-exit-mumbai'
  assert_not_contains "$state/aws.log" 'release-static-ip'
  assert_not_contains "$state/aws.log" 'create-instance-snapshot'
}

test_snapshot_command_refreshes_snapshot_without_deleting_instance() {
  local state
  state=$(new_state)
  trap 'rm -rf "$state"' RETURN
  printf 'running\n' >"$state/instance"
  printf '203.0.113.44\n' >"$state/public-ip"
  : >"$state/static-ip"
  printf 'india-exit-mumbai-lifecycle-old\n' >"$state/snapshots"

  run_script "$state" --yes snapshot >/dev/null

  [[ -f $state/instance ]] || fail 'snapshot command deleted the instance'
  [[ $(wc -l <"$state/snapshots" | tr -d ' ') == 1 ]] || fail 'snapshot command did not retain exactly one snapshot'
  assert_not_contains "$state/snapshots" 'india-exit-mumbai-lifecycle-old'
  assert_contains "$state/aws.log" 'create-instance-snapshot'
  assert_contains "$state/aws.log" 'delete-instance-snapshot --instance-snapshot-name india-exit-mumbai-lifecycle-old'
  assert_not_contains "$state/aws.log" 'delete-instance --instance-name india-exit-mumbai'
}

test_usage_reports_month_to_date_bandwidth_and_costs() {
  local state output
  state=$(new_state)
  trap 'rm -rf "$state"' RETURN
  printf 'running\n' >"$state/instance"
  printf '203.0.113.44\n' >"$state/public-ip"
  : >"$state/static-ip"
  printf 'india-exit-mumbai-lifecycle-20261002T200000Z\n' >"$state/snapshots"
  cat >"$state/cost-explorer.json" <<'JSON'
{
  "ResultsByTime": [{
    "Estimated": true,
    "Groups": [
      {"Keys":["APS3-BundleUsage:0.5GB"],"Metrics":{"UsageQuantity":{"Amount":"12","Unit":"Hrs"},"UnblendedCost":{"Amount":"0.0804","Unit":"USD"}}},
      {"Keys":["APS3-SnapshotUsage"],"Metrics":{"UsageQuantity":{"Amount":"0.5","Unit":"GB-Month"},"UnblendedCost":{"Amount":"0.025","Unit":"USD"}}},
      {"Keys":["APS3-TotalDataXfer-In-Bytes"],"Metrics":{"UsageQuantity":{"Amount":"20","Unit":"GB"},"UnblendedCost":{"Amount":"0","Unit":"USD"}}},
      {"Keys":["APS3-TotalDataXfer-Out-Bytes"],"Metrics":{"UsageQuantity":{"Amount":"30","Unit":"GB"},"UnblendedCost":{"Amount":"0","Unit":"USD"}}},
      {"Keys":["APS3-DataXfer-Out-Overage-Bytes"],"Metrics":{"UsageQuantity":{"Amount":"0","Unit":"GB"},"UnblendedCost":{"Amount":"0","Unit":"USD"}}},
      {"Keys":["APS3-UnusedStaticIP"],"Metrics":{"UsageQuantity":{"Amount":"2","Unit":"Hrs"},"UnblendedCost":{"Amount":"0.01","Unit":"USD"}}}
    ]
  }]
}
JSON

  output=$(run_script "$state" usage)

  printf '%s\n' "$output" | grep -F 'Instance: india-exit-mumbai (running), public IPv4: 203.0.113.44' >/dev/null || fail 'usage did not report the current instance'
  printf '%s\n' "$output" | grep -F 'Plan: nano_3_1, $5.00/month maximum, billed hourly while the VM exists.' >/dev/null || fail 'usage did not report the plan price'
  printf '%s\n' "$output" | grep -F 'Bandwidth this month: 50.00 GB of 512.00 GB used (9.77%).' >/dev/null || fail 'usage did not report total bandwidth'
  printf '%s\n' "$output" | grep -F 'Incoming: 20.00 GB; outgoing: 30.00 GB; remaining: 462.00 GB.' >/dev/null || fail 'usage did not report the transfer breakdown'
  printf '%s\n' "$output" | grep -F 'Transfer overage: none.' >/dev/null || fail 'usage did not report zero overage'
  printf '%s\n' "$output" | grep -F 'Estimated Lightsail charges this month: $0.12 USD.' >/dev/null || fail 'usage did not report total charges'
  printf '%s\n' "$output" | grep -F 'VM: $0.08; snapshots: $0.03; unused static IPs: $0.01; transfer overage: $0.00.' >/dev/null || fail 'usage did not report the cost breakdown'
  printf '%s\n' "$output" | grep -F 'AWS billing data is estimated and can lag by several hours.' >/dev/null || fail 'usage did not explain billing delay'
}

test_schedule_down_creates_one_time_self_deleting_timer() {
  local state output
  state=$(new_state)
  trap 'rm -rf "$state"' RETURN
  printf 'running\n' >"$state/instance"
  printf '203.0.113.44\n' >"$state/public-ip"
  : >"$state/static-ip"
  printf 'india-exit-mumbai-lifecycle-20261002T200000Z\n' >"$state/snapshots"

  output=$(run_script "$state" schedule-down 2)

  [[ -f $state/schedule ]] || fail 'schedule-down did not create a timer'
  [[ $(<"$state/schedule") == 'at(2026-10-04T12:00:00)' ]] || fail 'schedule-down used the wrong execution time'
  assert_contains "$state/aws.log" 'scheduler create-schedule'
  assert_contains "$state/aws.log" '--action-after-completion DELETE'
  assert_contains "$state/aws.log" 'arn:aws:scheduler:::aws-sdk:lightsail:deleteInstance'
  assert_contains "$state/aws.log" '\"InstanceName\": \"india-exit-mumbai\"'
  printf '%s\n' "$output" | grep -F 'Automatic deletion scheduled for 2026-10-04 12:00:00 UTC' >/dev/null || fail 'schedule-down did not report the UTC deadline'
  printf '%s\n' "$output" | grep -F 'The ready lifecycle snapshot will be kept.' >/dev/null || fail 'schedule-down did not confirm snapshot retention'
}

test_schedule_down_replaces_existing_timer() {
  local state
  state=$(new_state)
  trap 'rm -rf "$state"' RETURN
  printf 'running\n' >"$state/instance"
  printf '203.0.113.44\n' >"$state/public-ip"
  : >"$state/static-ip"
  printf 'india-exit-mumbai-lifecycle-20261002T200000Z\n' >"$state/snapshots"
  printf 'at(2026-10-04T11:00:00)\n' >"$state/schedule"

  run_script "$state" schedule-down 2 >/dev/null

  assert_contains "$state/aws.log" 'scheduler update-schedule'
  assert_not_contains "$state/aws.log" 'scheduler create-schedule'
  [[ $(<"$state/schedule") == 'at(2026-10-04T12:00:00)' ]] || fail 'schedule-down did not replace the timer deadline'
}

test_cancel_down_removes_timer() {
  local state output
  state=$(new_state)
  trap 'rm -rf "$state"' RETURN
  printf 'running\n' >"$state/instance"
  printf '203.0.113.44\n' >"$state/public-ip"
  : >"$state/static-ip"
  printf 'india-exit-mumbai-lifecycle-20261002T200000Z\n' >"$state/snapshots"
  printf 'at(2026-10-04T12:00:00)\n' >"$state/schedule"

  output=$(run_script "$state" cancel-down)

  [[ ! -f $state/schedule ]] || fail 'cancel-down left the timer in place'
  assert_contains "$state/aws.log" 'scheduler delete-schedule'
  printf '%s\n' "$output" | grep -F 'Automatic deletion cancelled.' >/dev/null || fail 'cancel-down did not report cancellation'
}

test_down_cancels_timer_before_deleting_instance() {
  local state
  state=$(new_state)
  trap 'rm -rf "$state"' RETURN
  printf 'running\n' >"$state/instance"
  printf '203.0.113.44\n' >"$state/public-ip"
  : >"$state/static-ip"
  printf 'india-exit-mumbai-lifecycle-20261002T200000Z\n' >"$state/snapshots"
  printf 'at(2026-10-04T12:00:00)\n' >"$state/schedule"

  run_script "$state" --yes down >/dev/null

  assert_before "$state/aws.log" 'scheduler delete-schedule' 'lightsail delete-instance'
}

test_hunt_static_ip_attaches_match_and_releases_rejections() {
  local state output
  state=$(new_state)
  trap 'rm -rf "$state"' RETURN
  printf 'running\n' >"$state/instance"
  printf '13.200.1.10\n' >"$state/public-ip"
  : >"$state/static-ip"
  : >"$state/allocated-static-ips"
  printf '13.201.1.1\n15.206.1.2\n43.204.8.9\n65.0.1.3\n3.6.1.4\n' >"$state/candidate-ips"
  printf 'india-exit-mumbai-lifecycle-20261002T200000Z\n' >"$state/snapshots"

  output=$(run_script "$state" --yes hunt-static-ip --prefix 43. --max-attempts 5)

  [[ $(wc -l <"$state/allocated-static-ips" | tr -d ' ') == 1 ]] || fail 'hunt left rejected static IPs allocated'
  grep -F $'43.204.8.9\tindia-exit-mumbai' "$state/allocated-static-ips" >/dev/null || fail 'hunt did not attach the matching static IP'
  assert_contains "$state/aws.log" 'allocate-static-ip --static-ip-name india-exit-mumbai-hunt-test-run-1'
  assert_contains "$state/aws.log" 'tag-resource --resource-name india-exit-mumbai-hunt-test-run-1'
  assert_contains "$state/aws.log" 'release-static-ip --static-ip-name india-exit-mumbai-hunt-test-run-1'
  assert_contains "$state/aws.log" 'attach-static-ip --static-ip-name india-exit-mumbai-hunt-test-run-3 --instance-name india-exit-mumbai'
  printf '%s\n' "$output" | grep -F 'Selected static IPv4: 43.204.8.9' >/dev/null || fail 'hunt did not report the selected address'
}

test_hunt_static_ip_releases_everything_when_no_prefix_matches() {
  local state
  state=$(new_state)
  trap 'rm -rf "$state"' RETURN
  printf 'running\n' >"$state/instance"
  printf '13.200.1.10\n' >"$state/public-ip"
  : >"$state/static-ip"
  : >"$state/allocated-static-ips"
  printf '13.201.1.1\n15.206.1.2\n65.0.1.3\n' >"$state/candidate-ips"
  printf 'india-exit-mumbai-lifecycle-20261002T200000Z\n' >"$state/snapshots"

  if run_script "$state" --yes hunt-static-ip --prefix 43. --max-attempts 3 >/dev/null 2>&1; then
    fail 'hunt succeeded even though no address matched'
  fi

  [[ ! -s $state/allocated-static-ips ]] || fail 'failed hunt left static IPs allocated'
  [[ $(grep -c 'release-static-ip --static-ip-name india-exit-mumbai-hunt-' "$state/aws.log") -eq 3 ]] || fail 'failed hunt did not release every candidate'
}

test_down_releases_attached_and_unattached_automation_static_ips() {
  local state
  state=$(new_state)
  trap 'rm -rf "$state"' RETURN
  printf 'running\n' >"$state/instance"
  printf '43.204.8.9\n' >"$state/public-ip"
  printf 'legacy-attached-ip\n' >"$state/static-ip"
  cat >"$state/allocated-static-ips" <<'EOF'
india-exit-mumbai-hunt-old-1	43.204.1.1	-
india-exit-mumbai-hunt-old-2	43.204.1.2	india-exit-mumbai
unrelated-static-ip	198.51.100.10	-
EOF
  printf 'india-exit-mumbai-lifecycle-20261002T200000Z\n' >"$state/snapshots"

  run_script "$state" --yes down >/dev/null

  [[ ! -s $state/static-ip ]] || fail 'down left the legacy attached IP allocated'
  grep -F $'unrelated-static-ip\t198.51.100.10\t-' "$state/allocated-static-ips" >/dev/null || fail 'down removed an unrelated unattached static IP'
  [[ $(wc -l <"$state/allocated-static-ips" | tr -d ' ') == 1 ]] || fail 'down left automation static IPs allocated'
  assert_contains "$state/aws.log" 'release-static-ip --static-ip-name india-exit-mumbai-hunt-old-1'
  assert_contains "$state/aws.log" 'detach-static-ip --static-ip-name india-exit-mumbai-hunt-old-2'
  assert_contains "$state/aws.log" 'release-static-ip --static-ip-name india-exit-mumbai-hunt-old-2'
}

test_down_cleans_legacy_automation_ips_when_vm_is_already_absent() {
  local state
  state=$(new_state)
  trap 'rm -rf "$state"' RETURN
  : >"$state/static-ip"
  cat >"$state/allocated-static-ips" <<'EOF'
india-exit-mumbai-ip-legacy	43.204.1.3	-
india-exit-mumbai-hunt-old-1	43.204.1.1	-
unrelated-static-ip	198.51.100.10	-
EOF
  printf 'india-exit-mumbai-lifecycle-20261002T200000Z\n' >"$state/snapshots"

  run_script "$state" --yes down >/dev/null

  grep -F $'unrelated-static-ip\t198.51.100.10\t-' "$state/allocated-static-ips" >/dev/null || fail 'down removed an unrelated IP while VM was absent'
  [[ $(wc -l <"$state/allocated-static-ips" | tr -d ' ') == 1 ]] || fail 'down left legacy automation IPs while VM was absent'
}

test_hunt_with_existing_matching_ip_cleans_stale_automation_ips() {
  local state
  state=$(new_state)
  trap 'rm -rf "$state"' RETURN
  printf 'running\n' >"$state/instance"
  printf '43.204.1.2\n' >"$state/public-ip"
  : >"$state/static-ip"
  cat >"$state/allocated-static-ips" <<'EOF'
india-exit-mumbai-hunt-current	43.204.1.2	india-exit-mumbai
india-exit-mumbai-hunt-stale	13.200.1.1	-
EOF
  : >"$state/candidate-ips"
  printf 'india-exit-mumbai-lifecycle-20261002T200000Z\n' >"$state/snapshots"

  run_script "$state" --yes hunt-static-ip --prefix 43. --max-attempts 5 >/dev/null

  [[ $(wc -l <"$state/allocated-static-ips" | tr -d ' ') == 1 ]] || fail 'hunt left a stale automation IP next to an existing match'
  grep -F 'india-exit-mumbai-hunt-current' "$state/allocated-static-ips" >/dev/null || fail 'hunt released the existing matching IP'
}

test_successful_hunt_cancels_pending_direct_deletion_timer() {
  local state
  state=$(new_state)
  trap 'rm -rf "$state"' RETURN
  printf 'running\n' >"$state/instance"
  printf '13.200.1.10\n' >"$state/public-ip"
  : >"$state/static-ip"
  : >"$state/allocated-static-ips"
  printf '43.204.8.9\n' >"$state/candidate-ips"
  printf 'india-exit-mumbai-lifecycle-20261002T200000Z\n' >"$state/snapshots"
  printf 'at(2026-10-04T12:00:00)\n' >"$state/schedule"

  run_script "$state" --yes hunt-static-ip --prefix 43. --max-attempts 1 >/dev/null

  [[ ! -f $state/schedule ]] || fail 'successful hunt left a direct-deletion timer that could orphan the static IP'
  assert_before "$state/aws.log" 'scheduler delete-schedule' 'lightsail attach-static-ip'
}

test_country_defaults_to_india_for_country_local_command() {
  local state output
  state=$(new_state)
  trap 'rm -rf "$state"' RETURN
  printf 'running\n' >"$state/instance"
  printf '203.0.113.44\n' >"$state/public-ip"
  : >"$state/static-ip"
  printf 'india-exit-mumbai-lifecycle-20261002T200000Z\n' >"$state/snapshots"

  output=$(run_script "$state" status)

  printf '%s\n' "$output" | grep -F 'Country: india' >/dev/null || fail 'default country was not India'
  assert_contains "$state/aws.log" '--region ap-south-1'
}

test_country_aliases_map_to_canonical_regions() {
  local state uk output
  state=$(new_state)
  trap 'rm -rf "$state"' RETURN
  seed_region "$state" eu-west-2
  uk=$(region_state "$state" eu-west-2)
  printf 'running\n' >"$uk/instance"
  printf '198.51.100.20\n' >"$uk/public-ip"

  output=$(run_script "$state" --country gb status)

  printf '%s\n' "$output" | grep -F 'Country: uk' >/dev/null || fail 'gb alias did not canonicalize to uk'
  printf '%s\n' "$output" | grep -F 'Instance: stream-exit-uk (running)' >/dev/null || fail 'UK used the wrong instance name'
  assert_contains "$state/aws.log" '--region eu-west-2'
}

test_country_option_works_before_or_after_command() {
  local state uk before after
  state=$(new_state)
  trap 'rm -rf "$state"' RETURN
  seed_region "$state" eu-west-2
  uk=$(region_state "$state" eu-west-2)
  printf 'running\n' >"$uk/instance"
  printf '198.51.100.20\n' >"$uk/public-ip"

  before=$(run_script "$state" --country uk status)
  after=$(run_script "$state" status --country united-kingdom)

  [[ $before == "$after" ]] || fail '--country position changed command behavior'
}

test_invalid_or_missing_country_fails_before_aws_call() {
  local state
  state=$(new_state)
  trap 'rm -rf "$state"' RETURN

  if run_script "$state" --country mars status >/dev/null 2>&1; then
    fail 'invalid country succeeded'
  fi
  [[ ! -f $state/aws.log ]] || fail 'invalid country called AWS'
  if run_script "$state" --country >/dev/null 2>&1; then
    fail 'missing country value succeeded'
  fi
  [[ ! -f $state/aws.log ]] || fail 'missing country called AWS'
}

test_destination_region_and_bundle_are_validated_before_source_deletion() {
  local state india uk
  state=$(new_state)
  trap 'rm -rf "$state"' RETURN
  seed_region "$state" ap-south-1
  seed_region "$state" eu-west-2
  india=$(region_state "$state" ap-south-1)
  uk=$(region_state "$state" eu-west-2)
  printf 'running\n' >"$india/instance"
  printf '43.204.1.1\n' >"$india/public-ip"
  printf 'india-exit-mumbai-lifecycle-base\n' >"$india/snapshots"

  run_script "$state" --yes --country uk up >/dev/null

  assert_before "$state/aws.log" 'lightsail get-regions' 'lightsail delete-instance --instance-name india-exit-mumbai'
  assert_before "$state/aws.log" 'lightsail get-bundles' 'lightsail delete-instance --instance-name india-exit-mumbai'
  [[ -f $uk/instance ]] || fail 'validated UK destination was not created'
}

test_non_india_uses_regional_five_dollar_bundle() {
  local state india uk
  state=$(new_state)
  trap 'rm -rf "$state"' RETURN
  seed_region "$state" ap-south-1
  seed_region "$state" eu-west-2
  india=$(region_state "$state" ap-south-1)
  uk=$(region_state "$state" eu-west-2)
  printf 'india-exit-mumbai-lifecycle-base\n' >"$india/snapshots"

  run_script "$state" --yes --country uk up >/dev/null

  [[ -f $uk/instance ]] || fail 'UK instance was not created with its regional bundle'
  assert_contains "$state/aws.log" 'create-instances-from-snapshot --instance-names stream-exit-uk'
  assert_contains "$state/aws.log" '--bundle-id nano_3_0'
}

test_missing_bundle_leaves_current_vm_untouched() {
  local state india uk
  state=$(new_state)
  trap 'rm -rf "$state"' RETURN
  seed_region "$state" ap-south-1
  seed_region "$state" eu-west-2
  india=$(region_state "$state" ap-south-1)
  uk=$(region_state "$state" eu-west-2)
  printf 'running\n' >"$india/instance"
  printf '43.204.1.1\n' >"$india/public-ip"
  printf 'india-exit-mumbai-lifecycle-base\n' >"$india/snapshots"
  touch "$uk/no-bundle"

  if run_script "$state" --yes --country uk up >/dev/null 2>&1; then
    fail 'UK up succeeded without the configured bundle'
  fi
  [[ -f $india/instance ]] || fail 'bundle validation failure deleted the India VM'
  assert_not_contains "$state/aws.log" 'delete-instance --instance-name india-exit-mumbai'
}

test_missing_availability_zone_leaves_current_vm_untouched() {
  local state india uk
  state=$(new_state)
  trap 'rm -rf "$state"' RETURN
  seed_region "$state" ap-south-1
  seed_region "$state" eu-west-2
  india=$(region_state "$state" ap-south-1)
  uk=$(region_state "$state" eu-west-2)
  printf 'running\n' >"$india/instance"
  printf '43.204.1.1\n' >"$india/public-ip"
  printf 'india-exit-mumbai-lifecycle-base\n' >"$india/snapshots"
  touch "$uk/no-zone"

  if run_script "$state" --yes --country uk up >/dev/null 2>&1; then
    fail 'UK up succeeded without an availability zone'
  fi
  [[ -f $india/instance ]] || fail 'zone validation failure deleted the India VM'
  assert_not_contains "$state/aws.log" 'delete-instance --instance-name india-exit-mumbai'
}

test_cross_region_snapshot_copy_completes_before_source_vm_deletion() {
  local state india uk
  state=$(new_state)
  trap 'rm -rf "$state"' RETURN
  seed_region "$state" ap-south-1
  seed_region "$state" eu-west-2
  india=$(region_state "$state" ap-south-1)
  uk=$(region_state "$state" eu-west-2)
  printf 'running\n' >"$india/instance"
  printf '43.204.1.1\n' >"$india/public-ip"
  printf 'india-exit-mumbai-lifecycle-base\n' >"$india/snapshots"

  run_script "$state" --yes --country uk up >/dev/null

  assert_before "$state/aws.log" 'copy-snapshot --source-snapshot-name india-exit-mumbai-lifecycle-base' 'delete-instance --instance-name india-exit-mumbai'
  assert_before "$state/aws.log" 'get-instance-snapshot --instance-snapshot-name region-relay-transfer-uk-test-run' 'delete-instance --instance-name india-exit-mumbai'
  assert_before "$state/aws.log" 'delete-instance --instance-name india-exit-mumbai' 'create-instances-from-snapshot --instance-names stream-exit-uk'
  assert_contains "$state/aws.log" 'delete-instance-snapshot --instance-snapshot-name region-relay-transfer-uk-test-run'
  grep -Fx 'india-exit-mumbai-lifecycle-base' "$india/snapshots" >/dev/null || fail 'switch deleted the canonical Mumbai snapshot'
  [[ ! -s $uk/snapshots ]] || fail 'switch left the temporary UK snapshot'
}

test_failed_snapshot_copy_leaves_source_vm_running() {
  local state india uk
  state=$(new_state)
  trap 'rm -rf "$state"' RETURN
  seed_region "$state" ap-south-1
  seed_region "$state" eu-west-2
  india=$(region_state "$state" ap-south-1)
  uk=$(region_state "$state" eu-west-2)
  printf 'running\n' >"$india/instance"
  printf '43.204.1.1\n' >"$india/public-ip"
  printf 'india-exit-mumbai-lifecycle-base\n' >"$india/snapshots"
  touch "$uk/copy-error"

  if run_script "$state" --yes --country uk up >/dev/null 2>&1; then
    fail 'switch succeeded after snapshot copy failure'
  fi
  [[ -f $india/instance ]] || fail 'copy failure deleted the source VM'
  assert_not_contains "$state/aws.log" 'delete-instance --instance-name india-exit-mumbai'
}

test_launch_failure_preserves_canonical_snapshot_and_reports_india_recovery() {
  local state india uk output
  state=$(new_state)
  trap 'rm -rf "$state"' RETURN
  seed_region "$state" ap-south-1
  seed_region "$state" eu-west-2
  india=$(region_state "$state" ap-south-1)
  uk=$(region_state "$state" eu-west-2)
  printf 'running\n' >"$india/instance"
  printf '43.204.1.1\n' >"$india/public-ip"
  printf 'india-exit-mumbai-lifecycle-base\n' >"$india/snapshots"
  touch "$uk/create-error"

  if output=$(run_script "$state" --yes --country uk up 2>&1); then
    fail 'switch succeeded after destination create failure'
  fi
  grep -Fx 'india-exit-mumbai-lifecycle-base' "$india/snapshots" >/dev/null || fail 'launch failure deleted the canonical snapshot'
  printf '%s\n' "$output" | grep -F -- '--country india up' >/dev/null || fail 'launch failure omitted India recovery guidance'
}

test_cleanup_failure_prevents_destination_instance_creation() {
  local state india uk
  state=$(new_state)
  trap 'rm -rf "$state"' RETURN
  seed_region "$state" ap-south-1
  seed_region "$state" eu-west-2
  india=$(region_state "$state" ap-south-1)
  uk=$(region_state "$state" eu-west-2)
  printf 'running\n' >"$india/instance"
  printf '43.204.1.1\n' >"$india/public-ip"
  printf 'india-exit-mumbai-lifecycle-base\n' >"$india/snapshots"
  touch "$india/delete-error"

  if run_script "$state" --yes --country uk up >/dev/null 2>&1; then
    fail 'switch succeeded after source cleanup failure'
  fi
  [[ ! -f $uk/instance ]] || fail 'cleanup failure created a duplicate UK instance'
  assert_not_contains "$state/aws.log" 'create-instances-from-snapshot --instance-names stream-exit-uk'
}

test_down_without_country_cleans_all_supported_regions() {
  local state india uk canada
  state=$(new_state)
  trap 'rm -rf "$state"' RETURN
  seed_region "$state" ap-south-1
  seed_region "$state" eu-west-2
  seed_region "$state" ca-central-1
  seed_region "$state" ap-southeast-1
  india=$(region_state "$state" ap-south-1)
  uk=$(region_state "$state" eu-west-2)
  canada=$(region_state "$state" ca-central-1)
  printf 'running\n' >"$india/instance"
  printf '43.204.1.1\n' >"$india/public-ip"
  printf 'india-exit-mumbai-lifecycle-base\n' >"$india/snapshots"
  printf 'running\n' >"$uk/instance"
  printf '198.51.100.20\n' >"$uk/public-ip"
  printf 'stream-exit-uk-hunt-old\t198.51.100.30\tstream-exit-uk\n' >"$uk/allocated-static-ips"
  printf 'running\n' >"$canada/instance"
  printf '198.51.100.40\n' >"$canada/public-ip"

  run_script "$state" --yes down >/dev/null

  [[ ! -f $india/instance && ! -f $uk/instance && ! -f $canada/instance ]] || fail 'global down left an owned VM'
  [[ ! -s $uk/allocated-static-ips ]] || fail 'global down left a UK automation static IP'
}

test_down_with_country_only_cleans_selected_region() {
  local state india uk
  state=$(new_state)
  trap 'rm -rf "$state"' RETURN
  seed_region "$state" ap-south-1
  seed_region "$state" eu-west-2
  india=$(region_state "$state" ap-south-1)
  uk=$(region_state "$state" eu-west-2)
  printf 'running\n' >"$india/instance"
  printf '43.204.1.1\n' >"$india/public-ip"
  printf 'india-exit-mumbai-lifecycle-base\n' >"$india/snapshots"
  printf 'running\n' >"$uk/instance"
  printf '198.51.100.20\n' >"$uk/public-ip"

  run_script "$state" --yes --country uk down >/dev/null

  [[ -f $india/instance ]] || fail 'UK-only down deleted India'
  [[ ! -f $uk/instance ]] || fail 'UK-only down left UK running'
}

test_status_without_country_reports_all_regions_read_only() {
  local state india output
  state=$(new_state)
  trap 'rm -rf "$state"' RETURN
  seed_region "$state" ap-south-1
  seed_region "$state" eu-west-2
  seed_region "$state" ca-central-1
  seed_region "$state" ap-southeast-1
  india=$(region_state "$state" ap-south-1)
  printf 'india-exit-mumbai-lifecycle-base\n' >"$india/snapshots"

  output=$(run_script "$state" status)

  for country in india uk canada singapore; do
    printf '%s\n' "$output" | grep -F "Country: $country" >/dev/null || fail "global status omitted $country"
  done
  assert_not_contains "$state/aws.log" 'delete-instance'
  assert_not_contains "$state/aws.log" 'release-static-ip'
}

test_non_india_status_reports_mumbai_canonical_snapshot() {
  local state india uk output
  state=$(new_state)
  trap 'rm -rf "$state"' RETURN
  seed_region "$state" ap-south-1
  seed_region "$state" eu-west-2
  india=$(region_state "$state" ap-south-1)
  uk=$(region_state "$state" eu-west-2)
  printf 'india-exit-mumbai-lifecycle-base\n' >"$india/snapshots"
  printf 'running\n' >"$uk/instance"
  printf '198.51.100.20\n' >"$uk/public-ip"

  output=$(run_script "$state" --country uk status)

  printf '%s\n' "$output" | grep -F 'Canonical ready snapshot: india-exit-mumbai-lifecycle-base' >/dev/null || fail 'non-India status hid the Mumbai recovery snapshot'
}

test_static_ip_hunt_uses_only_selected_region_and_country_prefix() {
  local state uk
  state=$(new_state)
  trap 'rm -rf "$state"' RETURN
  seed_region "$state" eu-west-2
  uk=$(region_state "$state" eu-west-2)
  printf 'running\n' >"$uk/instance"
  printf '198.51.100.20\n' >"$uk/public-ip"
  printf '43.1.2.3\n' >"$uk/candidate-ips"

  run_script "$state" --yes --country uk hunt-static-ip --prefix 43. --max-attempts 1 >/dev/null

  assert_contains "$state/aws.log" 'allocate-static-ip --static-ip-name stream-exit-uk-hunt-test-run-1'
  assert_contains "$state/aws.log" '--region eu-west-2'
  grep -F $'stream-exit-uk-hunt-test-run-1\t43.1.2.3\tstream-exit-uk' "$uk/allocated-static-ips" >/dev/null || fail 'UK hunt did not attach the selected UK address'
}

test_schedule_down_uses_selected_region_stack() {
  local state india uk
  state=$(new_state)
  trap 'rm -rf "$state"' RETURN
  seed_region "$state" ap-south-1
  seed_region "$state" eu-west-2
  india=$(region_state "$state" ap-south-1)
  uk=$(region_state "$state" eu-west-2)
  printf 'india-exit-mumbai-lifecycle-base\n' >"$india/snapshots"
  printf 'running\n' >"$uk/instance"
  printf '198.51.100.20\n' >"$uk/public-ip"

  run_script "$state" --country uk schedule-down 2 >/dev/null

  [[ -f $uk/schedule ]] || fail 'UK timer was not stored in the UK Region'
  assert_contains "$state/aws.log" 'scheduler create-schedule'
  assert_contains "$state/aws.log" 'stream-exit-uk'
  grep -F 'scheduler create-schedule' "$state/aws.log" | grep -F -- '--region eu-west-2' >/dev/null || fail 'scheduler was not called in eu-west-2'
}

test_country_switch_cancels_existing_schedules_in_other_regions() {
  local state india uk
  state=$(new_state)
  trap 'rm -rf "$state"' RETURN
  seed_region "$state" ap-south-1
  seed_region "$state" eu-west-2
  india=$(region_state "$state" ap-south-1)
  uk=$(region_state "$state" eu-west-2)
  printf 'india-exit-mumbai-lifecycle-base\n' >"$india/snapshots"
  printf 'at(2026-10-06T12:00:00)\n' >"$india/schedule"
  printf 'running\n' >"$uk/instance"
  printf '198.51.100.20\n' >"$uk/public-ip"

  run_script "$state" --yes --country uk up >/dev/null

  [[ ! -f $india/schedule ]] || fail 'country switch left the India timer active'
  assert_contains "$state/aws.log" 'scheduler delete-schedule'
}

test_usage_filters_cost_explorer_by_selected_region() {
  local state uk
  state=$(new_state)
  trap 'rm -rf "$state"' RETURN
  seed_region "$state" eu-west-2
  uk=$(region_state "$state" eu-west-2)
  printf '{"ResultsByTime":[]}' >"$state/cost-explorer.json"

  run_script "$state" --country uk usage >/dev/null

  grep -F 'ce get-cost-and-usage' "$state/aws.log" | grep -F '"Key":"REGION","Values":["eu-west-2"]' >/dev/null || fail 'Cost Explorer request was not filtered to eu-west-2'
}

test_snapshot_outside_india_promotes_new_canonical_copy_to_mumbai() {
  local state india uk
  state=$(new_state)
  trap 'rm -rf "$state"' RETURN
  seed_region "$state" ap-south-1
  seed_region "$state" eu-west-2
  india=$(region_state "$state" ap-south-1)
  uk=$(region_state "$state" eu-west-2)
  printf 'india-exit-mumbai-lifecycle-old\n' >"$india/snapshots"
  printf 'running\n' >"$uk/instance"
  printf '198.51.100.20\n' >"$uk/public-ip"

  run_script "$state" --yes --country uk snapshot >/dev/null

  [[ $(wc -l <"$india/snapshots" | tr -d ' ') == 1 ]] || fail 'snapshot promotion did not leave exactly one Mumbai canonical snapshot'
  grep -F 'india-exit-mumbai-lifecycle-' "$india/snapshots" >/dev/null || fail 'promoted snapshot does not use the canonical Mumbai prefix'
  [[ ! -s $uk/snapshots ]] || fail 'snapshot promotion left the local UK source snapshot'
  assert_before "$state/aws.log" 'copy-snapshot --source-snapshot-name stream-exit-uk-lifecycle-' 'delete-instance-snapshot --instance-snapshot-name india-exit-mumbai-lifecycle-old'
  assert_before "$state/aws.log" 'get-instance-snapshot --instance-snapshot-name india-exit-mumbai-lifecycle-' 'delete-instance-snapshot --instance-snapshot-name india-exit-mumbai-lifecycle-old'
}

chmod +x "$FAKE_AWS"

test_down_reuses_ready_snapshot_and_releases_ip
test_up_restores_latest_snapshot_without_static_ip_and_closes_ports
test_rotate_releases_static_ip_and_changes_dynamic_ip
test_expired_session_runs_aws_login_then_rechecks_identity
test_toggle_defaults_to_down_when_instance_exists
test_down_without_ready_snapshot_never_deletes_instance_or_releases_ip
test_snapshot_command_refreshes_snapshot_without_deleting_instance
test_usage_reports_month_to_date_bandwidth_and_costs
test_schedule_down_creates_one_time_self_deleting_timer
test_schedule_down_replaces_existing_timer
test_cancel_down_removes_timer
test_down_cancels_timer_before_deleting_instance
test_hunt_static_ip_attaches_match_and_releases_rejections
test_hunt_static_ip_releases_everything_when_no_prefix_matches
test_down_releases_attached_and_unattached_automation_static_ips
test_down_cleans_legacy_automation_ips_when_vm_is_already_absent
test_hunt_with_existing_matching_ip_cleans_stale_automation_ips
test_successful_hunt_cancels_pending_direct_deletion_timer
test_country_defaults_to_india_for_country_local_command
test_country_aliases_map_to_canonical_regions
test_country_option_works_before_or_after_command
test_invalid_or_missing_country_fails_before_aws_call
test_destination_region_and_bundle_are_validated_before_source_deletion
test_non_india_uses_regional_five_dollar_bundle
test_missing_bundle_leaves_current_vm_untouched
test_missing_availability_zone_leaves_current_vm_untouched
test_cross_region_snapshot_copy_completes_before_source_vm_deletion
test_failed_snapshot_copy_leaves_source_vm_running
test_launch_failure_preserves_canonical_snapshot_and_reports_india_recovery
test_cleanup_failure_prevents_destination_instance_creation
test_down_without_country_cleans_all_supported_regions
test_down_with_country_only_cleans_selected_region
test_status_without_country_reports_all_regions_read_only
test_non_india_status_reports_mumbai_canonical_snapshot
test_static_ip_hunt_uses_only_selected_region_and_country_prefix
test_schedule_down_uses_selected_region_stack
test_country_switch_cancels_existing_schedules_in_other_regions
test_usage_filters_cost_explorer_by_selected_region
test_snapshot_outside_india_promotes_new_canonical_copy_to_mumbai

printf 'PASS: region-relay-exit-node lifecycle tests\n'
