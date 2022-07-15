defmodule FzHttp.Rules do
  @moduledoc """
  The Rules context.
  """

  import Ecto.Query, warn: false
  import FzHttp.Devices, only: [decode: 1]

  alias FzHttp.{Repo, Rules.Rule, Telemetry}

  def list_rules, do: Repo.all(Rule)

  def overlap(%{user_id: user_id, action: action, destination: destination}) do
    query =
      from r in Rule,
        where: r.user_id == ^user_id and r.action == ^action

    overlap_find(query, destination)
  end

  def overlap(%{action: action, destination: destination}) do
    query =
      from r in Rule,
        where: is_nil(r.user_id) and r.action == ^action

    overlap_find(query, destination)
  end

  defp overlap_find(query, destination) do
    Repo.all(query)
    |> Enum.find(fn rule ->
      existing_rule = CIDR.parse(decode(rule.destination))
      incoming_rule = CIDR.parse(decode(destination))

      CIDR.subnet?(existing_rule, incoming_rule) ||
        CIDR.subnet?(incoming_rule, existing_rule)
    end)
  end

  def list_rules(user_id) do
    Repo.all(
      from r in Rule,
        where: r.user_id == ^user_id
    )
  end

  def as_settings do
    Repo.all(
      from r in Rule, select: %{destination: r.destination, user_id: r.user_id, action: r.action}
    )
    |> Enum.map(&setting_projection/1)
    |> MapSet.new()
  end

  def setting_projection(rule) do
    %{destination: decode(rule.destination), user_id: rule.user_id, action: rule.action}
  end

  def count(user_id) do
    Repo.one(from r in Rule, where: r.user_id == ^user_id, select: count())
  end

  def get_rule!(id), do: Repo.get!(Rule, id)

  def new_rule(attrs \\ %{}) do
    %Rule{}
    |> Rule.changeset(attrs)
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
