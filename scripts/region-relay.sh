#!/usr/bin/env bash
set -euo pipefail

# Lifecycle helper for regional Amazon Lightsail Tailscale exit nodes.
# No AWS or Tailscale credentials are stored by this script.

PROFILE=${VPN_AWS_PROFILE:-region-relay}
COUNTRY=${VPN_COUNTRY:-india}
COUNTRY_EXPLICIT=false
REGION=ap-south-1
AZ=ap-south-1a
INSTANCE_NAME=india-exit-mumbai
BUNDLE_ID=nano_3_1
SNAPSHOT_PREFIX=india-exit-mumbai-lifecycle
TAILSCALE_HOSTNAME=${VPN_TAILSCALE_HOSTNAME:-aws-exit-node}
AWS_BIN=${VPN_AWS_BIN:-aws}
BILLING_REGION=${VPN_BILLING_REGION:-us-east-1}
POLL_SECONDS=${VPN_POLL_SECONDS:-5}
MAX_POLLS=${VPN_MAX_POLLS:-120}
ROTATE_ATTEMPTS=${VPN_ROTATE_ATTEMPTS:-3}
STATIC_IP_PREFIX=india-exit-mumbai-hunt
HUNT_DELAY_SECONDS=${VPN_HUNT_DELAY_SECONDS:-2}
RUN_ID=${VPN_RUN_ID:-$(date -u '+%Y%m%dT%H%M%SZ')-$$}
SCHEDULER_STACK=${VPN_SCHEDULER_STACK:-region-relay-scheduler}
SCHEDULE_NAME=${VPN_SCHEDULE_NAME:-region-relay-auto-down}
NOW_UTC=${VPN_NOW_UTC:-}

YES=false
COMMAND=
COMMAND_ARG=
COMMAND_IMPLICIT=false
HUNT_MAX_ATTEMPTS=20
HUNT_PREFIXES=()
HUNT_CREATED_IPS=()
SUPPORTED_COUNTRIES=(india uk canada singapore)
CANONICAL_REGION=ap-south-1
CANONICAL_SNAPSHOT_PREFIX=india-exit-mumbai-lifecycle
TRANSFER_SNAPSHOT_PREFIX=region-relay-transfer
RESTORE_SNAPSHOT=

configure_country() {
  local requested=${1:-india} mode=${2:-user} mapped_region mapped_az mapped_instance mapped_snapshot mapped_static mapped_bundle
  case "$requested" in
    india|in)
      COUNTRY=india
      mapped_region=ap-south-1
      mapped_az=ap-south-1a
      mapped_instance=india-exit-mumbai
      mapped_snapshot=india-exit-mumbai-lifecycle
      mapped_static=india-exit-mumbai-hunt
      mapped_bundle=nano_3_1
      ;;
    uk|gb|united-kingdom)
      COUNTRY=uk
      mapped_region=eu-west-2
      mapped_az=eu-west-2a
      mapped_instance=stream-exit-uk
      mapped_snapshot=stream-exit-uk-lifecycle
      mapped_static=stream-exit-uk-hunt
      mapped_bundle=nano_3_0
      ;;
    canada|ca)
      COUNTRY=canada
      mapped_region=ca-central-1
      mapped_az=ca-central-1a
      mapped_instance=stream-exit-canada
      mapped_snapshot=stream-exit-canada-lifecycle
      mapped_static=stream-exit-canada-hunt
      mapped_bundle=nano_3_0
      ;;
    singapore|sg)
      COUNTRY=singapore
      mapped_region=ap-southeast-1
      mapped_az=ap-southeast-1a
      mapped_instance=stream-exit-singapore
      mapped_snapshot=stream-exit-singapore-lifecycle
      mapped_static=stream-exit-singapore-hunt
      mapped_bundle=nano_3_0
      ;;
    *) die "Unsupported country '$requested'. Choose india, uk, canada, or singapore." ;;
  esac
  REGION=$mapped_region
  AZ=$mapped_az
  INSTANCE_NAME=$mapped_instance
  SNAPSHOT_PREFIX=$mapped_snapshot
  STATIC_IP_PREFIX=$mapped_static
  BUNDLE_ID=${VPN_BUNDLE_ID:-$mapped_bundle}
  if [[ $mode == user && $COUNTRY == india && $COUNTRY_EXPLICIT == false ]]; then
    REGION=${VPN_AWS_REGION:-$REGION}
    AZ=${VPN_AWS_AZ:-$AZ}
    INSTANCE_NAME=${VPN_INSTANCE_NAME:-$INSTANCE_NAME}
    SNAPSHOT_PREFIX=${VPN_SNAPSHOT_PREFIX:-$SNAPSHOT_PREFIX}
    STATIC_IP_PREFIX=${VPN_STATIC_IP_PREFIX:-$STATIC_IP_PREFIX}
  fi
}

