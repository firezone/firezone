defmodule FzHttp.Rules do
  @moduledoc """
  The Rules context.
  """

  import Ecto.Query, warn: false
  import Ecto.Changeset
  alias FzHttp.{Repo, Rules.Rule, Rules.RuleSetting, Telemetry}

  def port_rules_supported?, do: Application.fetch_env!(:fz_wall, :port_based_rules_supported)

  defp scope(port_based_rules) when port_based_rules == true do
    Rule
  end

  defp scope(port_based_rules) when port_based_rules == false do
    from r in Rule, where: is_nil(r.port_type)
  end

  def list_rules, do: Repo.all(Rule)

  def list_rules(user_id) do
    Repo.all(
      from r in Rule,
        where: r.user_id == ^user_id
    )
  end

  def as_settings do
    port_rules_supported?()
    |> scope()
    |> Repo.all()
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
      {:ok, _rule} ->
        Telemetry.add_rule()

      _ ->
        nil
    end

    result
  end

  def delete_rule(%Rule{} = rule) do
    Telemetry.delete_rule()
    Repo.delete(rule)
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
