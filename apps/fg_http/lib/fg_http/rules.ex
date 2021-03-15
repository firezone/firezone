defmodule FgHttp.Rules do
  @moduledoc """
  The Rules context.
  """

  import Ecto.Query, warn: false
  alias FgHttp.Repo

  alias FgHttp.{Devices.Device, Rules.Rule}

  def get_rule!(id), do: Repo.get!(Rule, id)

  def create_rule(attrs \\ %{}) do
    %Rule{}
    |> Rule.changeset(attrs)
    |> Repo.insert()
  end

  def update_rule(%Rule{} = rule, attrs) do
    rule
    |> Rule.changeset(attrs)
    |> Repo.update()
  end

  def delete_rule(%Rule{} = rule) do
    Repo.delete(rule)
  end

  def change_rule(%Rule{} = rule) do
    Rule.changeset(rule, %{})
  end

  def to_iptables do
    query =
      from d in Device,
        join: r in Rule,
        on: r.device_id == d.id,
        where: r.enabled == true,
        # "deny" enum is indexed 0
        order_by: r.action,
        select: {
          # Need to select both ipv4 and ipv6 since we don't know which the
          # corresponding rule is.
          {d.interface_address4, d.interface_address6},
          r.destination,
          r.action
        }

    Repo.all(query)
  end
end
