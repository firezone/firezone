defmodule FzHttp.Rules do
  @moduledoc """
  The Rules context.
  """

  import Ecto.Query, warn: false
  alias EctoNetwork.INET

  alias FzHttp.{Repo, Rules.Rule, Telemetry}

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
      {:ok, rule} ->
        Telemetry.add_rule(rule)

      _ ->
        nil
    end

    result
  end

  def delete_rule(%Rule{} = rule) do
    Telemetry.delete_rule(rule)
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

  def nftables_spec(rule) do
    {decode(rule.destination), rule.action}
  end

  def to_nftables do
    Enum.map(nftables_query(), fn {dest, act} ->
      {decode(dest), act}
    end)
  end

  defp nftables_query do
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
