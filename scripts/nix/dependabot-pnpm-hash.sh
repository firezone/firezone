#!/usr/bin/env bash
# Compute untrusted hash data, or apply it using trusted workflow code only.

PNPM_FRONTEND="scripts/nix/packages/firezone-gui-client/frontend.nix"
PNPM_LOCKFILE="rust/gui-client/pnpm-lock.yaml"
PNPM_WORKFLOW=".github/workflows/dependabot-nix-pnpm.yml"

fail() {
    echo "$*" >&2
    return 1
}

validate_hash() {
    [[ "$1" =~ ^sha256-[A-Za-z0-9+/]{43}=$ ]] || fail "Invalid SHA-256 SRI"
}

read_pin() {
    local value
    value=$(sed -nE 's/^[[:space:]]*hash[[:space:]]*=[[:space:]]*"(sha256-[A-Za-z0-9+/]{43}=)"[[:space:]]*;[[:space:]]*$/\1/p' "$1")
    validate_hash "$value" || return 1
    printf '%s\n' "$value"
}

replace_pin() {
    read_pin "$1" >/dev/null || return 1
    validate_hash "$2" || return 1
    sed -E "s|^([[:space:]]*hash[[:space:]]*=[[:space:]]*\")(sha256-[A-Za-z0-9+/]{43}=)(\"[[:space:]]*;[[:space:]]*)$|\1${2}\3|" "$1"
}

validate_pr() {
    jq -e --arg repo "$repository" --slurpfile run "$task_tmp/run.json" '
        .state == "open" and
        .user.login == "dependabot[bot]" and
        .base.ref == "main" and .base.repo.full_name == $repo and
        .head.repo.full_name == $repo and
        (.head.ref | test("^dependabot/[A-Za-z0-9._/@+-]+$")) and
        .head.ref == $run[0].head_branch and .head.sha == $run[0].head_sha
    ' "$1" >/dev/null || fail "PR owner, repository, branch or head changed"
}

validate_files() {
    jq -e --arg lock "$PNPM_LOCKFILE" --arg frontend "$PNPM_FRONTEND" '
        any(.[]; .filename == $lock) and
        all(.[]; .status == "modified" and
            (.filename == $lock or .filename == "rust/gui-client/package.json" or .filename == $frontend))
    ' "$1" >/dev/null || fail "Unexpected PR file changes"
}

read_artifact() {
    local archive="$1" sha="$2" entries
    [[ $(wc -c <"$archive") -le 65536 ]] || fail "Artifact archive is too large" || return 1
    entries=$(unzip -Z -1 "$archive") || return 1
    [[ "$entries" == "hash.json" ]] || fail "Expected exactly one hash.json artifact file" || return 1
    # Never extract archive paths. Bound decompression even for a zip bomb.
    unzip -p "$archive" hash.json | head -c 1025 >"$task_tmp/payload.json" || return 1
    [[ $(wc -c <"$task_tmp/payload.json") -le 1024 ]] || fail "Artifact payload is too large" || return 1
    jq -e --arg sha "$sha" '
        type == "object" and keys == ["hash", "sha"] and .sha == $sha and
        (.hash | type == "string" and test("^sha256-[A-Za-z0-9+/]{43}=$"))
    ' "$task_tmp/payload.json" >/dev/null || fail "Invalid artifact payload or commit" || return 1
    jq -r .hash "$task_tmp/payload.json"
}

api() {
    gh api --hostname github.com "$@"
}

repo_api() {
    api "repos/$repository/$1" "${@:2}"
}

get_text() {
    repo_api "contents/$PNPM_FRONTEND?ref=$1" >"$task_tmp/content.json"
    jq -e '.type == "file" and .encoding == "base64" and .size <= 1048576' "$task_tmp/content.json" >/dev/null
    jq -r .content "$task_tmp/content.json" | tr -d '\n' | openssl base64 -d -A >"$2"
}

base64url() {
    openssl base64 -A | tr '+/' '-_' | tr -d '='
}

