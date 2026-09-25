# Google Ads conversion verification

The portal imports completed registrations and active Team enrollments through the
Google Data Manager API. Trials, renewals, and seat changes aren't new enrollments.
Jobs contain hashed email and consented click IDs. Ad API calls run outside signup
and billing transactions; the Oban inserts commit with the corresponding business
change. An enqueue failure rolls back that change so retrying can recover it.

## 1. Check deployment and account configuration

On the running release, confirm these runtime settings are populated:

- `GOOGLE_ADS_CUSTOMER_ID` (digits only, no hyphens)
- `GOOGLE_ADS_REGISTRATION_CONVERSION_ACTION_ID`
- `GOOGLE_ADS_SUBSCRIPTION_CONVERSION_ACTION_ID`
- `GOOGLE_ADS_SERVICE_ACCOUNT_EMAIL`
- `GOOGLE_ADS_WORKLOAD_IDENTITY_PROVIDER`
- `GOOGLE_ADS_WORKLOAD_IDENTITY_AUDIENCE`

The Azure managed identity configured for the portal must match the subject allowed
by the workload identity provider and the service account's
`roles/iam.workloadIdentityUser` binding. The provider must accept the configured
Azure audience. Enable Data Manager, IAM Credentials, and STS in the Google project.

In Google Ads, check both conversion actions:

- The configured customer owns the actions; the numeric IDs match.
- Their source is **Website (Import from clicks)** (`UPLOAD_CLICKS`).
- Enhanced conversions for leads is enabled and the applicable terms are accepted.
- The service account has access to that customer, directly or through a manager.
  For manager access, configure `GOOGLE_ADS_LOGIN_CUSTOMER_ID`.
- Primary/secondary status, campaign goals, counting, conversion windows, and default
  values match the intended bidding strategy. The portal doesn't send revenue values.

See [destination requirements](https://developers.google.com/data-manager/api/devguides/events/send-events)
and [API access setup](https://developers.google.com/data-manager/api/devguides/quickstart/set-up-access).

## 2. Validate through the actual portal identity

After deploying this change, run from the release directory inside a running portal
container (or use the existing remote console):

```sh
bin/portal rpc 'IO.inspect(Portal.Analytics.GoogleAds.validate_configuration())'
```

Expected result:

```elixir
[
  registration_conversion_action_id: {:ok, %{field_warnings: []}},
  subscription_conversion_action_id: {:ok, %{field_warnings: []}}
]
```

This uses the same Azure IMDS → Google STS → service-account impersonation path as
normal delivery. It submits a synthetic hashed `validation@example.com` event to
each action with **`validateOnly: true`**. It creates no conversion or Oban job and
prints no credentials. Review any returned warning codes and field paths. HTTP
errors are returned as sanitized status codes; authentication failures are separate.

A successful validation checks synchronous API validation and authorization. It
doesn't prove asynchronous ingestion, attribution, or inclusion in bidding.
Validation-only requests have no processing diagnostics.

## 3. Verify attribution and real delivery

Use staging for synthetic click IDs. Visit `/sign_up?gclid=example` from an allowed
region, then follow the email or Google signup path. Confirm the URL is cleaned and
the account's `metadata.marketing_attribution.gclid` survives navigation. Repeat
with `fz_mktg=false`, GPC enabled, and an opt-in region; click IDs must not be saved
without an allowed marketing decision. Prefixed website handoffs (`fz_gclid` plus
`fz_mktg=true`) remain supported.

For production attribution, inspect a genuine, consented ad-driven signup and a
subsequent active Team enrollment. Don't submit fake clicks to production actions.
In Oban, locate `Portal.Analytics.GoogleAds` jobs by `args.account_id`. Check their
stable `transactionId` (`registration_<account UUID>` or `team_<subscription ID>`),
destination, and state. Don't copy email hashes or click IDs into logs or tickets.
Reopening a verification link or replaying a webhook should not create a new event.

An ingestion HTTP success means **accepted**, not processed. Each successful upload
schedules `Portal.Analytics.GoogleAds.Diagnostics` after 30 minutes, retaining the
Google request ID in `args.request_id` and the conversion ID in `args.transaction_id`.
Ingestion warnings are retained in the diagnostics job’s `meta.field_warnings`.
The diagnostics worker only reads status;
it never resubmits conversions. It retries pending statuses and temporary HTTP
failures with increasing delays capped at one hour, for roughly a day.

- `completed`: all returned destinations reached `SUCCESS`; review warning logs.
- `cancelled` with `processing_failed`: a destination reached `FAILED` or
  `PARTIAL_SUCCESS`. The job error retains aggregate reason codes and counts.
- `discarded`: polling exhausted its attempts or encountered repeated errors.
- Ingestion field warning logs retain reason codes and field paths, excluding
  free-form descriptions. Processing warning logs retain aggregate counts/reasons.

To manually inspect a real request (including one submitted before this change):

```sh
bin/portal rpc 'IO.inspect(Portal.Analytics.GoogleAds.request_status("REQUEST_ID"))'
```

Wait at least 30 minutes after ingestion. Processing can take up to 24 hours. Fix
reported account/data problems before considering a replay; preserve transaction
IDs to avoid double counting. Check Google Ads conversion diagnostics and reports
as well: API processing success alone doesn't establish that a user matched an ad
or that the conversion was included in a campaign's bidding goals.

See [Google's diagnostics workflow](https://developers.google.com/data-manager/api/devguides/diagnostics).
