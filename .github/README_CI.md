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

## End to end test architecture

Unfortunately, it's not feasible to write automated end-to-end tests for every
scenario. Some manual QA testing is required before publishing a new release.
However, this workflow attempts to automate at least some of it.

The [end-to-end workflow](./workflows/e2e.yml) makes use of the baremetal
testbed running at the Firezone HQ. The testbed consists of the following
components:

- An `ubuntu-22.04` testbed orchestration server with the following specs:
  - Ryzen 5950x 16-core CPU
  - 128 GB DDR4 ECC memory
  - 500 GB NVMe SSD
  - 10 gbe networking
- Apple Silicon Macbook Air running macOS 14 with the following specs:
  - 256 GB SSD
  - 8 GB memory
  - 8-core M1
  - 1 gbe networking
- Laptop running Windows 11 with the following specs:
  - Intel i3
  - 12 GB RAM
  - 256 GB SSD
  - 1 gbe networking
