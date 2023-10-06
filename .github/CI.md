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
