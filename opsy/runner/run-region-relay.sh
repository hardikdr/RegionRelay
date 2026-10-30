#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
REGION_RELAY=$ROOT/scripts/region-relay.sh

die() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 2
}

[[ ${VPN_EXPECTED_ACCOUNT:-} =~ ^[0-9]{12}$ ]] || \
  die 'VPN_EXPECTED_ACCOUNT must be the expected 12-digit AWS account ID.'

ACTION=${OPSY_ACTION:-}
COUNTRY=${OPSY_COUNTRY:-}

case "$COUNTRY" in
  india|uk|canada|singapore) ;;
  *) die 'OPSY_COUNTRY must be india, uk, canada, or singapore.' ;;
esac

export VPN_AWS_PROFILE=

case "$ACTION" in
  up|rotate)
    exec "$REGION_RELAY" --country "$COUNTRY" --yes "$ACTION"
    ;;
  down)
    exec "$REGION_RELAY" --yes down
    ;;
  hunt)
    ATTEMPTS=${OPSY_HUNT_ATTEMPTS:-20}
    [[ $ATTEMPTS =~ ^[0-9]+$ ]] && ((ATTEMPTS >= 1 && ATTEMPTS <= 400)) || \
      die 'OPSY_HUNT_ATTEMPTS must be an integer from 1 through 400.'
    [[ -n ${OPSY_TARGET_PREFIXES:-} ]] || \
      die 'OPSY_TARGET_PREFIXES must contain at least one configured IPv4 prefix.'

    IFS=',' read -r -a prefixes <<<"$OPSY_TARGET_PREFIXES"
    command=("$REGION_RELAY" --country "$COUNTRY" --yes hunt-static-ip)
    for prefix in "${prefixes[@]}"; do
      [[ $prefix =~ ^[0-9.]+$ && $prefix == *.* && $prefix != .* && $prefix != *..* ]] || \
        die "Invalid configured IPv4 prefix: $prefix"
      command+=(--prefix "$prefix")
    done
    command+=(--max-attempts "$ATTEMPTS")
    exec "${command[@]}"
    ;;
  *)
    die 'OPSY_ACTION must be up, down, rotate, or hunt.'
    ;;
esac
