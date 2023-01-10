defmodule FzHttp.AllowRules do
  @moduledoc """
  The AllowRules context.
  """

  import Ecto.Query, warn: false
  alias FzHttp.{AllowRules.AllowRule, Gateways.Gateway, Repo, Users.User, Events, Telemetry}

  def create_allow_rule(attrs \\ %{}) do
    with {:ok, allow_rule} <-
           %AllowRule{}
           |> AllowRule.changeset(attrs)
           |> Repo.insert() do
      Events.add(allow_rule)
      Telemetry.add_rule()
      {:ok, allow_rule}
    end
  end

  def as_setting(rule) do
    user_uuid = with %User{} = user <- Repo.preload(rule, :user).user, do: user.uuid

    %{
      dst: rule.destination,
      user_uuid: user_uuid,
      port_range: add_port_settings(rule)
    }
  end

  defp add_port_settings(%{
         port_range_start: range_start,
         port_range_end: range_end,
         protocol: protocol
       })
       when range_start != nil do
    %{
      range_start: range_start,
      range_end: range_end,
      protocol: protocol
    }
  end

  defp add_port_settings(_), do: nil

  def delete_allow_rule(%AllowRule{} = allow_rule) do
    with {:ok, allow_rule} <- Repo.delete(allow_rule) do
      Events.delete(allow_rule)
      Telemetry.delete_rule()
      {:ok, allow_rule}
    end
  end

  def new_rule(attrs \\ %{}) do
    %AllowRule{}
    |> AllowRule.changeset(attrs)
  end

  def get_allow_rule!(id), do: Repo.get!(AllowRule, id)

  def list_allow_rules, do: Repo.all(AllowRule)

  def list_allow_rules(%Gateway{} = gateway) do
    Repo.all(from(r in AllowRule, where: r.gateway_id == ^gateway.id))
  end

  def list_allow_rules(%User{} = user) do
    Repo.all(user_query(user.uuid))
  end

  def count do
    Repo.aggregate(AllowRule, :count)
  end

  defp user_query(user_uuid) do
    from(r in AllowRule, where: r.user_id == ^user_uuid)
  end

  def count_by_user_id(user_uuid) do
    Repo.aggregate(user_query(user_uuid), :count)
  end
end
