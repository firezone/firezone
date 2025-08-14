defmodule Domain.Relays.Authorizer do
  use Domain.Auth.Authorizer
  alias Domain.Relays.{Group, Relay}

  def manage_relays_permission, do: build(Relay, :manage)

  @impl Domain.Auth.Authorizer

  def list_permissions_for_role(:account_admin_user) do
    [
      manage_relays_permission()
    ]
  end

  def list_permissions_for_role(_) do
    []
  end

  def ensure_has_access_to(%Group{} = group, %Subject{} = subject) do
    # Allow access to global relay groups or account-specific groups
    if group.account_id == subject.account.id or is_nil(group.account_id) do
      Domain.Auth.ensure_has_permissions(subject, manage_relays_permission())
    else
      {:error, :unauthorized}
    end
  end

  def ensure_has_access_to(%Relay{} = relay, %Subject{} = subject) do
    # Allow access to global relays or account-specific relays
    if relay.account_id == subject.account.id or is_nil(relay.account_id) do
      Domain.Auth.ensure_has_permissions(subject, manage_relays_permission())
    else
      {:error, :unauthorized}
    end
  end

  @impl Domain.Auth.Authorizer
  def for_subject(queryable, %Subject{} = subject) do
    cond do
      has_permission?(subject, manage_relays_permission()) ->
        by_account_id(queryable, subject)
    end
  end

  defp by_account_id(queryable, subject) do
    cond do
      Ecto.Query.has_named_binding?(queryable, :groups) ->
        Group.Query.global_or_by_account_id(queryable, subject.account.id)

      Ecto.Query.has_named_binding?(queryable, :relays) ->
        Relay.Query.global_or_by_account_id(queryable, subject.account.id)
    end
  end
end
