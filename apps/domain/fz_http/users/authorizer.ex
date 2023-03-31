defmodule FzHttp.Users.Authorizer do
  use FzHttp.Auth.Authorizer
  alias FzHttp.Users.User

  def manage_users_permission, do: build(User, :manage)
  def edit_own_profile_permission, do: build(User, :edit_own_profile)

  @impl FzHttp.Auth.Authorizer
  def list_permissions_for_role(:admin) do
    [
      manage_users_permission(),
      edit_own_profile_permission()
    ]
  end

  def list_permissions_for_role(:unprivileged) do
    [
      edit_own_profile_permission()
    ]
  end

  def list_permissions_for_role(_role) do
    []
  end

  @impl FzHttp.Auth.Authorizer
  def for_subject(queryable, %Subject{} = subject) when is_user(subject) do
    cond do
      has_permission?(subject, manage_users_permission()) ->
        queryable
    end
  end
end
