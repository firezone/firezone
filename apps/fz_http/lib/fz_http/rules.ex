defmodule FzHttp.Rules do
  @moduledoc """
  The Rules context.
  """

  import Ecto.Query, warn: false
  alias EctoNetwork.INET

  alias FzHttp.{Repo, Rules.Rule}

  def get_rule!(id), do: Repo.get!(Rule, id)

  def new_rule(attrs \\ %{}) do
    %Rule{}
    |> Rule.changeset(attrs)
  end

  def create_rule(attrs \\ %{}) do
    attrs
    |> new_rule()
    |> Repo.insert()
  end

  def delete_rule(%Rule{} = rule) do
    Repo.delete(rule)
  end

  def allowlist do
    Repo.all(
      from r in Rule,
        where: r.action == :allow
    )
  end

  def denylist do
    Repo.all(
      from r in Rule,
        where: r.action == :deny
    )
  end

  def iptables_spec(rule) do
    {decode(rule.destination), rule.action}
  end

  def to_iptables do
    Enum.map(iptables_query(), fn {dest, act} ->
      {decode(dest), act}
    end)
  end

  defp iptables_query do
    query =
      from r in Rule,
        order_by: r.action,
        select: {
          r.destination,
          r.action
        }

    Repo.all(query)
  end

  defp decode(nil), do: nil
  defp decode(inet), do: INET.decode(inet)
end
