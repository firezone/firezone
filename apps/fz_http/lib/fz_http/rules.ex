defmodule FzHttp.Rules do
  @moduledoc """
  The Rules context.
  """

  import Ecto.Query, warn: false
  alias EctoNetwork.INET

  alias FzHttp.{Devices, Repo, Rules, Rules.Rule, Telemetry, Users}

  def list_rules, do: Repo.all(Rule)

  def list_rules(user_id) do
    Repo.all(
      from r in Rule,
        where: r.user_id == ^user_id
    )
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

  def device_projection(device) do
    %{ip: decode(device.ipv4), ip6: decode(device.ipv6), user_id: device.user_id}
  end

  def rule_projection(rule) do
    %{destination: decode(rule.destination), user_id: rule.user_id, action: rule.action}
  end

  def user_projection(user) do
    user.id
  end

  def to_settings do
    # Would prefer the query to do the projection in `select`
    # but it doesn't seem to be supported with Ecto DSL
    {
      project_users(Users.list_users()),
      project_devices(Devices.list_devices()),
      project_rules(Rules.list_rules())
    }
  end

  defp project_users(users) do
    Enum.map(users, fn user -> user_projection(user) end)
    |> MapSet.new()
  end

  defp project_devices(devices) do
    Enum.map(devices, fn device -> device_projection(device) end)
    |> MapSet.new()
  end

  defp project_rules(rules) do
    Enum.map(rules, fn rule -> rule_projection(rule) end)
    |> MapSet.new()
  end

  def decode(nil), do: nil
  def decode(inet), do: INET.decode(inet)
end
