# RegionRelay

Provision on-demand regional Tailscale exit nodes on Amazon Lightsail, move them
between supported AWS Regions, and remove billable resources when they are not
needed.

The project keeps one canonical Lightsail snapshot in Mumbai and creates at
most one managed VM at a time. A country switch copies the snapshot to the
destination, verifies the copy, removes the previous VM, restores the new VM,
closes all public inbound ports, and deletes the temporary snapshot.

## Features

- Regional exit nodes in India, the United Kingdom, Canada, and Singapore.
- One-active-VM safety model to limit cost and prevent duplicate Tailscale
  machine identities.
- No inbound public firewall rules after provisioning.
- No AWS access keys or Tailscale authentication keys stored in the repository.
- Snapshot-based `up` and `down`, dynamic IPv4 rotation, optional static IPv4
  management, usage reporting, and one-time automatic deletion timers.
- Ownership-scoped cleanup that leaves unrelated Lightsail resources alone.

This project is intended for legitimate administration of infrastructure you
own. You are responsible for applicable laws, organizational policies, network
security, and third-party terms. Cloud-provider addresses are publicly
identifiable, and compatibility with external services is not guaranteed.

## Repository layout

```text
scripts/region-relay.sh       Lifecycle CLI
scripts/bootstrap-tailscale-exit-node.sh Initial Linux/Tailscale setup
infra/scheduler.yaml                     Optional deletion-timer stack
docs/aws-account-prerequisites.md        Account, Region, SCP, and IAM setup
docs/operations.md                       Commands and recovery procedures
tests/                                   Offline lifecycle test suite
```

## Prerequisites

- An AWS account with billing enabled.
- AWS CLI version 2.32.0 or newer.
- A short-lived CLI session, preferably created with `aws login`.
- Amazon Lightsail access in every Region you intend to use.
- A Tailscale tailnet where you can approve an exit node.
- Bash, Python 3, and standard Unix command-line tools.

AWS account Region enablement and AWS Organizations policies are separate
controls. A Region can appear enabled in the account console while an
Organizations service control policy still explicitly denies Lightsail there.
Complete [the AWS account prerequisites](docs/aws-account-prerequisites.md)
before provisioning.

## Supported destinations

| Country | AWS Region | Lightsail bundle |
|---|---|---|
| India | `ap-south-1` | `nano_3_1` |
| United Kingdom | `eu-west-2` | `nano_3_0` |
| Canada | `ca-central-1` | `nano_3_0` |
| Singapore | `ap-southeast-1` | `nano_3_0` |

Bundle availability is checked before an existing VM is removed. Set
`VPN_BUNDLE_ID` only when you have verified that the replacement bundle is
available in the selected Region and can restore the snapshot.

## Configure the local environment

```bash
cp .env.example .env
# Edit .env, including VPN_EXPECTED_ACCOUNT.
set -a
source .env
set +a

aws --version
aws login --profile "$VPN_AWS_PROFILE"
aws sts get-caller-identity --profile "$VPN_AWS_PROFILE"
```

Do not paste AWS access keys, Tailscale keys, private keys, or session tokens
into `.env`, issues, logs, or chat. The lifecycle script uses the named AWS CLI
profile and verifies the caller identity before changing resources.

## First-time bootstrap

The lifecycle CLI restores an existing canonical snapshot. A new account must
therefore bootstrap one Linux Lightsail instance in `ap-south-1` first:

1. Query the current Lightsail Linux blueprints and availability zones.
2. Create a small Ubuntu instance using
   `scripts/bootstrap-tailscale-exit-node.sh` as user data.
3. Connect through the Lightsail console, finish `tailscale up`, and approve the
   advertised exit node in the Tailscale admin console.
4. Run the lifecycle `up` command once to close all public inbound ports.
5. Create the canonical snapshot with the `snapshot` command.

Detailed commands and safety checks are in
[AWS account prerequisites](docs/aws-account-prerequisites.md).

## Everyday commands

```bash
# Show all managed Regions without changing anything.
./scripts/region-relay.sh status

# Start in one country. Any managed VM in another supported Region is removed.
./scripts/region-relay.sh --country canada up

# Delete all managed VMs and static IPs; retain the canonical snapshot.
./scripts/region-relay.sh --yes down

# Refresh the canonical snapshot from the running machine.
./scripts/region-relay.sh --country canada snapshot

# Display selected-Region transfer and estimated Lightsail charges.
./scripts/region-relay.sh --country canada usage

# Delete the selected VM automatically after two hours.
./scripts/region-relay.sh --country canada schedule-down 2
```

Read [Operations](docs/operations.md) before using static-IP or recovery
commands.

## Costs

Lightsail bills instances by the hour up to the plan's monthly maximum.
Instances continue to accrue charges while stopped, so this project deletes
them when taking an exit node down. Snapshots and unattached static IPv4
addresses are separate billable resources. Data-transfer allowances and
overage prices vary by Region.

Review the current [Lightsail pricing](https://aws.amazon.com/lightsail/pricing/)
and [Lightsail billing documentation](https://docs.aws.amazon.com/lightsail/latest/userguide/amazon-lightsail-frequently-asked-questions-faq-billing-and-account-management.html)
before use.

## Test locally

The tests use a filesystem-backed fake AWS CLI and do not contact AWS:

```bash
./tests/test-repository.sh
./tests/test-lifecycle.sh
```

## License

MIT. See [LICENSE](LICENSE).
