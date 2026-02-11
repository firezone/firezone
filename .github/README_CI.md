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
