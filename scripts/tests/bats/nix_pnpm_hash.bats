#!/usr/bin/env bats

setup() {
  REPO="$BATS_TEST_TMPDIR/repo"
  mkdir -p "$REPO/scripts/nix/packages/firezone-gui-client" "$REPO/bin"
  git init -q "$REPO"
  cp "$BATS_TEST_DIRNAME/../../nix/update-pnpm-hash.sh" "$REPO/check.sh"
  FRONTEND="$REPO/scripts/nix/packages/firezone-gui-client/frontend.nix"
  HASH="sha256-ksdIUZNZJHFTo4pZUZXKzF6qv6LEpBXG0Yi+9Jks/HY="
  printf 'hash = "%s";\n' "$HASH" > "$FRONTEND"
  cp "$FRONTEND" "$REPO/original"
  cat > "$REPO/bin/nix" <<'MOCK'
#!/usr/bin/env bash
if [[ "$*" == 'eval --impure --raw --expr builtins.currentSystem' ]]; then
  printf '%s' "${MOCK_SYSTEM:-x86_64-linux}"
  exit 0
fi
[[ "$*" == "build .#checks.${MOCK_SYSTEM:-x86_64-linux}.pnpm-deps --no-link --print-build-logs" ]] || exit 2
grep -q 'sha256-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=' scripts/nix/packages/firezone-gui-client/frontend.nix || exit 2
if [[ -n "${GOT_HASH:-}" ]]; then
  echo "error: hash mismatch in fixed-output derivation 'pnpm-deps'" >&2
  echo "         got:    $GOT_HASH" >&2
else
  echo "error: network failure" >&2
fi
exit 1
MOCK
  chmod +x "$REPO/bin/nix"
  export PATH="$REPO/bin:$PATH"
  cd "$REPO" || return
}

@test "check accepts a correct pin and restores the file" {
  export GOT_HASH="$HASH"
  run bash check.sh --check
  [ "$status" -eq 0 ]
  cmp "$FRONTEND" original
}

@test "check rejects a stale pin and restores the file" {
  export GOT_HASH="sha256-a6jhWUZxTStTOQraSD88uVS5Mq72NdN1xnzVB1mtjk8="
  run bash check.sh --check
  [ "$status" -eq 1 ]
  [[ "$output" == *"hash is stale"* ]]
  cmp "$FRONTEND" original
}

@test "fetch errors fail closed and restore the file" {
  unset GOT_HASH
  run bash check.sh --check
  [ "$status" -eq 1 ]
  [[ "$output" == *"network failure"* ]]
  cmp "$FRONTEND" original
}

@test "update commits the computed pin to the file" {
  export GOT_HASH="sha256-a6jhWUZxTStTOQraSD88uVS5Mq72NdN1xnzVB1mtjk8="
  run bash check.sh
  [ "$status" -eq 0 ]
  grep -F -q "$GOT_HASH" "$FRONTEND"
}

@test "check uses the native ARM Linux system" {
  export GOT_HASH="$HASH" MOCK_SYSTEM=aarch64-linux
  run bash check.sh --check
  [ "$status" -eq 0 ]
  cmp "$FRONTEND" original
}