usage() {
  cat <<EOF
Usage: $(basename "$0") [--country COUNTRY] [--yes] [up|down|snapshot|rotate|hunt-static-ip|status|usage|schedule-down HOURS|cancel-down|help]

With no command, the script toggles the exit node:
  running/present -> down
  absent          -> up

Commands:
  up       Restore the newest lifecycle snapshot without a static IP.
  down     Without --country, delete all managed VMs/IPs; with it, only that country.
  snapshot Replace the saved lifecycle snapshot with the current VM state.
  rotate   Release any static IP and stop/start to obtain a new dynamic IPv4.
  hunt-static-ip --prefix PREFIX [--prefix PREFIX ...] [--max-attempts N]
           Allocate static IPv4 candidates without restarting the VM, attach
           the first prefix match, and release every rejected candidate.
  status   Without --country, show all countries; with it, show one country.
  usage    Show this month's selected-Region bandwidth and Lightsail charges.
  schedule-down HOURS
           Delete the VM automatically after HOURS (maximum 168 hours).
  cancel-down
           Cancel a pending automatic deletion.
  help     Show this help.

Options:
  --country COUNTRY
           india (default), uk, canada, or singapore.
  --yes    Skip confirmations for irreversible actions.
  --prefix PREFIX
           Accepted IPv4 text prefix for hunt-static-ip, for example 43.
  --max-attempts N
           Maximum static IPv4 candidates for hunt-static-ip (1-20; default 20).

Environment overrides:
  VPN_AWS_PROFILE, VPN_AWS_REGION, VPN_AWS_AZ, VPN_INSTANCE_NAME,
  VPN_BUNDLE_ID, VPN_SNAPSHOT_PREFIX, VPN_TAILSCALE_HOSTNAME
EOF
}

log() {
  printf '%s\n' "$*"
}

die() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

confirm() {
  local prompt=$1 answer
  $YES && return 0
  if [[ ! -t 0 ]]; then
    die "$prompt Re-run with --yes in a non-interactive terminal."
  fi
  read -r -p "$prompt [y/N] " answer
  [[ $answer == y || $answer == Y || $answer == yes || $answer == YES ]] || die 'Cancelled.'
}

aws_ls() {
  "$AWS_BIN" lightsail "$@" --profile "$PROFILE" --region "$REGION" --no-cli-pager
}

aws_ls_region() {
  local region=$1
  shift
  "$AWS_BIN" lightsail "$@" --profile "$PROFILE" --region "$region" --no-cli-pager
}

aws_ce() {
  "$AWS_BIN" ce "$@" --profile "$PROFILE" --region "$BILLING_REGION" --no-cli-pager
}

aws_scheduler() {
  "$AWS_BIN" scheduler "$@" --profile "$PROFILE" --region "$REGION" --no-cli-pager
}

aws_cf() {
  "$AWS_BIN" cloudformation "$@" --profile "$PROFILE" --region "$REGION" --no-cli-pager
}

scheduler_stack_output() {
  local key=$1
  aws_cf describe-stacks \
    --stack-name "$SCHEDULER_STACK" \
    --query "Stacks[0].Outputs[?OutputKey==\`$key\`].OutputValue|[0]" \
    --output text 2>/dev/null
}

scheduler_group_name() {
  scheduler_stack_output SchedulerGroupName
}

scheduler_role_arn() {
  scheduler_stack_output SchedulerExecutionRoleArn
}

schedule_exists() {
  local group=$1
  aws_scheduler get-schedule --group-name "$group" --name "$SCHEDULE_NAME" >/dev/null 2>&1
}

cancel_pending_schedule() {
  local group
  group=$(scheduler_group_name 2>/dev/null || true)
  [[ -n $group && $group != None ]] || return 1
  schedule_exists "$group" || return 1
  aws_scheduler delete-schedule --group-name "$group" --name "$SCHEDULE_NAME" >/dev/null
}

show_pending_schedule() {
  local group expression human
  group=$(scheduler_group_name 2>/dev/null || true)
  if [[ -z $group || $group == None ]] || ! schedule_exists "$group"; then
    log 'Automatic deletion: none'
    return 0
  fi
  expression=$(aws_scheduler get-schedule --group-name "$group" --name "$SCHEDULE_NAME" \
    --query ScheduleExpression --output text)
  human=${expression#at(}
  human=${human%)}
  log "Automatic deletion: $human UTC"
}

authenticate() {
  local identity account arn
  if ! identity=$("$AWS_BIN" sts get-caller-identity --profile "$PROFILE" --region "$REGION" --output json --no-cli-pager 2>/dev/null); then
    confirm "AWS session for profile '$PROFILE' is missing or expired. Open AWS browser login?"
    "$AWS_BIN" login --profile "$PROFILE"
    identity=$("$AWS_BIN" sts get-caller-identity --profile "$PROFILE" --region "$REGION" --output json --no-cli-pager) || \
      die "AWS login did not produce usable credentials for '$PROFILE'."
  fi

  account=$(printf '%s' "$identity" | python3 -c 'import json,sys; print(json.load(sys.stdin)["Account"])')
  arn=$(printf '%s' "$identity" | python3 -c 'import json,sys; print(json.load(sys.stdin)["Arn"])')
  if [[ -n ${VPN_EXPECTED_ACCOUNT:-} && $account != "$VPN_EXPECTED_ACCOUNT" ]]; then
    die "Authenticated to AWS account $account, expected $VPN_EXPECTED_ACCOUNT."
  fi
  log "AWS: account $account via $arn"
}

instance_exists() {
  aws_ls get-instance --instance-name "$INSTANCE_NAME" --query 'instance.name' --output text >/dev/null 2>&1
}

instance_state() {
  aws_ls get-instance-state --instance-name "$INSTANCE_NAME" --query 'state.name' --output text
}

instance_ip() {
  aws_ls get-instance --instance-name "$INSTANCE_NAME" --query 'instance.publicIpAddress' --output text
}

latest_snapshot() {
  local result
  result=$(aws_ls get-instance-snapshots \
    --query "instanceSnapshots[?starts_with(name, \`$SNAPSHOT_PREFIX-\`) && state==\`available\`]|sort_by(@,&createdAt)[-1].name" \
    --output text)
  [[ $result != None && -n $result ]] || return 1
  printf '%s\n' "$result"
}

