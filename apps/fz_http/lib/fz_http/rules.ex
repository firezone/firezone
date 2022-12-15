defmodule FzHttp.Rules do
  @moduledoc """
  The Rules context.
  """

  import Ecto.Query, warn: false
  import Ecto.Changeset
  alias FzHttp.{Repo, Rules.Rule, Rules.RuleSetting, Telemetry, Events}

  def list_rules, do: Repo.all(Rule)

  def list_rules(user_id) do
    Repo.all(
      from r in Rule,
        where: r.user_id == ^user_id
    )
  end

  def as_settings do
    Repo.all(Rule)
    |> Enum.map(&setting_projection/1)
    |> MapSet.new()
  end

  def setting_projection(rule) do
    RuleSetting.parse(rule)
    |> Map.from_struct()
  end

  def count(user_id) do
    Repo.one(from r in Rule, where: r.user_id == ^user_id, select: count())
  end

  def get_rule!(id), do: Repo.get!(Rule, id)

  def new_rule(attrs \\ %{}) do
    %Rule{}
    |> Rule.changeset(attrs)
  end

  def defaults(changeset) do
    %{port_type: get_field(changeset, :port_type)}
  end

  def defaults do
    defaults(new_rule())
  end

  def create_rule(attrs \\ %{}) do
    result =
      attrs
      |> new_rule()
      |> Repo.insert()

    case result do
      {:ok, rule} ->
        Events.add("rules", rule)
        Telemetry.add_rule()

      _ ->
        nil
    end

    result
  end

  def project_rule(rule) do
    user_uuid = Repo.preload(rule, :user).user.uuid

    %{
      dst: rule.destination,
      user_uuid: user_uuid
    }
  end

  def update_rule(%Rule{} = rule, attrs \\ %{}) do
    rule
    |> Rule.changeset(attrs)
    |> Repo.update()
  end

  def delete_rule(%Rule{} = rule) do
    case Repo.delete(rule) do
      {:ok, rule} ->
        Events.delete("rules", rule)
        Telemetry.delete_rule()

      _ ->
        nil
    end
  end

  def allowlist do
    Repo.all(
      from r in Rule,
        where: r.action == :accept
    )
  end

  def denylist do
    Repo.all(
      from r in Rule,
        where: r.action == :drop
    )
  end
end
