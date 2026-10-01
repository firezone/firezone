#!/usr/bin/env bats

setup() {
    repo_root="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
    fixture="$BATS_TEST_TMPDIR/repo"
    mkdir -p "$fixture/mise-tasks/elixir" "$fixture/elixir"
    cp "$repo_root/mise-tasks/elixir/dead-code.sh" "$fixture/mise-tasks/elixir/"
    cd "$fixture" || return
    git init -q
    task="$fixture/mise-tasks/elixir/dead-code.sh"
    baseline="$fixture/elixir/dead-code-exceptions.json"
}

@test "records uncalled names once per file, including clauses, specs, and punctuation" {
    cat >elixir/example.ex <<'EOF'
defmodule Example do
  @spec unused?(term()) :: boolean()
  def unused?(nil), do: false
  def unused?(_), do: true
  def unused!(value), do: value
  def used(value), do: value
end
EOF
    printf 'Example.used(1)\n' >caller.txt
    git add .
    run "$task"
    [ "$status" -eq 0 ]
    [ "$(jq -c 'map(.name)' "$baseline")" = '["unused!","unused?"]' ]
    # The committed baseline must not count as a caller of its own exceptions.
    git add .
    run "$task" --check
    [ "$status" -eq 0 ]
}

@test "fails for a new violation and does not update the baseline in check mode" {
    printf 'def unused(), do: :ok\n' >elixir/example.exs
    git add .
    "$task"
    cp "$baseline" before.json
    printf 'def another(), do: :ok\n' >>elixir/example.exs
    run "$task" --check
    [ "$status" -eq 1 ]
    [[ "$output" == *"Elixir dead code violation."* ]]
    [[ "$output" == *"mise run //:elixir:dead-code"* ]]
    cmp before.json "$baseline"
    "$task"
    run "$task" --check
    [ "$status" -eq 0 ]
}

@test "fails when an exception gains a caller outside Elixir or is deleted" {
    printf 'def unused(), do: :ok\n' >elixir/example.ex
    git add .
    "$task"
    mkdir -p rel
    printf 'Example.unused()\n' >rel/start.sh
    git add .
    run "$task" --check
    [ "$status" -eq 1 ]
    rm rel/start.sh
    printf '\n' >elixir/example.ex
    run "$task" --check
    [ "$status" -eq 1 ]
}

@test "counts captures, atoms, templates, and exact predicate names as references" {
    cat >elixir/example.ex <<'EOF'
def captured(), do: :ok
def dynamic(), do: :ok
def component(assigns), do: assigns
def ready?(), do: true
def ready(), do: :ok
EOF
    cat >elixir/caller.exs <<'EOF'
&Example.captured/0
apply(Example, :dynamic, [])
Example.ready?()
EOF
    printf '<.component />\n' >elixir/page.html.heex
    git add .
    "$task"
    [ "$(jq -c 'map(.name)' "$baseline")" = '["ready"]' ]
}

@test "handles an empty inventory and ignores untracked source files" {
    printf 'def unused(), do: :ok\n' >elixir/untracked.ex
    git add mise-tasks
    "$task"
    [ "$(jq -c . "$baseline")" = '[]' ]
    run "$task" --check
    [ "$status" -eq 0 ]
}

@test "tracks exceptions per file and recognizes delegates as references" {
    printf 'def unused(), do: :ok\ndef delegated(), do: :ok\n' >elixir/first.ex
    printf 'def unused(), do: :ok\ndefdelegate delegated(), to: Example\n' >elixir/second.ex
    git add .
    "$task"
    [ "$(jq -c 'map(.file)' "$baseline")" = '["elixir/first.ex","elixir/second.ex"]' ]
    [ "$(jq -c 'map(.name)' "$baseline")" = '["unused","unused"]' ]
}
