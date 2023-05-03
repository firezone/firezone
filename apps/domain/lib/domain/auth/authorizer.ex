defmodule Domain.Auth.Authorizer do
  @moduledoc """
  Business contexts use authorization modules to define permissions that are supported by the context
  and expose them to the authorization system by implementing behaviour provided by this module.
  """

  defmacro __using__(_opts) do
    quote do
      import Domain.Auth.Authorizer, only: [build: 2, is_user: 1, is_api_token: 1]
      import Domain.Auth, only: [has_permission?: 2]
      alias Domain.Auth.Subject

      @behaviour Domain.Auth.Authorizer
    end
  end

  @doc """
  Returns list of all permissions defined by implementation module,
  which is used to simplify role management.
  """
  @callback list_permissions_for_role(Domain.Auth.Role.name()) :: [Domain.Auth.Permission.t()]

  @doc """
  Optional helper which allows to filter queryable based on subject permissions.
  """
  @callback for_subject(Ecto.Queryable.t(), Domain.Auth.Subject.t()) :: Ecto.Queryable.t()

  @optional_callbacks for_subject: 2

  def build(resource, action) do
    %Domain.Auth.Permission{resource: resource, action: action}
  end

  defguard is_user(subject)
           when is_struct(subject, Domain.Auth.Subject) and
                  subject.actor.type == :user

  defguard is_api_token(subject)
           when is_struct(subject, Domain.Auth.Subject) and
                  subject.actor.type == :api_token

  # TODO: is this the best place for this?
  def manage_providers_permission, do: build(Domain.Auth.Provider, :manage)

  def list_permissions_for_role(:admin) do
    [
      manage_providers_permission()
    ]
  end

  def list_permissions_for_role(_role) do
    []
  end

  def for_subject(queryable, %Domain.Auth.Subject{} = subject) when is_user(subject) do
    cond do
      Domain.Auth.has_permission?(subject, manage_providers_permission()) ->
        Domain.Auth.Provider.Query.by_account_id(queryable, subject.account.id)
    end
  end
end
