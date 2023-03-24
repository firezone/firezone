# TODO: add subjects
defmodule FzHttp.Auth.MFA do
  alias FzHttp.{Repo, Validator}
  alias FzHttp.Users
  alias FzHttp.Auth.MFA.Method

  def count_users_with_mfa_enabled do
    Method.Query.select_distinct_user_ids_count()
    |> Repo.one()
  end

  def count_users_with_totp_method do
    Method.Query.select_distinct_user_ids_count()
    |> Method.Query.by_type(:totp)
    |> Repo.one()
  end

  def fetch_method_by_id(id) do
    if Validator.valid_uuid?(id) do
      Method.Query.by_id(id)
      |> Repo.fetch()
    else
      {:error, :not_found}
    end
  end

  def fetch_last_used_method_by_user_id(user_id) do
    if Validator.valid_uuid?(user_id) do
      Method.Query.by_user_id(user_id)
      |> Method.Query.order_by_last_usage()
      |> Method.Query.with_limit(1)
      |> Repo.fetch()
    else
      {:error, :not_found}
    end
  end

  def list_methods_for_user(%Users.User{id: user_id}) do
    Method.Query.by_user_id(user_id)
    |> Method.Query.order_by_last_usage()
    |> Repo.list()
  end

  def create_method_changeset(attrs \\ %{}, user_id) do
    Method.Changeset.create_changeset(user_id, attrs)
  end

  def create_method(attrs, user_id) do
    create_method_changeset(attrs, user_id)
    |> Repo.insert()
  end

  def use_method_changeset(method, attrs \\ %{}) do
    Method.Changeset.use_code_changeset(method, attrs)
  end

  def use_method(%Method{} = method, attrs) do
    use_method_changeset(method, attrs)
    |> Repo.update()
  end

  def delete_method_by_id(method_id, %Users.User{} = user) do
    with {:ok, method} <- fetch_method_by_id(method_id),
         # A user can only delete his/her own MFA method!
         true <- method.user_id == user.id do
      {:ok, Repo.delete!(method)}
    else
      {:error, :not_found} -> {:error, :not_found}
      false -> {:error, :not_found}
    end
  end
end
