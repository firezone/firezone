#!/usr/bin/env bats

setup() {
    SCRIPT="$BATS_TEST_DIRNAME/../../nix/pr-pnpm-hash.sh"
    # shellcheck source=/dev/null
    source "$SCRIPT"
    task_tmp="$BATS_TEST_TMPDIR/task"
    mkdir -p "$task_tmp"
    repository=firezone/firezone
    export MOCK_DIR="$BATS_TEST_TMPDIR/mock"
    mkdir -p "$MOCK_DIR/bin"
    export GITHUB_REPOSITORY="$repository" GITHUB_EVENT_PATH="$MOCK_DIR/event.json"
    export GH_TOKEN=read-token NIX_HASH_BOT_TOKEN=write-token
    export MOCK_OPENSSL
    MOCK_OPENSSL=$(command -v openssl)
    export SHA=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
    export BASE_SHA=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
    export TREE_SHA=cccccccccccccccccccccccccccccccccccccccc
    export COMMIT_SHA=dddddddddddddddddddddddddddddddddddddddd
    HASH="sha256-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="
    NEW_HASH="sha256-a6jhWUZxTStTOQraSD88uVS5Mq72NdN1xnzVB1mtjk8="
    printf 'hash = "%s";\n' "$HASH" >"$MOCK_DIR/frontend.nix"
    cp "$MOCK_DIR/frontend.nix" "$MOCK_DIR/base.nix"
    jq -n --arg sha "$SHA" --arg base "$BASE_SHA" '
        {number: 123, state: "open", user: {login: "dependabot[bot]"},
         head: {sha: $sha, ref: "dependabot/npm_and_yarn/gui-update", repo: {full_name: "firezone/firezone"}},
         base: {sha: $base, ref: "main", repo: {full_name: "firezone/firezone"}}}
    ' >"$MOCK_DIR/pr.json"
    jq -n --arg sha "$SHA" --arg path "$PNPM_WORKFLOW" '
        {event: "pull_request", conclusion: "success", workflow_id: 1, path: $path,
         head_sha: $sha, head_branch: "dependabot/npm_and_yarn/gui-update",
         head_repository: {full_name: "firezone/firezone"}}
    ' >"$task_tmp/run.json"
    cp "$task_tmp/run.json" "$MOCK_DIR/run.json"
    printf '%s\n' '{"workflow_run":{"id":42}}' >"$GITHUB_EVENT_PATH"
    make_artifact "$NEW_HASH" "$SHA"
    cat >"$MOCK_DIR/bin/gh" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
shift # api
shift 2 # --hostname github.com
endpoint="$1"
shift
query=""
input=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --jq) query="$2"; shift 2 ;;
        --input) input="$2"; shift 2 ;;
        --method) shift 2 ;;
        *) shift ;;
    esac