canonical_snapshot() {
  local result
  result=$(aws_ls_region "$CANONICAL_REGION" get-instance-snapshots \
    --query "instanceSnapshots[?starts_with(name, \`$CANONICAL_SNAPSHOT_PREFIX-\`) && state==\`available\`]|sort_by(@,&createdAt)[-1].name" \
    --output text)
  [[ $result != None && -n $result ]] || return 1
  printf '%s\n' "$result"
}

validate_destination() {
  local zone bundle
  zone=$(aws_ls get-regions --include-availability-zones \
    --query "regions[?name==\`$REGION\`].availabilityZones[0].zoneName|[0]" --output text 2>/dev/null || true)
  [[ -n $zone && $zone != None ]] || die "Lightsail returned no availability zone for $COUNTRY ($REGION). The current VM was not changed."
  bundle=$(aws_ls get-bundles --query "bundles[?bundleId==\`$BUNDLE_ID\`]|[0].bundleId" --output text 2>/dev/null || true)
  [[ $bundle == "$BUNDLE_ID" ]] || die "Bundle '$BUNDLE_ID' is unavailable for $COUNTRY ($REGION). The current VM was not changed."
  AZ=$zone
}

delete_temporary_snapshots() {
  local snapshots snapshot
  [[ $COUNTRY != india ]] || return 0
  snapshots=$(aws_ls get-instance-snapshots \
    --query "instanceSnapshots[?starts_with(name, \`$TRANSFER_SNAPSHOT_PREFIX-$COUNTRY-\`)].name" --output text 2>/dev/null || true)
  [[ -n $snapshots && $snapshots != None ]] || return 0
  for snapshot in $snapshots; do
    log "Deleting temporary $COUNTRY restore snapshot '$snapshot'..."
    aws_ls delete-instance-snapshot --instance-snapshot-name "$snapshot" >/dev/null
  done
}

prepare_restore_snapshot() {
  local source target
  source=$(canonical_snapshot || true)
  [[ -n $source ]] || die "No available canonical snapshot beginning '$CANONICAL_SNAPSHOT_PREFIX-' exists in $CANONICAL_REGION."
  if [[ $COUNTRY == india ]]; then
    RESTORE_SNAPSHOT=$source
    return 0
  fi

  target="$TRANSFER_SNAPSHOT_PREFIX-$COUNTRY-$RUN_ID"
  delete_temporary_snapshots
  log "Copying canonical snapshot '$source' to $COUNTRY ($REGION)..."
  aws_ls copy-snapshot \
    --source-snapshot-name "$source" \
    --source-region "$CANONICAL_REGION" \
    --target-snapshot-name "$target" >/dev/null || \
    die "Snapshot copy to $COUNTRY failed. The existing VM was not changed."
  wait_for_snapshot "$target"
  RESTORE_SNAPSHOT=$target
}

wait_for_snapshot() {
  local snapshot=$1 state i
  for ((i=1; i<=MAX_POLLS; i++)); do
    state=$(aws_ls get-instance-snapshot --instance-snapshot-name "$snapshot" --query 'instanceSnapshot.state' --output text 2>/dev/null || true)
    case "$state" in
      available) return 0 ;;
      error) die "Snapshot '$snapshot' entered the error state." ;;
    esac
    sleep "$POLL_SECONDS"
  done
  die "Timed out waiting for snapshot '$snapshot' to become available. The VM was not deleted."
}

wait_for_snapshot_in_region() {
  local region=$1 snapshot=$2 state i
  for ((i=1; i<=MAX_POLLS; i++)); do
    state=$(aws_ls_region "$region" get-instance-snapshot --instance-snapshot-name "$snapshot" --query 'instanceSnapshot.state' --output text 2>/dev/null || true)
    case "$state" in
      available) return 0 ;;
      error) die "Snapshot '$snapshot' entered the error state in $region." ;;
    esac
    sleep "$POLL_SECONDS"
  done
  die "Timed out waiting for snapshot '$snapshot' to become available in $region."
}

wait_for_instance_state() {
  local wanted=$1 current i
  for ((i=1; i<=MAX_POLLS; i++)); do
    current=$(instance_state 2>/dev/null || true)
    [[ $current == "$wanted" ]] && return 0
    sleep "$POLL_SECONDS"
  done
  die "Timed out waiting for '$INSTANCE_NAME' to become $wanted."
}

wait_for_instance_absent() {
  local i
  for ((i=1; i<=MAX_POLLS; i++)); do
    instance_exists || return 0
    sleep "$POLL_SECONDS"
  done
  die "Timed out waiting for '$INSTANCE_NAME' to be deleted."
}

cleanup_country() {
  local country=$1
  (
    configure_country "$country" internal
    if cancel_pending_schedule; then
      log "Cancelled pending automatic deletion in $COUNTRY."
    fi
    release_managed_static_ips
    if instance_exists; then
      log "Deleting $COUNTRY instance '$INSTANCE_NAME'..."
      aws_ls delete-instance --instance-name "$INSTANCE_NAME" >/dev/null
      wait_for_instance_absent
    fi
    delete_temporary_snapshots
  )
}

cleanup_other_countries() {
  local destination=$1 country
  for country in "${SUPPORTED_COUNTRIES[@]}"; do
    [[ $country == "$destination" ]] && continue
    cleanup_country "$country" || die "Cleanup failed in $country. Destination provisioning was cancelled to avoid duplicate VM charges."
  done
}

attached_static_ips() {
  local result
  result=$(aws_ls get-static-ips --query "staticIps[?attachedTo==\`$INSTANCE_NAME\`].name" --output text)
  if [[ $result != None && -n $result ]]; then
    printf '%s\n' "$result"
  fi
  return 0
}