jwt_api() {
    local jwt="$1" endpoint="$2"
    shift 2
    # GitHub App JWTs require Bearer auth; gh defaults to token auth. Feed
    # curl the header over stdin so the credential is not in process arguments.
    printf 'header = "Authorization: Bearer %s"\n' "$jwt" |
        curl --fail --silent --show-error --max-time 30 --config - \
            --header 'Accept: application/vnd.github+json' \
            --header 'X-GitHub-Api-Version: 2022-11-28' \
            --header 'Content-Type: application/json' \
            --url "https://api.github.com/$endpoint" "$@"
}

mint_token() {

    local now header claims signing_input signature jwt installation
    now=$(date +%s)
    header=$(printf '%s' '{"alg":"RS256","typ":"JWT"}' | base64url)
    claims=$(jq -cn --arg iss "$NIX_HASH_APP_ID" --argjson now "$now" \
        '{iat: ($now - 60), exp: ($now + 540), iss: $iss}' | tr -d '\n' | base64url)
    signing_input="$header.$claims"
    printf '%s\n' "$NIX_HASH_APP_PRIVATE_KEY" >"$task_tmp/key.pem"
    chmod 600 "$task_tmp/key.pem"
    signature=$(printf '%s' "$signing_input" | openssl dgst -sha256 -sign "$task_tmp/key.pem" | base64url)
    rm "$task_tmp/key.pem"
    jwt="$signing_input.$signature"
    installation=$(jwt_api "$jwt" "repos/$repository/installation" | jq -er '.id')
    [[ "$installation" =~ ^[0-9]+$ ]]
    jq -n --arg repo "${repository#*/}" \
        '{repositories: [$repo], permissions: {contents: "write"}}' >"$task_tmp/token-request.json"
    # Assign in this shell so the EXIT trap can revoke the token on any failure.
    write_token=$(jwt_api "$jwt" "app/installations/$installation/access_tokens" \
        --request POST --data-binary "@$task_tmp/token-request.json" | jq -er '.token')
    [[ -n "$write_token" && "$write_token" != "null" ]]
}

cleanup() {
    if [[ -n "${write_token:-}" ]]; then
        GH_TOKEN="$write_token" api installation/token --method DELETE >/dev/null || true
    fi
    rm -rf "$task_tmp"
}

