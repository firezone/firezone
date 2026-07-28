defmodule Credo.Check.Warning.MissingAccountIdInJoinTest do
  use ExUnit.Case, async: true

  alias Credo.Check.Warning.MissingAccountIdInJoin

  setup_all do
    Application.ensure_all_started(:credo)
    :ok
  end

  test "reports a piped join without an account_id condition" do
    issues =
      """
      query
      |> join(:left, [actors: actor], token in Portal.APIToken,
        on: token.actor_id == actor.id
      )
      """
      |> issues()

    assert [%{trigger: "join", line_no: 2}] = issues
  end

  test "allows a piped join with an account_id condition" do
    issues =
      """
      query
      |> join(:left, [actors: actor], token in Portal.APIToken,
        on: token.actor_id == actor.id and token.account_id == actor.account_id
      )
      """
      |> issues()

    assert issues == []
  end

  test "reports only unsafe joins in a from expression with multiple joins" do
    issues =
      """
      from(actor in Portal.Actor,
        join: token in Portal.APIToken,
        on: token.actor_id == actor.id and token.account_id == actor.account_id,
        left_join: identity in Portal.ExternalIdentity,
        on: identity.actor_id == actor.id
      )
      """
      |> issues()

    assert [%{trigger: "left_join", line_no: 4}] = issues
  end

  test "reports a join without an explicit on condition" do
    issues =
      """
      query
      |> join(:inner, [actors: actor], identity in assoc(actor, :identities))
      """
      |> issues()

    assert [%{trigger: "join", line_no: 2}] = issues
  end

  test "allows account association joins without an explicit on condition" do
    issues =
      """
      query
      |> join(:inner, [tokens: token], account in assoc(token, :account))
      """
      |> issues()

    assert issues == []
  end

  test "allows direct Portal.Account joins without an account_id condition" do
    issues =
      """
      from(directory in Portal.Directory,
        join: account in Portal.Account,
        on: account.id == directory.account_id
      )
      """
      |> issues()

    assert issues == []
  end

  test "allows a join scoped to a pinned account_id" do
    issues =
      """
      from(actor in Portal.Actor,
        join: identity in Portal.ExternalIdentity,
        on: identity.actor_id == actor.id and identity.account_id == ^account_id
      )
      """
      |> issues()

    assert issues == []
  end

  test "reports an intentional on true join so it must be explicitly suppressed" do
    issues =
      """
      from(row in fragment("SELECT 1"),
        left_join: lookup in "actor_lookup",
        on: true
      )
      """
      |> issues()

    assert [%{trigger: "left_join", line_no: 2}] = issues
  end

  test "supports qualified Ecto.Query calls" do
    issues =
      """
      Ecto.Query.join(
        query,
        :left,
        [actors: actor],
        token in Portal.APIToken,
        on: token.actor_id == actor.id
      )
      """
      |> issues()

    assert [%{trigger: "join", line_no: 1}] = issues
  end

  test "ignores unrelated join functions" do
    issues =
      """
      Enum.join(values, ",")
      join(values)
      """
      |> issues()

    assert issues == []
  end

  defp issues(source) do
    source
    |> Credo.SourceFile.parse("lib/portal/example.ex")
    |> MissingAccountIdInJoin.run()
  end
end
