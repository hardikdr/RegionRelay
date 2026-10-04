# Operations

## Safety model

- Mumbai (`ap-south-1`) stores the persistent canonical snapshot.
- Non-India launches use a temporary regional snapshot copy.
- The destination Region and bundle are validated before another VM is
  removed.
- A copied snapshot must become available before the source VM is deleted.
- At most one managed VM should remain after a successful `up`.
- Public inbound Lightsail firewall rules are closed after creation.
- Temporary copies and rejected automation static IPs are removed.
- Resources are matched by the project's exact names and prefixes; unrelated
  Lightsail resources are not intentional cleanup targets.

## Configuration

Load the local environment before running commands:

```bash
set -a
source .env
set +a
```

Important variables:

| Variable | Purpose |
|---|---|
| `VPN_AWS_PROFILE` | AWS CLI profile; defaults to `region-relay` |
| `VPN_EXPECTED_ACCOUNT` | Refuse mutations in any other AWS account |
| `VPN_TAILSCALE_HOSTNAME` | Machine name checked in the local tailnet |
| `VPN_BUNDLE_ID` | Advanced bundle override |
| `VPN_SCHEDULER_STACK` | CloudFormation stack used by timers |

## Status and lifecycle

```bash
# Read-only status across all supported Regions.
./scripts/region-relay.sh status

# Start or switch to one destination.
./scripts/region-relay.sh --country india up
./scripts/region-relay.sh --country uk up
./scripts/region-relay.sh --country canada up
./scripts/region-relay.sh --country singapore up

# Remove only the selected country's resources.
./scripts/region-relay.sh --country canada --yes down

# Remove managed VMs, timers, temporary snapshots, and automation static IPs
# in every supported Region. The canonical Mumbai snapshot is retained.
./scripts/region-relay.sh --yes down
```

With no command, the CLI retains its compatibility behavior: it toggles the
default India instance only. Explicit `down` without `--country` is global.

## Snapshots

```bash
./scripts/region-relay.sh --country canada snapshot
```

Outside India, the script creates a local snapshot, copies it to Mumbai under
the canonical prefix, waits for availability, removes the previous canonical
snapshot, and deletes the temporary local source. If promotion fails, it keeps
the local snapshot for diagnosis instead of deleting the last recoverable copy.

Snapshots are billable until deleted.

## Public IPv4 addresses

The default address is dynamic. It can change when an instance is recreated or
stopped and started.

```bash
./scripts/region-relay.sh --country india rotate
```

The optional static-IP command allocates candidates in the selected Region,
attaches the first address matching one of the provided literal prefixes, and
releases every rejected automation-owned address:

```bash
./scripts/region-relay.sh \
  --country india \
  --yes \
  hunt-static-ip --prefix 203.0.113. --max-attempts 5
```

Use prefixes that can actually be allocated in the selected AWS Region; the
documentation prefix above is intentionally non-routable. Unattached static
IPv4 addresses incur hourly charges. Global `down` releases automation-owned
static IPs so they do not remain as billable orphans.

## Usage and costs

```bash
./scripts/region-relay.sh --country canada usage
```

The output uses the selected Region's bundle allowance and Cost Explorer data.
Cost data is estimated and can lag. Confirm final amounts in AWS Billing.

## Automatic deletion timer

Deploy the scheduler stack once in each Region where timers will be used:

```bash
aws cloudformation deploy \
  --profile region-relay \
  --region ca-central-1 \
  --stack-name region-relay-scheduler \
  --template-file infra/scheduler.yaml \
  --capabilities CAPABILITY_IAM
```

Then schedule or cancel a one-time deletion:

```bash
./scripts/region-relay.sh --country canada schedule-down 2
./scripts/region-relay.sh --country canada cancel-down
```

Timers refuse to run while a static IP is attached because direct instance
deletion could otherwise leave a billable unattached IP.

## Tailscale client controls

Select the machine from the client's exit-node list. On Linux:

```bash
sudo tailscale set --exit-node=aws-exit-node
```

Stop using an exit node without stopping the AWS VM:

```bash
sudo tailscale set --exit-node=
```

The Tailscale documentation describes approval, grants, and platform-specific
client controls: [Exit nodes](https://tailscale.com/docs/features/exit-nodes).

## Recovery

If a destination launch fails after the previous VM has been removed, restore
India from the canonical snapshot:

```bash
./scripts/region-relay.sh --country india up
```

If AWS reports an expired session, the script offers to start `aws login` in an
interactive terminal. It never asks you to paste long-lived AWS credentials.
