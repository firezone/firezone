# CI Tips and Tricks

## Adding a new repository to Google Cloud workload identity

We are using a separate Google Cloud project for GitHub Actions workload
federation, if you need `auth` action to work from a new repo - it needs to be
added to the principal set of a GitHub Actions service account:

```
export REPO="firezone/firezone"
gcloud iam service-accounts add-iam-policy-binding "github-actions@github-iam-387915.iam.gserviceaccount.com" \
  --project="github-iam-387915" \
  --role="roles/iam.workloadIdentityUser" \
  --member="principalSet://iam.googleapis.com/projects/397012414171/locations/global/workloadIdentityPools/github-actions-pool/attribute.repository/${REPO}"
```

for more details see https://github.com/google-github-actions/auth.

## Larger GitHub-hosted runners

We've configured two GitHub-hosted larger runners to use in workflows:

- `ubuntu-22.04.firezone-4c`
- `ubuntu-22.04-firezone-16c`

Please use them wisely (especially the 16c one) as we are billed for their
usage.

Before you run your jobs on these larger runners, please ensure your workload is
**CPU-bound** or **Memory-size-bound** so that your workflow / job will actually
benefit from the extra cores. Many workloads are IO-bound and won't see a marked
difference using a larger runner.

## Self-hosted runners

We maintain a baremetal testbed for running our end-to-end test suite. See
[the `e2e`](../e2e) directory. Please don't target those runners unless you're
specifically trying to run workflows that require a baremetal runner.
