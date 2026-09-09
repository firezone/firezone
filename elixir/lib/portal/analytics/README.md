# Account ad conversions

Set `OPENAI_CONVERSIONS_API_KEY` in the portal runtime to enable delivery to pixel
`3b8jrA5hEKwRPyD15bYfAQ`. Without the key, conversion jobs are not queued.

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

The Google Data Manager API imports the same two events into Firezone customer
`3339175923`. The created actions are secondary (observation), with no monetary
value assigned:

| Event | Action | Numeric action ID | Count |
| --- | --- | --- | --- |
| `registration_completed` | Registration completed | `7754865801` | One |
| `subscription_created` | Subscribed to Team plan | `7754865804` | Every |

Enable the Data Manager API in the OAuth client's Cloud project and authorize a
user with access to this Ads account using the
`https://www.googleapis.com/auth/datamanager` scope. Set these runtime secrets:

- `GOOGLE_ADS_CLIENT_ID`
- `GOOGLE_ADS_CLIENT_SECRET`
- `GOOGLE_ADS_REFRESH_TOKEN`

See Google's [access setup](https://developers.google.com/data-manager/api/devguides/quickstart/set-up-access).
Credentials have not been provisioned by this change. Google jobs are disabled
until all three are present. `GOOGLE_ADS_CUSTOMER_ID`,
`GOOGLE_ADS_REGISTRATION_CONVERSION_ACTION_ID`, and
`GOOGLE_ADS_SUBSCRIPTION_CONVERSION_ACTION_ID` default to the IDs above and may be
overridden. Set `GOOGLE_ADS_LOGIN_CUSTOMER_ID` only when access requires a manager
account. Use numeric IDs without hyphens; browser `AW-` tags and event labels are
not Data Manager destinations.

The worker refreshes its access token and submits hashed email plus any saved
Google click identifiers. Google email normalization also removes Gmail dots and
plus aliases, following its [formatting rules](https://developers.google.com/data-manager/api/devguides/concepts/formatting).
OpenAI normalization remains separate. Consent is required even for hash-only
matching, and is checked again before network requests. OAuth credentials and
raw email are never persisted in conversion jobs.

Google ingestion is asynchronous: a successful request means accepted, not yet
matched or attributed. The worker logs the returned request ID for Google
Data Manager diagnostics, and reports whether field warnings were returned.
Monitor those diagnostics and the Ads conversion status after deployment before
promoting these actions to primary bidding goals. No synthetic conversions were
sent while creating the actions.