release_attached_static_ips() {
  local ips ip
  ips=$(attached_static_ips)
  [[ -n $ips ]] || return 0
  for ip in $ips; do
    log "Detaching and permanently releasing static IP '$ip'..."
    aws_ls detach-static-ip --static-ip-name "$ip" >/dev/null
    aws_ls release-static-ip --static-ip-name "$ip" >/dev/null
  done
}

managed_static_ips() {
  local result
  result=$(aws_ls get-static-ips \
    --query "staticIps[?attachedTo==\`$INSTANCE_NAME\` || starts_with(name, \`$STATIC_IP_PREFIX-\`) || starts_with(name, \`$INSTANCE_NAME-ip\`)].[name,attachedTo]" \
    --output text)
  [[ $result != None && -n $result ]] && printf '%s\n' "$result"
  return 0
}

release_static_ip_resource() {
  local name=$1 attached_to=${2:-}
  if [[ $attached_to == "$INSTANCE_NAME" ]]; then
    log "Detaching automation static IP '$name'..."
    aws_ls detach-static-ip --static-ip-name "$name" >/dev/null
  fi
  log "Permanently releasing automation static IP '$name'..."
  aws_ls release-static-ip --static-ip-name "$name" >/dev/null
}

release_managed_static_ips() {
  local exclude=${1:-} resources name attached_to
  resources=$(managed_static_ips)
  [[ -n $resources ]] || return 0
  while read -r name attached_to; do
    [[ -n ${name:-} && $name != None ]] || continue
    [[ $name != "$exclude" ]] || continue
    release_static_ip_resource "$name" "${attached_to:-}"
  done <<<"$resources"
}

cleanup_hunt_created_ips() {
  local name attached_to
  for name in "${HUNT_CREATED_IPS[@]}"; do
    attached_to=$(aws_ls get-static-ip --static-ip-name "$name" --query 'staticIp.attachedTo' --output text 2>/dev/null || true)
    if [[ $attached_to == "$INSTANCE_NAME" ]]; then
      aws_ls detach-static-ip --static-ip-name "$name" >/dev/null 2>&1 || true
    fi
    aws_ls release-static-ip --static-ip-name "$name" >/dev/null 2>&1 || true
  done
  HUNT_CREATED_IPS=()
}

