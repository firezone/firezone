# CI Tips and Tricks

## Rotating signing secrets

- Apple: see [../swift/apple/README.md](../swift/apple/README.md)
- Android: see [../kotlin/android/README.md](../kotlin/android/README.md)
- Windows: see [../rust/gui-client/README.md](../rust/gui-client/README.md)

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

## Busting the GCP Docker layer cache

If you find yourself hitting strange Docker image issues like Rust binaries
failing to start inside Docker images, you may need to bust the GCP layer cache.

To do so:

- Login to [GCP](console.cloud.google.com)
- Ensure `firezone-staging` project is selected
- Navigate to the artifact registry service
- Delete all image versions for the appropriate `cache/` image repository
