#!/usr/bin/env bats

setup() {
  PATCHER="$BATS_TEST_DIRNAME/../../../rust/mise-tasks/patch-relay-release"
  BINARY="$BATS_TEST_TMPDIR/relay"
  # A stand-in binary: arbitrary bytes around the marker + 40-zero placeholder.
  printf 'HEADER\0firezone-git-sha:0000000000000000000000000000000000000000\0FOOTER' >"$BINARY"
}

@test "stamps the sha into the placeholder without changing the size" {
  local before after sha="1234567890abcdef1234567890abcdef12345678"
  before=$(wc -c <"$BINARY")

  run "$PATCHER" "$BINARY" "$sha"
  [ "$status" -eq 0 ]

  after=$(wc -c <"$BINARY")
  [ "$before" -eq "$after" ]
  grep -F -q "firezone-git-sha:$sha" "$BINARY"
  grep -F -q "FOOTER" "$BINARY"
}

@test "rejects a sha that is not 40 hex characters" {
  run "$PATCHER" "$BINARY" "tooshort"
  [ "$status" -ne 0 ]
  [[ "$output" == *"40-char"* ]]

  # 40 characters but not hex (would be >40 bytes if multibyte) must be rejected.
  run "$PATCHER" "$BINARY" "zzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzz"
  [ "$status" -ne 0 ]
}

@test "fails when the marker is missing" {
  printf 'no marker here' >"$BINARY"
  run "$PATCHER" "$BINARY" "1234567890abcdef1234567890abcdef12345678"
  [ "$status" -ne 0 ]
  [[ "$output" == *"exactly once"* ]]
}
