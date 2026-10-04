# Contributing

Contributions that improve safety, portability, documentation, tests, or AWS
cost visibility are welcome.

## Development

1. Fork the repository and create a focused branch.
2. Do not include AWS account IDs, organization IDs, public IP addresses,
   credentials, Tailscale keys, or private logs in commits or issues.
3. Add or update offline tests for behavioral changes.
4. Run the complete test suite:

   ```bash
   ./tests/test-repository.sh
   ./tests/test-lifecycle.sh
   ```

5. Describe the AWS resources, permissions, costs, and cleanup behavior changed
   by the pull request.

Keep resource cleanup ownership-scoped. Changes must not broaden deletion to
unrelated instances, snapshots, static IPs, schedules, or stacks.

