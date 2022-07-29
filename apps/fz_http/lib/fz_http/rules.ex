defmodule FzHttp.Rules do
  @moduledoc """
  The Rules context.
  """

  import Ecto.Query, warn: false
  import FzHttp.Devices, only: [decode: 1]

  alias FzHttp.{Repo, Rules.Rule, Telemetry}

  def list_rules, do: Repo.all(Rule)

  def list_rules(user_id) do
    Repo.all(
      from r in Rule,
        where: r.user_id == ^user_id
    )
  end

  def as_settings do
    Repo.all(
      from r in Rule,
        select: %{
          destination: r.destination,
          user_id: r.user_id,
          action: r.action,
          port_range: r.port_range,
          port_type: r.port_type
        }
    )
    |> Enum.map(&setting_projection/1)
    |> MapSet.new()
  end

  def setting_projection(rule) do
    %{
      destination: decode(rule.destination),
      user_id: rule.user_id,
      action: rule.action,
      port_range: rule.port_range,
      port_type: rule.port_type
    }
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
      |> range_from_params()
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

  defp range_from_params(%{"port_start" => "", "port_stop" => ""} = attrs) do
    attrs
  end

  defp range_from_params(%{"port_start" => port_start, "port_stop" => port_stop} = attrs) do
    Map.put_new(attrs, "port_range", [to_num(port_start), to_num(port_stop)])
  end

  defp range_from_params(attrs) do
    attrs
  end

  defp to_num(nil), do: nil
  defp to_num(""), do: nil

  defp to_num(port) when is_binary(port) do
    {port, _} = Integer.parse(port)
    port
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
