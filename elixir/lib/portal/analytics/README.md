# Account ad conversions

Set `OPENAI_CONVERSIONS_API_KEY` and `OPENAI_CONVERSIONS_PIXEL_ID` in the portal
runtime to enable OpenAI delivery. Without both, conversion jobs are not queued.
Ad destinations and credentials are deployment configuration, never application
defaults. Tests use synthetic destinations.

- `registration_completed` / `customer_action`: successful email or Google signup.
- `subscription_created` / `plan_enrollment`: Stripe confirms an active Team
  enrollment, including a trial becoming active. Free plans, Enterprise, incomplete
  subscriptions, renewals and seat changes do not count.

Requests use the [Conversions API](https://developers.openai.com/ads/conversions-api).
Jobs send SHA-256 hashes of trimmed, lowercase email addresses. Registration uses
the registrant's email; Team enrollment uses the billing email. Retries preserve
the original event ID and timestamp. Permanent HTTP failures cancel the job.

Deploy the accompanying website link-handoff change with the portal change. Portal
links carry `fz_marketing=true|false` and, when allowed, `fz_oppref`, `fz_gclid`,
`fz_gbraid`, and `fz_wbraid`; these are
removed from the URL after capture. Marketing permission is separate from PostHog
permission. Email verification preserves attribution in its signed token.

Consent and click attribution use existing account metadata, so no migration is
needed. Snapshots expire after 90 days. Admin sign-in and entry into Stripe billing
refresh the snapshot when the session contains a new choice. Jobs recheck saved
consent before delivery. Direct visits without a consent snapshot are not reported.
Website consent changes reach the account on its next portal handoff; there is no
background synchronization between the sites.

Enqueue failures are logged without blocking signup or billing. Enqueueing follows
successful application transactions, leaving a small failure window between commit
and enqueue. These events are best-effort measurement, not an audit log.

## Google Ads

The Google Data Manager API imports the same two events. Set these runtime variables:

- `GOOGLE_ADS_CUSTOMER_ID`
- `GOOGLE_ADS_REGISTRATION_CONVERSION_ACTION_ID`
- `GOOGLE_ADS_SUBSCRIPTION_CONVERSION_ACTION_ID`
- `GOOGLE_ADS_SERVICE_ACCOUNT_EMAIL`
- `GOOGLE_ADS_WORKLOAD_IDENTITY_PROVIDER`
- `GOOGLE_ADS_WORKLOAD_IDENTITY_AUDIENCE`

Set `GOOGLE_ADS_LOGIN_CUSTOMER_ID` only when access requires a manager account.
Use numeric customer IDs without hyphens and numeric import action IDs, not
browser `AW-` tags or event labels. Missing identity or customer settings disable
Google jobs; a missing action ID disables only that event.

Authentication uses the portal's Azure managed identity, Google STS, and IAM
Credentials `generateAccessToken` with the
`https://www.googleapis.com/auth/datamanager` scope. It reuses the existing Google
federation and token cache infrastructure, with a dedicated Ads service account.
No user OAuth client, refresh token, private key, or Workspace domain-wide
delegation is needed. The service-account token cache includes provider, audience,
service account, and scope to isolate credentials from Workspace and other APIs.

Enable Data Manager, STS and IAM Credentials APIs. Grant the portal's federated
principal `roles/iam.workloadIdentityUser` on the Ads service account and grant
that service account `roles/serviceusage.serviceUsageConsumer` on its project.
Add its email to the receiving Google Ads account with Standard access after the
service account is created. See Google's
[access setup](https://developers.google.com/data-manager/api/devguides/quickstart/set-up-access).

The companion infra PR provisions the identity and passes Terraform Cloud inputs
through the production portal module into `portal.env`. Apply GCP first so its
identity outputs exist, then grant Ads account access, apply the production portal
workspace, and deploy the portal and companion website handoff. Staging has no ad
destinations by default. Do not enable ad conversions there with production IDs.

The worker submits hashed email plus any saved Google click identifiers. Google
email normalization removes Gmail dots and plus aliases, following its
[formatting rules](https://developers.google.com/data-manager/api/devguides/concepts/formatting).
OpenAI normalization remains separate. Consent is required even for hash-only
matching, and is checked again before network requests. Identity tokens and raw
email are never persisted in conversion jobs.

Google ingestion is asynchronous: a successful request means accepted, not yet
matched or attributed. The worker logs the returned request ID for Google
Data Manager diagnostics, and reports whether field warnings were returned.
Monitor those diagnostics and the Ads conversion status after deployment before
promoting these actions to primary bidding goals. No synthetic conversions were
sent while creating the actions.