commit_hash() {
    local run_id sha workflow_id number base_sha value current_hash artifact_id parent_tree tree_sha commit_sha branch
    run_id=$(jq -er '.workflow_run.id | select(type == "number" and . > 0 and . == floor)' "$GITHUB_EVENT_PATH")
    repo_api "actions/runs/$run_id" >"$task_tmp/run.json"
    jq -e --arg repo "$repository" --arg workflow "$PNPM_WORKFLOW" '
        .event == "pull_request" and .conclusion == "success" and
        .path == $workflow and .head_repository.full_name == $repo and
        (.head_sha | test("^[0-9a-f]{40}$"))
    ' "$task_tmp/run.json" >/dev/null || fail "Unexpected source run"
    sha=$(jq -r .head_sha "$task_tmp/run.json")
    workflow_id=$(jq -er '.workflow_id | select(type == "number" and . > 0 and . == floor)' "$task_tmp/run.json")
    repo_api "actions/workflows/$workflow_id" | jq -e --arg path "$PNPM_WORKFLOW" '.path == $path' >/dev/null
    repo_api "commits/$sha/pulls" --paginate --slurp >"$task_tmp/prs.json"
    number=$(jq -er --arg sha "$sha" '
        [.[][] | select(.state == "open" and .head.sha == $sha)] |
        select(length == 1) | .[0].number | select(type == "number" and . > 0 and . == floor)
    ' "$task_tmp/prs.json")
    repo_api "pulls/$number" >"$task_tmp/pr.json"
    validate_pr "$task_tmp/pr.json"
    repo_api "pulls/$number/files" --paginate --slurp | jq '[.[][]]' >"$task_tmp/files.json"
    validate_files "$task_tmp/files.json"
    base_sha=$(jq -er '.base.sha | select(test("^[0-9a-f]{40}$"))' "$task_tmp/pr.json")
    get_text "$sha" "$task_tmp/original.nix"
    get_text "$base_sha" "$task_tmp/base.nix"
    replace_pin "$task_tmp/original.nix" "$(read_pin "$task_tmp/base.nix")" >"$task_tmp/normalized.nix"
    cmp -s "$task_tmp/normalized.nix" "$task_tmp/base.nix" || fail "Frontend has changes outside hash pin"
    artifact_id=$(repo_api "actions/runs/$run_id/artifacts?per_page=100" --jq '
        [.artifacts[] | select(.name == "dependabot-pnpm-hash" and .expired == false)] |
        select(length == 1 and .[0].size_in_bytes <= 65536) | .[0].id
    ')
    [[ "$artifact_id" =~ ^[0-9]+$ ]] || fail "Expected one bounded hash artifact"
    repo_api "actions/artifacts/$artifact_id/zip" >"$task_tmp/artifact.zip"
    value=$(read_artifact "$task_tmp/artifact.zip" "$sha")
    current_hash=$(read_pin "$task_tmp/original.nix")
    if [[ "$value" == "$current_hash" ]]; then
        echo "Hash already correct; no commit needed"
        return
    fi
    replace_pin "$task_tmp/original.nix" "$value" >"$task_tmp/updated.nix"
    mint_token
    repo_api "pulls/$number" >"$task_tmp/latest.json"
    validate_pr "$task_tmp/latest.json"
    parent_tree=$(repo_api "git/commits/$sha" --jq '.tree.sha')
    [[ "$parent_tree" =~ ^[0-9a-f]{40}$ ]]
    jq -n --arg tree "$parent_tree" --arg path "$PNPM_FRONTEND" --rawfile content "$task_tmp/updated.nix" \
        '{base_tree: $tree, tree: [{path: $path, mode: "100644", type: "blob", content: $content}]}' >"$task_tmp/tree.json"
    tree_sha=$(GH_TOKEN="$write_token" repo_api git/trees --method POST --input "$task_tmp/tree.json" --jq '.sha')
    [[ "$tree_sha" =~ ^[0-9a-f]{40}$ ]]
    jq -n --arg tree "$tree_sha" --arg parent "$sha" \
        '{message: "fix(nix): refresh GUI pnpm dependency hash [dependabot skip]", tree: $tree, parents: [$parent]}' >"$task_tmp/commit.json"
    commit_sha=$(GH_TOKEN="$write_token" repo_api git/commits --method POST --input "$task_tmp/commit.json" --jq '.sha')
    [[ "$commit_sha" =~ ^[0-9a-f]{40}$ ]]
    branch=$(jq -r '.head.ref' "$task_tmp/pr.json")
    jq -n --arg sha "$commit_sha" '{sha: $sha, force: false}' >"$task_tmp/ref.json"
    # Fast-forward only: a concurrent branch update cannot be overwritten.
    GH_TOKEN="$write_token" repo_api "git/refs/heads/$branch" --method PATCH --input "$task_tmp/ref.json" >/dev/null
    echo "Updated PR #$number: $commit_sha"
}

main() {
    local sha value
    set -euo pipefail
    umask 077
    task_tmp=$(mktemp -d)
    write_token=""
    trap cleanup EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
    case "${1:-}" in
    compute)
        sha=$(jq -er '.pull_request.head.sha | select(test("^[0-9a-f]{40}$"))' "$GITHUB_EVENT_PATH")
        value=$(read_pin "$PNPM_FRONTEND")
        jq -n --arg sha "$sha" \
            --arg hash "$value" '{sha: $sha, hash: $hash}' >"$2"
        ;;
    commit)
        repository="$GITHUB_REPOSITORY"
        [[ "$repository" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]]
        commit_hash
        ;;
    *) fail "Usage: $0 compute OUTPUT | commit" ;;
    esac
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
