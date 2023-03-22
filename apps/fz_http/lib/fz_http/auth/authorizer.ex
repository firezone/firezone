defmodule FzHttp.Auth.Authorizer do
  @moduledoc """
  Business contexts use authorization modules to define permissions that are supported by the context
  and expose them to the authorization system by implementing behaviour provided by this module.
  """

  defmacro __using__(_opts) do
    quote do
      import FzHttp.Auth.Authorizer
      import FzHttp.Auth, only: [has_permission?: 2]
      alias FzHttp.Auth.Subject

      @behaviour FzHttp.Auth.Authorizer
    end
  end

  @doc """
  Returns list of all permissions defined by implementation module,
  which is used to simplify role management.
  """
  @callback list_permissions_for_role(FzHttp.Auth.Role.name()) :: [FzHttp.Auth.Permission.t()]

  @doc """
  Optional helper which allows to filter queryable based on subject permissions.
  """
  @callback for_subject(Ecto.Queryable.t(), FzHttp.Auth.Subject.t()) :: Ecto.Queryable.t()

  @optional_callbacks for_subject: 2

  def build(resource, action) do
    %FzHttp.Auth.Permission{resource: resource, action: action}
  end

  defguard is_user(subject)
           when is_struct(subject, FzHttp.Auth.Subject) and
                  elem(subject.actor, 0) == :user

  defguard is_api_token(subject)
           when is_struct(subject, FzHttp.Auth.Subject) and
                  elem(subject.actor, 0) == :api_token
end