done
printf '%s %s\n' "$endpoint" "$GH_TOKEN" >> "$MOCK_DIR/calls"
result() {
    if [[ -n "$query" ]]; then
        jq -r "$query"
    else
        cat
    fi
}
case "$endpoint" in
    repos/firezone/firezone/actions/runs/42) result < "$MOCK_DIR/run.json" ;;
    repos/firezone/firezone/actions/workflows/1)
        printf '%s' '{"path":".github/workflows/pr-nix-pnpm.yml"}' | result ;;
    repos/firezone/firezone/commits/"$SHA"/pulls)
        jq '[[.]]' "$MOCK_DIR/pr.json" | result ;;
    repos/firezone/firezone/pulls/123)
        if [[ -f "$MOCK_DIR/pr-read" && -n "${LATEST_SHA:-}" ]]; then
            jq --arg sha "$LATEST_SHA" '.head.sha = $sha' "$MOCK_DIR/pr.json" | result
        else
            touch "$MOCK_DIR/pr-read"
            result < "$MOCK_DIR/pr.json"
        fi ;;
    repos/firezone/firezone/pulls/123/files) jq '[.]' "$MOCK_DIR/files.json" | result ;;
    repos/firezone/firezone/contents/*)
        file="$MOCK_DIR/frontend.nix"
        [[ "$endpoint" != *"ref=$BASE_SHA" ]] || file="$MOCK_DIR/base.nix"
        content=$("$MOCK_OPENSSL" base64 -A < "$file")
        jq -n --arg content "$content" '{type: "file", encoding: "base64", size: 100, content: $content}' | result ;;
    repos/firezone/firezone/actions/runs/42/artifacts\?per_page=100)
        printf '%s' '{"artifacts":[{"name":"pr-pnpm-hash","expired":false,"size_in_bytes":300,"id":9}]}' | result ;;
    repos/firezone/firezone/actions/artifacts/9/zip) cat "$MOCK_DIR/artifact.zip" ;;
    repos/firezone/firezone/git/commits/"$SHA")
        jq -n --arg sha "$TREE_SHA" '{tree:{sha:$sha}}' | result ;;
    repos/firezone/firezone/git/trees)
        cp "$input" "$MOCK_DIR/tree.json"
        jq -n --arg sha "$TREE_SHA" '{sha:$sha}' | result ;;
    repos/firezone/firezone/git/commits)
        cp "$input" "$MOCK_DIR/commit.json"
        jq -n --arg sha "$COMMIT_SHA" '{sha:$sha}' | result ;;
    repos/firezone/firezone/git/refs/heads/*)
        cp "$input" "$MOCK_DIR/ref.json"
        [[ "${REF_FAILURE:-false}" != true ]] || exit 1
        printf '{}' | result ;;
    installation/token) ;;
    *) echo "Unexpected API call: $endpoint" >&2; exit 1 ;;
esac
MOCK
    chmod +x "$MOCK_DIR/bin/gh"
    export PATH="$MOCK_DIR/bin:$PATH"
}

make_artifact() {
    jq -n --arg hash "$1" --arg sha "$2" '{hash:$hash,sha:$sha}' >"$MOCK_DIR/hash.json"
}

edit_json() {
    jq "$2" "$1" >"$task_tmp/edit.json"
    mv "$task_tmp/edit.json" "$1"
}

@test "accepts an open same-repository PR with the computed head" {
    run validate_pr "$MOCK_DIR/pr.json"
    [ "$status" -eq 0 ]
    for change in '.head.sha="stale"' '.head.repo.full_name="attacker/fork"' '.base.ref="release"' '.head.ref="main"' '.head.ref="dependabot/branch#fragment"' '.state="closed"'; do
        cp "$MOCK_DIR/pr.json" "$task_tmp/pr.json"
        edit_json "$task_tmp/pr.json" "$change"
        run validate_pr "$task_tmp/pr.json"
        [ "$status" -eq 1 ]
    done
}

@test "replaces only a unique hash assignment" {
    printf '# Comment\nhash = "%s";\nother = true;\n' "$HASH" >"$task_tmp/frontend.nix"
    replace_pin "$task_tmp/frontend.nix" "$NEW_HASH" >"$task_tmp/updated.nix"
    replace_pin "$task_tmp/updated.nix" "$HASH" >"$task_tmp/restored.nix"
    cmp "$task_tmp/frontend.nix" "$task_tmp/restored.nix"
    cat "$task_tmp/frontend.nix" >>"$task_tmp/restored.nix"
    run replace_pin "$task_tmp/restored.nix" "$NEW_HASH"
    [ "$status" -eq 1 ]
}

@test "artifact rejects a stale commit, extra fields and hash injection" {
    run read_artifact "$MOCK_DIR/hash.json" "$SHA"
    [ "$status" -eq 0 ]
    [ "$output" = "$NEW_HASH" ]
    for change in '.sha="stale"' '.branch="main"' '.hash += "\nrun evil"' '.hash=1'; do
        make_artifact "$NEW_HASH" "$SHA"
        edit_json "$MOCK_DIR/hash.json" "$change"
        run read_artifact "$MOCK_DIR/hash.json" "$SHA"
        [ "$status" -eq 1 ]
    done
}

@test "artifact rejects oversized payloads and symlinks" {
    head -c 2048 /dev/zero >"$MOCK_DIR/hash.json"
    run read_artifact "$MOCK_DIR/hash.json" "$SHA"
    [ "$status" -eq 1 ]
    make_artifact "$NEW_HASH" "$SHA"
    ln -s "$MOCK_DIR/hash.json" "$MOCK_DIR/link.json"
    run read_artifact "$MOCK_DIR/link.json" "$SHA"
    [ "$status" -eq 1 ]
}

@test "writer commits only the hash, uses the existing bot token, and never force pushes" {
    run bash "$SCRIPT" commit "$MOCK_DIR/hash.json"
    [ "$status" -eq 0 ]
    jq -e --arg path "$PNPM_FRONTEND" --arg hash "$NEW_HASH" \
        '.tree | length == 1 and .[0].path == $path and .[0].content == ("hash = \"" + $hash + "\";\n")' "$MOCK_DIR/tree.json"
    jq -e --arg sha "$SHA" '.parents == [$sha] and (.message | contains("[dependabot skip]"))' "$MOCK_DIR/commit.json"
    jq -e --arg sha "$COMMIT_SHA" '.force == false and .sha == $sha' "$MOCK_DIR/ref.json"
    grep -q 'git/trees write-token$' "$MOCK_DIR/calls"
}

@test "regular PRs retain frontend code edits and update only their hash" {
    edit_json "$MOCK_DIR/pr.json" '.user.login="developer" | .head.ref="feature/frontend"'
    edit_json "$MOCK_DIR/run.json" '.head_branch="feature/frontend"'
    printf 'other = true;\n' >>"$MOCK_DIR/frontend.nix"
    run bash "$SCRIPT" commit "$MOCK_DIR/hash.json"
    [ "$status" -eq 0 ]
    jq -e --arg hash "$NEW_HASH" '.tree[0].content == ("hash = \"" + $hash + "\";\nother = true;\n")' "$MOCK_DIR/tree.json"
}

@test "writer rejects a different source workflow before obtaining write credentials" {
    edit_json "$MOCK_DIR/run.json" '.path=".github/workflows/evil.yml"'
    run bash "$SCRIPT" commit "$MOCK_DIR/hash.json"
    [ "$status" -ne 0 ]
    run grep -q 'write-token' "$MOCK_DIR/calls"
    [ "$status" -eq 1 ]
}

@test "correct hash does not use write credentials" {
    make_artifact "$HASH" "$SHA"
    run bash "$SCRIPT" commit "$MOCK_DIR/hash.json"
    [ "$status" -eq 0 ]
    [[ "$output" == *"Hash already correct"* ]]
    run grep -q 'write-token' "$MOCK_DIR/calls"
    [ "$status" -eq 1 ]
}

@test "PR changed after validation is not written" {
    export LATEST_SHA=eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee
    run bash "$SCRIPT" commit "$MOCK_DIR/hash.json"
    [ "$status" -ne 0 ]
    run grep -q 'git/trees' "$MOCK_DIR/calls"
    [ "$status" -eq 1 ]
    run grep -q 'installation/token' "$MOCK_DIR/calls"
    [ "$status" -eq 1 ]
}

@test "rejected fast-forward update is not retried with force" {
    export REF_FAILURE=true
    run bash "$SCRIPT" commit "$MOCK_DIR/hash.json"
    [ "$status" -ne 0 ]
    jq -e '.force == false' "$MOCK_DIR/ref.json"
    run grep -q 'installation/token' "$MOCK_DIR/calls"
    [ "$status" -eq 1 ]
}

@test "compute emits only the head and hash and rejects an ambiguous pin" {
    mkdir -p "$MOCK_DIR/repo/$(dirname "$PNPM_FRONTEND")"
    cp "$MOCK_DIR/frontend.nix" "$MOCK_DIR/repo/$PNPM_FRONTEND"
    jq -n --arg sha "$SHA" '{pull_request:{head:{sha:$sha}}}' >"$GITHUB_EVENT_PATH"
    cd "$MOCK_DIR/repo" || return
    run bash "$SCRIPT" compute "$MOCK_DIR/computed.json"
    [ "$status" -eq 0 ]
    jq -e --arg sha "$SHA" --arg hash "$HASH" '. == {sha:$sha,hash:$hash}' "$MOCK_DIR/computed.json"
    cat "$MOCK_DIR/frontend.nix" >>"$PNPM_FRONTEND"
    run bash "$SCRIPT" compute "$MOCK_DIR/computed.json"
    [ "$status" -ne 0 ]
}

@test "writer rejects invalid artifact data before obtaining write credentials" {
    make_artifact "$NEW_HASH" stale
    run bash "$SCRIPT" commit "$MOCK_DIR/hash.json"
    [ "$status" -ne 0 ]
    run grep -q 'write-token' "$MOCK_DIR/calls"
    [ "$status" -eq 1 ]
}

@test "writer never updates the default branch even if the run names it" {
    edit_json "$MOCK_DIR/pr.json" '.head.ref="main"'
    edit_json "$MOCK_DIR/run.json" '.head_branch="main"'
    run bash "$SCRIPT" commit "$MOCK_DIR/hash.json"
    [ "$status" -ne 0 ]
    run grep -q 'write-token' "$MOCK_DIR/calls"
    [ "$status" -eq 1 ]
}
