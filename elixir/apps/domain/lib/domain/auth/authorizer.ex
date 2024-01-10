defmodule Domain.Auth.Authorizer do
  @moduledoc """
  Business contexts use authorization modules to define permissions that are supported by the context
  and expose them to the authorization system by implementing behaviour provided by this module.
  """
  alias Domain.Auth

  defmacro __using__(_opts) do
    quote do
      import Domain.Auth.Authorizer, only: [build: 2]
      import Domain.Auth, only: [has_permission?: 2]
      alias Domain.Auth.Subject

      @behaviour Domain.Auth.Authorizer
    end
  end

  @doc """
  Returns list of all permissions defined by implementation module,
  which is used to simplify role management.
  """
  @callback list_permissions_for_role(Auth.Role.name()) :: [Auth.Permission.t()]

  @doc """
  Optional helper which allows to filter queryable based on subject permissions.
  """
  @callback for_subject(Ecto.Queryable.t(), Auth.Subject.t()) :: Ecto.Queryable.t()

  @optional_callbacks for_subject: 2

  def build(resource, action) do
    %Auth.Permission{resource: resource, action: action}
  end

  # TODO: is this the best place for this?
  def manage_providers_permission, do: build(Auth.Provider, :manage)
  def manage_identities_permission, do: build(Auth.Identity, :manage)
  def manage_service_accounts_permission, do: build(Auth, :manage_service_accounts)
  def manage_own_identities_permission, do: build(Auth.Identity, :manage_own)

  def list_permissions_for_role(:account_admin_user) do
    [
      manage_providers_permission(),
      manage_service_accounts_permission(),
      manage_own_identities_permission(),
      manage_identities_permission()
    ]
  end

  def list_permissions_for_role(:account_user) do
    [
      manage_own_identities_permission()
    ]
  end

  def list_permissions_for_role(_role) do
    []
  end

  def for_subject(queryable, Auth.Identity, %Auth.Subject{} = subject) do
    cond do
      Auth.has_permission?(subject, manage_identities_permission()) ->
        Auth.Identity.Query.by_account_id(queryable, subject.account.id)

      Auth.has_permission?(subject, manage_own_identities_permission()) ->
        queryable
        |> Auth.Identity.Query.by_account_id(subject.account.id)
        |> Auth.Identity.Query.by_actor_id(subject.actor.id)
    end
  end

  def for_subject(queryable, Auth.Provider, %Auth.Subject{} = subject) do
    cond do
      Auth.has_permission?(subject, manage_providers_permission()) ->
        Auth.Provider.Query.by_account_id(queryable, subject.account.id)
    end
  end
end
