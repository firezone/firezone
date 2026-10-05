#!/usr/bin/env bats

@test "Dependabot pnpm hash writer rejects untrusted inputs and limits writes" {
  run python3 "$BATS_TEST_DIRNAME/../../nix/tests/test_dependabot_pnpm_hash.py"
  [ "$status" -eq 0 ]
}