ip_matches_hunt_prefix() {
  local ip=$1 prefix
  for prefix in "${HUNT_PREFIXES[@]}"; do
    if [[ ${ip:0:${#prefix}} == "$prefix" ]]; then
      return 0
    fi
  done
  return 1
}

close_all_public_ports() {
  local ports from_port to_port protocol remaining
  ports=$(aws_ls get-instance-port-states --instance-name "$INSTANCE_NAME" \
    --query 'portStates[?state==`open`].[fromPort,toPort,protocol]' --output text)

  while read -r from_port to_port protocol; do
    [[ -n ${from_port:-} && $from_port != None ]] || continue
    aws_ls close-instance-public-ports \
      --instance-name "$INSTANCE_NAME" \
      --port-info "{\"fromPort\":$from_port,\"toPort\":$to_port,\"protocol\":\"$protocol\"}" >/dev/null
  done <<<"$ports"

  remaining=$(aws_ls get-instance-port-states --instance-name "$INSTANCE_NAME" \
    --query 'length(portStates[?state==`open`])' --output text)
  [[ $remaining == 0 ]] || die "Firewall verification found $remaining open public rule(s)."
  log 'Firewall: no public inbound ports are open.'
}

prune_old_snapshots() {
  local keep=$1 snapshots snapshot
  snapshots=$(aws_ls get-instance-snapshots \
    --query "instanceSnapshots[?starts_with(name, \`$SNAPSHOT_PREFIX-\`)].name" --output text)
  [[ $snapshots != None ]] || return 0
  for snapshot in $snapshots; do
    if [[ $snapshot != "$keep" ]]; then
      log "Deleting superseded lifecycle snapshot '$snapshot'..."
      aws_ls delete-instance-snapshot --instance-snapshot-name "$snapshot" >/dev/null
    fi
  done
}

prune_old_canonical_snapshots() {
  local keep=$1 snapshots snapshot
  snapshots=$(aws_ls_region "$CANONICAL_REGION" get-instance-snapshots \
    --query "instanceSnapshots[?starts_with(name, \`$CANONICAL_SNAPSHOT_PREFIX-\`)].name" --output text)
  [[ $snapshots != None ]] || return 0
  for snapshot in $snapshots; do
    if [[ $snapshot != "$keep" ]]; then
      log "Deleting superseded canonical snapshot '$snapshot'..."
      aws_ls_region "$CANONICAL_REGION" delete-instance-snapshot --instance-snapshot-name "$snapshot" >/dev/null
    fi
  done
}

optional_tailscale_check() {
  local ts_output
  if command -v tailscale >/dev/null 2>&1; then
    ts_output=$(tailscale status 2>/dev/null || true)
    if printf '%s\n' "$ts_output" | grep -F "$TAILSCALE_HOSTNAME" >/dev/null; then
      log "Tailscale: '$TAILSCALE_HOSTNAME' is visible from this computer's tailnet."
    else
      log "Tailscale: could not confirm '$TAILSCALE_HOSTNAME' locally. Check https://login.tailscale.com/admin/machines"
    fi
  else
    log 'Tailscale verification: https://login.tailscale.com/admin/machines'
  fi
}

do_down() {
  local snapshot
  snapshot=$(canonical_snapshot || true)
  [[ -n $snapshot ]] || die "No available canonical snapshot beginning '$CANONICAL_SNAPSHOT_PREFIX-' exists in $CANONICAL_REGION. The VM was not changed."
  if ! instance_exists; then
    if cancel_pending_schedule; then
      log 'Cancelled the stale automatic deletion timer.'
    fi
    release_managed_static_ips
    log "Exit node is already down. Ready snapshot: $snapshot"
    return 0
  fi

  confirm "This will delete '$INSTANCE_NAME' using existing snapshot '$snapshot', then permanently release its attached static IP. Continue?"

  if cancel_pending_schedule; then
    log 'Cancelled the pending automatic deletion timer.'
  fi
  release_managed_static_ips
  log "Deleting Lightsail instance '$INSTANCE_NAME'..."
  aws_ls delete-instance --instance-name "$INSTANCE_NAME" >/dev/null
  wait_for_instance_absent

  log "Exit node is down. Ready snapshot: $snapshot"
  log 'Ongoing AWS cost is limited to snapshot storage until you run up again.'
}

do_global_down() {
  local snapshot country
  snapshot=$(canonical_snapshot || true)
  [[ -n $snapshot ]] || die "No available canonical snapshot beginning '$CANONICAL_SNAPSHOT_PREFIX-' exists in $CANONICAL_REGION. Nothing was deleted."
  confirm "This will delete every VM, timer, temporary snapshot, and automation static IP managed by this script in India, UK, Canada, and Singapore. Continue?"
  for country in "${SUPPORTED_COUNTRIES[@]}"; do
    cleanup_country "$country" || die "Cleanup failed in $country. Check status before retrying."
  done
  log 'Exit node is down in every managed country; all managed VMs and automation static IPs were removed.'
  log "Canonical recovery snapshot retained in India: $snapshot"
  log 'Ongoing AWS cost is limited to canonical snapshot storage.'
}

do_hunt_static_ip() {
  local attempt=0 allocated_count available batch index name ip selected_name selected_ip
  local existing_name existing_ip resources candidate_names candidate_ips candidate_name candidate_ip

  instance_exists || die "'$INSTANCE_NAME' does not exist. Run up first."
  [[ $(instance_state) == running ]] || die "'$INSTANCE_NAME' must be running before hunting for a static IP."
  ((${#HUNT_PREFIXES[@]})) || die 'hunt-static-ip requires at least one --prefix, for example: --prefix 43.'
  [[ $HUNT_MAX_ATTEMPTS =~ ^[0-9]+$ ]] && ((HUNT_MAX_ATTEMPTS >= 1 && HUNT_MAX_ATTEMPTS <= 20)) || \
    die '--max-attempts must be an integer from 1 through 20.'
  for candidate_ip in "${HUNT_PREFIXES[@]}"; do
    [[ $candidate_ip =~ ^[0-9.]+$ && $candidate_ip == *.* ]] || \
      die "Invalid IPv4 prefix '$candidate_ip'. Use a literal prefix such as 43.204."
  done

  resources=$(attached_static_ips)
  if [[ -n $resources ]]; then
    for existing_name in $resources; do
      existing_ip=$(aws_ls get-static-ip --static-ip-name "$existing_name" --query 'staticIp.ipAddress' --output text)
      if ip_matches_hunt_prefix "$existing_ip"; then
        if cancel_pending_schedule; then
          log 'Cancelled the pending automatic deletion timer so it cannot orphan the static IP.'
        fi
        release_managed_static_ips "$existing_name"
        log "An attached static IPv4 already matches: $existing_ip ($existing_name)"
        return 0
      fi
    done
  fi

  confirm "This will replace any static IP attached to '$INSTANCE_NAME', allocate up to $HUNT_MAX_ATTEMPTS candidates, and permanently release every rejected address. Continue?"
  release_managed_static_ips

  trap cleanup_hunt_created_ips EXIT
  trap 'cleanup_hunt_created_ips; exit 130' INT TERM
  while ((attempt < HUNT_MAX_ATTEMPTS)); do
    allocated_count=$(aws_ls get-static-ips --query 'length(staticIps)' --output text)
    available=$((5 - allocated_count))
    ((available > 0)) || die 'All five Lightsail static IP slots in this Region are occupied by unrelated resources.'
    batch=$available
    ((batch > HUNT_MAX_ATTEMPTS - attempt)) && batch=$((HUNT_MAX_ATTEMPTS - attempt))

    candidate_names=()
    candidate_ips=()
    for ((index=1; index<=batch; index++)); do
      attempt=$((attempt + 1))
      name="$STATIC_IP_PREFIX-$RUN_ID-$attempt"
      log "Allocating candidate $attempt/$HUNT_MAX_ATTEMPTS..."
      aws_ls allocate-static-ip --static-ip-name "$name" >/dev/null
      HUNT_CREATED_IPS+=("$name")
      aws_ls tag-resource --resource-name "$name" \
        --tags key=ManagedBy,value=region-relay key=Purpose,value=static-ip-hunt >/dev/null
      ip=$(aws_ls get-static-ip --static-ip-name "$name" --query 'staticIp.ipAddress' --output text)
      candidate_names+=("$name")
      candidate_ips+=("$ip")
      log "Candidate $attempt: $ip"
    done

    selected_name=
    selected_ip=
    for ((index=0; index<${#candidate_names[@]}; index++)); do
      candidate_name=${candidate_names[$index]}
      candidate_ip=${candidate_ips[$index]}
      if [[ -z $selected_name ]] && ip_matches_hunt_prefix "$candidate_ip"; then
        selected_name=$candidate_name
        selected_ip=$candidate_ip
      else
        release_static_ip_resource "$candidate_name"
      fi
    done

    if [[ -n $selected_name ]]; then
      if cancel_pending_schedule; then
        log 'Cancelled the pending automatic deletion timer so it cannot orphan the selected static IP.'
      fi
      aws_ls attach-static-ip --static-ip-name "$selected_name" --instance-name "$INSTANCE_NAME" >/dev/null
      HUNT_CREATED_IPS=()
      trap - EXIT INT TERM
      close_all_public_ports
      log "Selected static IPv4: $selected_ip"
      log "Attached resource: $selected_name"
      log "The down command will detach and permanently release this static IP."
      optional_tailscale_check
      return 0
    fi

    HUNT_CREATED_IPS=()
    ((attempt < HUNT_MAX_ATTEMPTS)) && sleep "$HUNT_DELAY_SECONDS"
  done

  trap - EXIT INT TERM
  die "No static IPv4 matched prefix(es): ${HUNT_PREFIXES[*]}. All candidates were released."
}

do_snapshot() {
  local snapshot canonical timestamp
  instance_exists || die "'$INSTANCE_NAME' does not exist. Run up before refreshing its snapshot."
  confirm "This will replace the saved lifecycle snapshot with the current state of '$INSTANCE_NAME'. Continue?"

  timestamp=$(date -u '+%Y%m%dT%H%M%SZ')
  snapshot="$SNAPSHOT_PREFIX-$timestamp"
  log "Creating lifecycle snapshot '$snapshot'..."
  aws_ls create-instance-snapshot \
    --instance-name "$INSTANCE_NAME" \
    --instance-snapshot-name "$snapshot" \
    --tags key=ManagedBy,value=region-relay key=Purpose,value=tailscale-exit-node >/dev/null
  wait_for_snapshot "$snapshot"
  log "Snapshot '$snapshot' is available."
  if [[ $COUNTRY == india ]]; then
    prune_old_snapshots "$snapshot"
    log "Ready canonical snapshot refreshed: $snapshot"
    return 0
  fi

  canonical="$CANONICAL_SNAPSHOT_PREFIX-$timestamp"
  log "Promoting '$snapshot' to canonical snapshot '$canonical' in India..."
  if ! aws_ls_region "$CANONICAL_REGION" copy-snapshot \
    --source-snapshot-name "$snapshot" \
    --source-region "$REGION" \
    --target-snapshot-name "$canonical" >/dev/null; then
    die "Canonical snapshot promotion failed. Local snapshot '$snapshot' was retained in $REGION."
  fi
  wait_for_snapshot_in_region "$CANONICAL_REGION" "$canonical"
  prune_old_canonical_snapshots "$canonical"
  aws_ls delete-instance-snapshot --instance-snapshot-name "$snapshot" >/dev/null
  log "Ready canonical snapshot refreshed in India: $canonical"
}

do_up() {
  local snapshot ip destination=$COUNTRY
  validate_destination
  if instance_exists; then
    cleanup_other_countries "$destination"
    log "Exit node is already present: state=$(instance_state), public-ip=$(instance_ip)"
    close_all_public_ports
    optional_tailscale_check
    return 0
  fi

  prepare_restore_snapshot
  snapshot=$RESTORE_SNAPSHOT
  cleanup_other_countries "$destination"

  log "Restoring '$INSTANCE_NAME' from '$snapshot' using bundle '$BUNDLE_ID'..."
  if ! aws_ls create-instances-from-snapshot \
    --instance-names "$INSTANCE_NAME" \
    --availability-zone "$AZ" \
    --instance-snapshot-name "$snapshot" \
    --bundle-id "$BUNDLE_ID" \
    --tags key=ManagedBy,value=region-relay key=Purpose,value=tailscale-exit-node >/dev/null; then
    die "Failed to create the $COUNTRY instance. The canonical snapshot remains safe. Recover with: $(basename "$0") --country india up"
  fi
  wait_for_instance_state running
  close_all_public_ports
  ip=$(instance_ip)
  delete_temporary_snapshots

  log "Exit node is up in $COUNTRY ($REGION). Public IPv4: $ip"
  log 'No static IP was allocated; Tailscale can follow endpoint changes automatically.'
  optional_tailscale_check
}

do_rotate() {
  local old_ip new_ip attempt
  instance_exists || die "'$INSTANCE_NAME' does not exist. Run up first."
  confirm 'This permanently releases any attached static IP and changes the VM public IPv4. Continue?'

  old_ip=$(instance_ip)
  release_attached_static_ips

  for ((attempt=1; attempt<=ROTATE_ATTEMPTS; attempt++)); do
    log "Rotating public IPv4 (attempt $attempt/$ROTATE_ATTEMPTS)..."
    aws_ls stop-instance --instance-name "$INSTANCE_NAME" >/dev/null
    wait_for_instance_state stopped
    aws_ls start-instance --instance-name "$INSTANCE_NAME" >/dev/null
    wait_for_instance_state running
    new_ip=$(instance_ip)
    [[ $new_ip != "$old_ip" ]] && break
  done

  [[ $new_ip != "$old_ip" ]] || die "AWS returned the same public IPv4 after $ROTATE_ATTEMPTS attempts."
  close_all_public_ports
  log "Public IPv4 rotated: $old_ip -> $new_ip"
  optional_tailscale_check
}

do_status() {
  local snapshot state ip static_ips
  log "Country: $COUNTRY"
  snapshot=$(canonical_snapshot || true)
  if instance_exists; then
    state=$(instance_state)
    ip=$(instance_ip)
    static_ips=$(attached_static_ips)
    log "Instance: $INSTANCE_NAME ($state)"
    log "Region/AZ: $REGION / $AZ"
    log "Public IPv4: $ip"
    if [[ -n $static_ips ]]; then
      log "Attached static IP resource(s): $static_ips"
    else
      log 'Attached static IP resources: none'
    fi
    optional_tailscale_check
  else
    log "Instance: $INSTANCE_NAME (absent)"
  fi
  log "Canonical ready snapshot: ${snapshot:-none}"
  show_pending_schedule
}

do_global_status() {
  local country
  for country in "${SUPPORTED_COUNTRIES[@]}"; do
    (
      configure_country "$country" internal
      do_status
    )
  done
}

do_schedule_down() {
  local hours=$1 snapshot static_ips group role_arn timing expression utc_human berlin_human target operation

  instance_exists || die "'$INSTANCE_NAME' does not exist. Run up first."
  snapshot=$(canonical_snapshot || true)
  [[ -n $snapshot ]] || die 'No ready canonical lifecycle snapshot exists in India. Run the snapshot command first.'
  static_ips=$(attached_static_ips)
  [[ -z $static_ips ]] || die "A static IP is attached ($static_ips). Release it first so automatic deletion cannot leave a billable orphan."

  timing=$(python3 - "$hours" "$NOW_UTC" <<'PY'
import math
import sys
from datetime import datetime, timedelta, timezone
from zoneinfo import ZoneInfo

try:
    hours = float(sys.argv[1])
except ValueError:
    raise SystemExit("HOURS must be a number greater than 0 and no more than 168.")
if not math.isfinite(hours) or hours <= 0 or hours > 168:
    raise SystemExit("HOURS must be a number greater than 0 and no more than 168.")
now_text = sys.argv[2]
if now_text:
    now = datetime.fromisoformat(now_text.replace("Z", "+00:00"))
else:
    now = datetime.now(timezone.utc)
when = (now.astimezone(timezone.utc) + timedelta(hours=hours)).replace(microsecond=0)
print(when.strftime("at(%Y-%m-%dT%H:%M:%S)"))
print(when.strftime("%Y-%m-%d %H:%M:%S UTC"))
print(when.astimezone(ZoneInfo("Europe/Berlin")).strftime("%Y-%m-%d %H:%M:%S %Z"))
PY
  ) || die 'HOURS must be a number greater than 0 and no more than 168.'
  expression=$(printf '%s\n' "$timing" | sed -n '1p')
  utc_human=$(printf '%s\n' "$timing" | sed -n '2p')
  berlin_human=$(printf '%s\n' "$timing" | sed -n '3p')

  group=$(scheduler_group_name 2>/dev/null || true)
  role_arn=$(scheduler_role_arn 2>/dev/null || true)
  [[ -n $group && $group != None && -n $role_arn && $role_arn != None ]] || \
    die "Scheduler infrastructure is missing in $REGION. Deploy it with: aws cloudformation deploy --profile $PROFILE --region $REGION --stack-name $SCHEDULER_STACK --template-file infra/scheduler.yaml --capabilities CAPABILITY_IAM"

  target=$(python3 - "$role_arn" "$INSTANCE_NAME" <<'PY'
import json
import sys

print(json.dumps({
    "Arn": "arn:aws:scheduler:::aws-sdk:lightsail:deleteInstance",
    "RoleArn": sys.argv[1],
    "Input": json.dumps({"InstanceName": sys.argv[2]}),
    "RetryPolicy": {"MaximumEventAgeInSeconds": 3600, "MaximumRetryAttempts": 3},
}))
PY
  )

  if schedule_exists "$group"; then
    operation=update-schedule
  else
    operation=create-schedule
  fi
  aws_scheduler "$operation" \
    --group-name "$group" \
    --name "$SCHEDULE_NAME" \
    --description "Delete tagged Lightsail exit node $INSTANCE_NAME" \
    --schedule-expression "$expression" \
    --schedule-expression-timezone UTC \
    --flexible-time-window '{"Mode":"OFF"}' \
    --target "$target" \
    --action-after-completion DELETE \
    --state ENABLED >/dev/null

  log "Automatic deletion scheduled for $utc_human ($berlin_human)."
  log 'The ready lifecycle snapshot will be kept.'
  log "Ready snapshot: $snapshot"
  log 'Use cancel-down to cancel or schedule-down HOURS to replace this timer.'
}

do_cancel_down() {
  if cancel_pending_schedule; then
    log 'Automatic deletion cancelled.'
  else
    log 'No automatic deletion was scheduled.'
  fi
}

do_usage() {
  local start_date end_date billing_data bundle_data allowance_gb monthly_price state ip

  if instance_exists; then
    state=$(instance_state)
    ip=$(instance_ip)
    log "Instance: $INSTANCE_NAME ($state), public IPv4: $ip"
  else
    log "Instance: $INSTANCE_NAME (absent)"
  fi

  bundle_data=$(aws_ls get-bundles \
    --query "bundles[?bundleId==\`$BUNDLE_ID\`]|[0].[transferPerMonthInGb,price]" \
    --output text 2>/dev/null || true)
  read -r allowance_gb monthly_price <<<"$bundle_data"
  if [[ -z ${allowance_gb:-} || $allowance_gb == None || -z ${monthly_price:-} || $monthly_price == None ]]; then
    log "Usage unavailable: AWS did not return pricing for bundle '$BUNDLE_ID'."
    return 0
  fi
  printf 'Plan: %s, $%.2f/month maximum, billed hourly while the VM exists.\n' \
    "$BUNDLE_ID" "$monthly_price"

  read -r start_date end_date < <(python3 -c 'from datetime import date,timedelta; today=date.today(); print(today.replace(day=1), today+timedelta(days=1))')
  if ! billing_data=$(aws_ce get-cost-and-usage \
    --time-period "Start=$start_date,End=$end_date" \
    --granularity MONTHLY \
    --metrics UsageQuantity UnblendedCost \
    --filter "{\"And\":[{\"Dimensions\":{\"Key\":\"SERVICE\",\"Values\":[\"Amazon Lightsail\"]}},{\"Dimensions\":{\"Key\":\"REGION\",\"Values\":[\"$REGION\"]}}]}" \
    --group-by Type=DIMENSION,Key=USAGE_TYPE \
    --output json 2>/dev/null); then
    log 'Usage unavailable: AWS Cost Explorer could not return the current month. The VM was not changed.'
    return 0
  fi

  printf '%s' "$billing_data" | python3 -c '
import json
import sys

allowance = float(sys.argv[1])
data = json.load(sys.stdin)
incoming = outgoing = overage_gb = 0.0
total_cost = vm_cost = snapshot_cost = static_ip_cost = overage_cost = other_cost = 0.0

for period in data.get("ResultsByTime", []):
    for group in period.get("Groups", []):
        keys = group.get("Keys", [])
        if not keys:
            continue
        key = keys[0]
        metrics = group.get("Metrics", {})
        usage = float(metrics.get("UsageQuantity", {}).get("Amount", 0))
        cost = float(metrics.get("UnblendedCost", {}).get("Amount", 0))
        total_cost += cost
        if key.endswith("TotalDataXfer-In-Bytes"):
            incoming += usage
        elif key.endswith("TotalDataXfer-Out-Bytes"):
            outgoing += usage
        elif key.endswith("DataXfer-Out-Overage-Bytes"):
            overage_gb += usage
            overage_cost += cost
        elif "BundleUsage:" in key:
            vm_cost += cost
        elif key.endswith("SnapshotUsage"):
            snapshot_cost += cost
        elif key.endswith("UnusedStaticIP"):
            static_ip_cost += cost
        else:
            other_cost += cost

used = incoming + outgoing
remaining = max(allowance - used, 0.0)
percent = used / allowance * 100 if allowance else 0.0
print(f"Bandwidth this month: {used:.2f} GB of {allowance:.2f} GB used ({percent:.2f}%).")
print(f"Incoming: {incoming:.2f} GB; outgoing: {outgoing:.2f} GB; remaining: {remaining:.2f} GB.")
if overage_gb > 0 or overage_cost > 0:
    print(f"Transfer overage: {overage_gb:.2f} GB; estimated charge: ${overage_cost:.2f} USD.")
else:
    print("Transfer overage: none.")
print(f"Estimated Lightsail charges this month: ${total_cost:.2f} USD.")
breakdown = (
    f"VM: ${vm_cost:.2f}; snapshots: ${snapshot_cost:.2f}; "
    f"unused static IPs: ${static_ip_cost:.2f}; transfer overage: ${overage_cost:.2f}."
)
print(breakdown)
if abs(other_cost) >= 0.005:
    print(f"Other Lightsail charges: ${other_cost:.2f} USD.")
print("AWS billing data is estimated and can lag by several hours.")
' "$allowance_gb"
}

while (($#)); do
  case "$1" in
    --yes|-y) YES=true ;;
    --country)
      shift
      (($#)) || die '--country requires india, uk, canada, or singapore.'
      COUNTRY_EXPLICIT=true
      COUNTRY=$1
      ;;
    --prefix)
      shift
      (($#)) || die '--prefix requires a value, for example: --prefix 43.'
      HUNT_PREFIXES+=("$1")
      ;;
    --max-attempts)
      shift
      (($#)) || die '--max-attempts requires a value from 1 through 20.'
      HUNT_MAX_ATTEMPTS=$1
      ;;
    schedule-down)
      [[ -z $COMMAND ]] || die 'Specify only one command.'
      COMMAND=$1
      shift
      (($#)) || die 'schedule-down requires HOURS, for example: schedule-down 2'
      COMMAND_ARG=$1
      ;;
    up|down|snapshot|rotate|hunt-static-ip|status|usage|cancel-down|help) [[ -z $COMMAND ]] || die 'Specify only one command.'; COMMAND=$1 ;;
    -h|--help) COMMAND=help ;;
    *) die "Unknown argument: $1" ;;
  esac
  shift
done

configure_country "${COUNTRY:-${VPN_COUNTRY:-india}}"

if [[ $COMMAND == help ]]; then
  usage
  exit 0
fi

authenticate

if [[ -z $COMMAND ]]; then
  COMMAND_IMPLICIT=true
  if instance_exists; then
    COMMAND=down
  else
    COMMAND=up
  fi
fi

case "$COMMAND" in
  up) do_up ;;
  down)
    if [[ $COUNTRY_EXPLICIT == false && $COMMAND_IMPLICIT == false ]]; then
      do_global_down
    else
      do_down
    fi
    ;;
  snapshot) do_snapshot ;;
  rotate) do_rotate ;;
  hunt-static-ip) do_hunt_static_ip ;;
  status)
    if [[ $COUNTRY_EXPLICIT == false ]]; then
      do_global_status
    else
      do_status
    fi
    ;;
  usage) do_usage ;;
  schedule-down) do_schedule_down "$COMMAND_ARG" ;;
  cancel-down) do_cancel_down ;;
  *) die "Unsupported command: $COMMAND" ;;
esac
