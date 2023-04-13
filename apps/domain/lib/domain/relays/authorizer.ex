defmodule Domain.Relays.Authorizer do
  use Domain.Auth.Authorizer
  alias Domain.Relays.Relay

  def manage_relays_permission, do: build(Relay, :manage)

  @impl Domain.Auth.Authorizer

  def list_permissions_for_role(:admin) do
    [
      manage_relays_permission()
    ]
  end

  def list_permissions_for_role(_) do
    []
  end

  @impl Domain.Auth.Authorizer
  def for_subject(queryable, %Subject{} = subject) when is_user(subject) do
    cond do
      has_permission?(subject, manage_relays_permission()) ->
        Relay.Query.by_account_id(subject.account.id)
    end
  end
end
