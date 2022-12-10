defmodule FzHttp.AllowRules do
  @moduledoc """
  The AllowRules context.
  """

  import Ecto.Query, warn: false
  alias FzHttp.{AllowRules.AllowRule, Gateways.Gateway, Repo, Users.User}

  def create_allow_rule(attrs \\ %{}) do
    %AllowRule{}
    |> AllowRule.changeset(attrs)
    |> Repo.insert()
  end

  def update_allow_rule(%AllowRule{} = allow_rule, attrs) do
    allow_rule
    |> AllowRule.changeset(attrs)
    |> Repo.update()
  end

  def delete_allow_rule(%AllowRule{} = allow_rule) do
    allow_rule
    |> Repo.delete()
  end

  def get_allow_rule!(id), do: Repo.get!(AllowRule, id)

  def list_allow_rules, do: Repo.all(AllowRule)

  def list_allow_rules(%Gateway{} = gateway) do
    Repo.all(from r in AllowRule, where: r.gateway_id == ^gateway.id)
  end

  def list_allow_rules(%User{} = user) do
    Repo.all(from r in AllowRule, where: r.user_id == ^user.uuid)
  end
end
