# Alexa Region Relay: private voice control

Region Relay is a private Alexa custom skill for RegionRelay. Alexa acknowledges a
command immediately, an asynchronous CodeBuild job runs the existing lifecycle
script, and a later status request reports both job state and the current
Lightsail public IP.

## What you can say

- “Alexa, ask Region Relay to start the exit node in Canada.”
- “Alexa, ask Region Relay to hunt for my target IP in India up to 30 times.”
- “Alexa, ask Region Relay what the current public IP is.”
- “Alexa, ask Region Relay if the IP hunt has finished.”
- “Alexa, ask Region Relay to rotate the public IP in India.”
- “Alexa, ask Region Relay to bring down the exit node.”

The down command asks for confirmation and then removes every managed VM,
timer, temporary snapshot, and automation-owned static IP. It retains the
canonical Mumbai recovery snapshot.

## Before you deploy

1. Complete the [AWS account prerequisites](aws-account-prerequisites.md).
2. Bootstrap and approve the Tailscale node, then create the canonical Mumbai
   snapshot as described in that guide.
3. Choose the literal public IPv4 prefix or comma-separated prefixes that a
   hunt may accept, for example `13.` or `13.204.,65.0.`. Prefixes are stack
   configuration, not voice input.
4. Use short-lived AWS credentials. Never paste AWS or Tailscale credentials
   into this repository, the Alexa console, or chat.
5. Review Lightsail static-IP quotas, API policies, and charges. A 400-candidate
   hunt allocates and releases many addresses and can be rate limited.

## Step 1: create the Alexa skill shell

1. Sign in to the [Alexa Developer Console](https://developer.amazon.com/alexa/console/ask).
2. Choose **Create Skill**.
3. Name it **Region Relay**, select the English locale used by the Echo, choose
   **Custom**, and choose to provision your own backend resources.
4. Open the skill's **Endpoint** page or skill settings and copy the Skill ID,
   which starts with `amzn1.ask.skill.`.

The checked-in invocation name is `region relay`, producing “Alexa, ask Region
Relay …”.

## Step 2: prepare a private deployment bucket

Use an existing private bucket in the deployment Region, or create one. Europe
and India Alexa users commonly use `eu-west-1` for low latency.

```bash
export OPSY_BUCKET="replace-with-a-globally-unique-private-bucket"
export OPSY_REGION="eu-west-1"

aws s3api create-bucket \
  --bucket "$OPSY_BUCKET" \
  --region "$OPSY_REGION" \
  --create-bucket-configuration LocationConstraint="$OPSY_REGION"

aws s3api put-public-access-block \
  --bucket "$OPSY_BUCKET" \
  --public-access-block-configuration \
  BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true

aws s3api put-bucket-encryption \
  --bucket "$OPSY_BUCKET" \
  --server-side-encryption-configuration \
  '{"Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"AES256"}}]}'

aws s3api put-bucket-versioning \
  --bucket "$OPSY_BUCKET" \
  --versioning-configuration Status=Enabled
```

Add your normal bucket lifecycle policy if you want old versioned deployment
artifacts expired automatically.

## Step 3: deploy the AWS backend

From the repository root:

```bash
export OPSY_SKILL_ID="amzn1.ask.skill.replace-me"
export OPSY_ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)"

./opsy/deploy.sh \
  --region "$OPSY_REGION" \
  --artifact-bucket "$OPSY_BUCKET" \
  --skill-id "$OPSY_SKILL_ID" \
  --account-id "$OPSY_ACCOUNT_ID" \
  --target-prefixes '43.,65.0.'
```

Add `--profile region-relay` if you use the named profile from the RegionRelay
setup. The deployer requires AWS CLI 2.32.0 or newer, verifies the AWS account,
uploads an encrypted source archive, packages the Lambda, deploys CloudFormation,
and prints the outputs. Keep the `AlexaFunctionArn` output.

The stack creates:

- a seven-second Python Lambda used only for Alexa requests;
- a CodeBuild project with a 60-minute ceiling for lifecycle jobs;
- separate Alexa and runner IAM roles;
- Skill-ID-scoped Lambda invocation permission;
- 30-day Lambda and CodeBuild log groups;
- CloudWatch alarms for Lambda errors and failed builds.

The alarms have no notification target by default. Attach an SNS topic in your
account if you want email or push notifications.

## Step 4: connect the Lambda endpoint

In the Alexa Developer Console:

1. Open **Custom > Endpoint**.
2. Choose **AWS Lambda ARN**.
3. Paste `AlexaFunctionArn` into the endpoint for your Alexa geographical
   region. For a device registered in Germany or the UK, use **Europe and
   India**; also set it as the default while developing.
4. Save the endpoint.

The CloudFormation stack already grants `alexa-appkit.amazon.com` permission
with the exact Skill ID as its source token.

## Step 5: import and build the voice model

1. For English UK, open **Custom > Interaction Model > JSON Editor** and paste
   [en-GB.json](../opsy/interaction-models/en-GB.json). For English US, use
   [en-US.json](../opsy/interaction-models/en-US.json).
2. Choose **Save Model**, then **Build Model**.
3. If your Echo uses another locale, add that locale and translate its sample
   utterances before expecting the device to invoke Region Relay.

## Step 6: test safely

Start with read-only status in the Alexa simulator:

> ask region relay for status

Then run one lifecycle command and wait before checking:

> ask region relay to start the exit node in india

> ask region relay for status

CloudWatch logs are under `/aws/lambda/<stack>-alexa` and
`/aws/codebuild/<stack>-runner`. The CodeBuild console also shows each exact
bounded job and whether it succeeded.

Only after `up` works should you test a short hunt, such as five attempts.
Increase to 400 after confirming the prefix, account, quotas, cleanup, and
expected API behavior.

## Updating and removing Region Relay

Rerun `opsy/deploy.sh` after code or configuration changes. To stop runtime
cost before deleting infrastructure, first say “Alexa, ask Region Relay to bring down
the exit node” and confirm, then verify status. Stack deletion retains the two
CloudWatch log groups by design; the artifact bucket and canonical RegionRelay
snapshot are outside the stack and remain under your control.
