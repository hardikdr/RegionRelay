# Security policy

## Reporting a vulnerability

Please use GitHub's private vulnerability reporting feature rather than a
public issue. Do not include active credentials, private keys, session tokens,
Tailscale authentication URLs, account IDs, or organization identifiers.

## Operational security

- Use short-lived AWS CLI sessions and a dedicated profile.
- Set `VPN_EXPECTED_ACCOUNT` to prevent accidental cross-account changes.
- Keep AWS Organizations and IAM permissions least-privileged.
- Review CloudTrail for unexpected infrastructure mutations.
- Keep public inbound Lightsail ports closed after bootstrap.
- Restrict Tailscale exit-node use with tailnet grants or ACLs.
- Treat snapshots as sensitive because they contain the VM filesystem and
  Tailscale node state.
- Review all commands before using `--yes`.

This repository intentionally contains no AWS or Tailscale secrets. If a secret
is committed, revoke it immediately and remove it from Git history; deleting it
only in a later commit is insufficient.

