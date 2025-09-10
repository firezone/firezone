defmodule Domain.Entra.Authorizer do
  use Domain.Auth.Authorizer
  alias Domain.Entra

  def manage_directories_permission, do: build(Entra.Directory, :manage)
  def manage_group_inclusions_permission, do: build(Entra.GroupInclusion, :manage)

  @impl Domain.Auth.Authorizer

  def list_permissions_for_role(:account_admin_user) do
    [
      manage_directories_permission(),
      manage_group_inclusions_permission()
    ]
  end

  def list_permissions_for_role(_) do
    []
  end

  @impl Domain.Auth.Authorizer

  def for_subject(queryable, %Subject{} = subject) do
    if has_permission?(subject, manage_directories_permission()) do
      by_account_id(queryable, subject)
    end
  end

  defp by_account_id(queryable, subject) do
    cond do
      Ecto.Query.has_named_binding?(queryable, :directories) ->
        Entra.Directory.Query.by_account_id(queryable, subject.account.id)

      Ecto.Query.has_named_binding?(queryable, :group_inclusions) ->
        Entra.GroupInclusion.Query.by_account_id(queryable, subject.account.id)

      true ->
        queryable
    end
  end
end
