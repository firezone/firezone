# CI Tips and Tricks

## Batch-deleting workflow runs

Manually disable the workflows to be cleaned up, then run this:

```bash
org=firezone
repo=firezone

# Get workflow IDs with status "disabled_manually"
workflow_ids=($(gh api repos/$org/$repo/actions/workflows --paginate | jq '.workflows[] | select(.["state"] | contains("disabled_manually")) | .id'))

for workflow_id in "${workflow_ids[@]}"
do
  echo "Listing runs for the workflow ID $workflow_id"
  run_ids=( $(gh api repos/$org/$repo/actions/workflows/$workflow_id/runs --paginate | jq '.workflow_runs[].id') )
  for run_id in "${run_ids[@]}"
  do
    echo "Deleting Run ID $run_id"
    gh api repos/$org/$repo/actions/runs/$run_id -X DELETE >/dev/null
  done
done
```

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
