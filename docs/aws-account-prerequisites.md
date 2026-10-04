# AWS account prerequisites

Several independent AWS controls must permit the destination Region. Check all
of them before creating or moving an exit node.

## 1. Authenticate with short-lived credentials

Install AWS CLI 2.32.0 or newer and create a local-development session:

```bash
aws --version
aws login --profile region-relay
aws sts get-caller-identity --profile region-relay --region ap-south-1
```

The returned account and role must be the account where Lightsail resources
will run. Set `VPN_EXPECTED_ACCOUNT` locally so the script refuses to mutate a
different account. Do not create long-lived IAM access keys solely for this
project.

## 2. Enable the AWS Region for the account

Some AWS Regions are opt-in Regions and are disabled by default. In the AWS
account or management-account console, open **AWS Regions**, enable the desired
Region, and wait until its status becomes **Enabled**.

Lightsail may also show its own opt-in workflow. AWS documents that the
Lightsail opt-in status must be enabled before provisioning in such a Region:
[Enable opt-in Regions for Lightsail](https://docs.aws.amazon.com/lightsail/latest/userguide/opt-in-regions-for-lightsail-enable.html).

The four destinations currently built into the lifecycle script are:

```text
ap-south-1      India (Mumbai)
eu-west-2       United Kingdom (London)
ca-central-1    Canada (Central)
ap-southeast-1  Singapore
```

## 3. Check the AWS Organizations Region guardrail

Accounts in AWS Organizations can inherit a Region restriction service control
policy (SCP) from the organization root or an organizational unit. In newer AWS
account-management experiences this may appear as a Region allowlist, Region
restriction, or an automatically generated advanced-mode Region restriction
policy.

An SCP does not grant access. It defines the maximum permissions available to
the member account. `AdministratorAccess` or `FullAWSAccess` in the member
account cannot override an explicit `Deny` inherited from an SCP.

From the management account:

1. Open **AWS Organizations**.
2. Select the member account or its organizational unit.
3. Inspect **Service control policies** and inherited policies.
4. Locate the policy that restricts `aws:RequestedRegion`.
5. Add every Region this project should use to that policy's allowed Region
   set, or adjust the management product's Region selection that generates the
   policy.
6. Save the change and allow time for propagation.

Do not detach security guardrails casually. Keep the allowlist as narrow as
your organization requires and have the organization administrator review the
change. AWS explains SCP creation and attachment in
[Creating organization policies](https://docs.aws.amazon.com/organizations/latest/userguide/orgs_policies_create.html).

## 4. Verify the effective result

Run these read-only checks for every desired Region:

```bash
REGION=ca-central-1

aws lightsail get-regions \
  --include-availability-zones \
  --profile region-relay \
  --region "$REGION" \
  --no-cli-pager

aws lightsail get-bundles \
  --profile region-relay \
  --region "$REGION" \
  --no-cli-pager
```

An `AccessDeniedException` mentioning an explicit deny in a service control
policy must be resolved in the management account. An empty bundle query is a
different problem: the configured Lightsail bundle is unavailable in that
Region.

## 5. Required permissions

The operator identity needs permission for the operations it uses:

- `sts:GetCallerIdentity`
- Lightsail instance, snapshot, firewall, static-IP, bundle, Region, and tag
  operations used by the lifecycle script
- Cost Explorer read access for `usage`
- EventBridge Scheduler access for deletion timers
- CloudFormation and IAM deployment permissions only when deploying the
  optional scheduler stack

Organizations SCPs, permission boundaries, session policies, and identity
policies all participate in AWS policy evaluation. Grant only the permissions
needed for the commands you intend to use.

## 6. Bootstrap the canonical instance

First inspect current blueprint and zone identifiers:

```bash
aws lightsail get-blueprints \
  --profile region-relay \
  --region ap-south-1 \
  --query "blueprints[?platform=='LINUX_UNIX' && contains(name, 'Ubuntu')].[blueprintId,name,version]" \
  --output table \
  --no-cli-pager

aws lightsail get-regions \
  --include-availability-zones \
  --profile region-relay \
  --region ap-south-1 \
  --no-cli-pager
```

Create the instance using a current Ubuntu blueprint returned by AWS:

```bash
aws lightsail create-instances \
  --profile region-relay \
  --region ap-south-1 \
  --instance-names india-exit-mumbai \
  --availability-zone ap-south-1a \
  --blueprint-id YOUR_CURRENT_UBUNTU_BLUEPRINT_ID \
  --bundle-id nano_3_1 \
  --user-data file://scripts/bootstrap-tailscale-exit-node.sh \
  --tags key=ManagedBy,value=region-relay key=Purpose,value=tailscale-exit-node \
  --no-cli-pager
```

Use the Lightsail console connection to complete Tailscale authentication:

```bash
sudo tailscale up \
  --advertise-exit-node \
  --hostname=aws-exit-node \
  --accept-dns=false
```

Open the authentication URL shown by Tailscale, then approve the machine as an
exit node in the Tailscale admin console. Tailscale requires Linux IP
forwarding and explicit exit-node approval; see
[Tailscale exit nodes](https://tailscale.com/docs/features/exit-nodes).

Finally, close public ports and create the recovery snapshot:

```bash
./scripts/region-relay.sh --country india up
./scripts/region-relay.sh --country india snapshot
```

