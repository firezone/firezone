defmodule FzHttp.Users do
  alias FzHttp.{Repo, Auth, Validator, Config, Telemetry}
  alias FzHttp.Users.{Authorizer, User}
  require Ecto.Query

  def count do
    User.Query.all()
    |> Repo.aggregate(:count)
  end

  def fetch_count_by_role(role, %Auth.Subject{} = subject) do
    with :ok <- Auth.ensure_has_permissions(subject, Authorizer.manage_users_permission()) do
      User.Query.by_role(role)
      |> Authorizer.for_subject(subject)
      |> Repo.aggregate(:count)
    end
  end

  def fetch_user_by_id(id, %Auth.Subject{} = subject) do
    with :ok <- Auth.ensure_has_permissions(subject, Authorizer.manage_users_permission()) do
      fetch_user_by_id(id)
    end
  end

  def fetch_user_by_id(id) do
    if Validator.valid_uuid?(id) do
      User.Query.by_id(id)
      |> Repo.fetch()
    else
      {:error, :not_found}
    end
  end

  def fetch_user_by_id!(id) do
    User.Query.by_id(id)
    |> Repo.fetch!()
  end

  def fetch_user_by_email(email) do
    User.Query.by_email(email)
    |> Repo.fetch()
  end

  def fetch_user_by_id_or_email(id_or_email, %Auth.Subject{} = subject) do
    with :ok <- Auth.ensure_has_permissions(subject, Authorizer.manage_users_permission()) do
      if Validator.valid_uuid?(id_or_email) do
        fetch_user_by_id(id_or_email)
      else
        fetch_user_by_email(id_or_email)
      end
    end
  end

  def list_users(%Auth.Subject{} = subject, opts \\ []) do
    with :ok <- Auth.ensure_has_permissions(subject, Authorizer.manage_users_permission()) do
      {hydrate, _opts} = Keyword.pop(opts, :hydrate, [])

      User.Query.all()
      |> hydrate_fields(hydrate)
      |> Repo.list()
    end
  end

  defp hydrate_fields(queryable, []), do: queryable

  defp hydrate_fields(queryable, [:device_count | rest]) do
    queryable
    |> User.Query.hydrate_device_count()
    |> hydrate_fields(rest)
  end

  def request_sign_in_token(%User{} = user) do
    user
    |> User.Changeset.generate_sign_in_token()
    |> Repo.update()
  end

  def consume_sign_in_token(%User{sign_in_token_hash: nil}, _token) do
    {:error, :no_token}
  end

  def consume_sign_in_token(%User{} = user, token) when is_binary(token) do
    if FzHttp.Crypto.equal?(token, user.sign_in_token_hash) do
      User.Query.by_id(user.id)
      |> User.Query.where_sign_in_token_is_not_expired()
      |> Ecto.Query.update(set: [sign_in_token_hash: nil, sign_in_token_created_at: nil])
      |> Ecto.Query.select([users: users], users)
      |> Repo.update_all([])
      |> case do
        {1, [user]} -> {:ok, user}
        {0, []} -> {:error, :token_expired}
      end
    else
      {:error, :invalid_token}
    end
  end

  def create_user(role, attrs, %Auth.Subject{} = subject) do
    with :ok <- Auth.ensure_has_permissions(subject, Authorizer.manage_users_permission()),
         changeset = User.Changeset.create_changeset(role, attrs),
         {:ok, user} <- Repo.insert(changeset) do
      Telemetry.add_user()
      {:ok, user}
    end
  end

  def change_user(%User{} = user \\ %User{}) do
    Ecto.Changeset.change(user)
  end

  def update_user(%User{} = user, attrs, %Auth.Subject{} = subject) do
    with :ok <- Auth.ensure_has_permissions(subject, Authorizer.manage_users_permission()) do
      user
      |> User.Changeset.update_user_role(attrs)
      |> User.Changeset.update_user_email(attrs)
      |> User.Changeset.update_user_password(attrs)
      |> User.Changeset.update_user_role(attrs)
      |> Repo.update()
    end
  end

  def update_self(attrs, %Auth.Subject{actor: {:user, %User{} = user}} = subject) do
    with :ok <- Auth.ensure_has_permissions(subject, Authorizer.edit_own_profile_permission()) do
      user
      |> User.Changeset.update_user_password(attrs)
      |> Repo.update()
    end
  end

  def delete_user(%User{} = user, %Auth.Subject{} = subject) do
    with :ok <- Auth.ensure_has_permissions(subject, Authorizer.manage_users_permission()) do
      Telemetry.delete_user()
      Repo.delete(user)
    end
  end

  def setting_projection(user) do
    user.id
  end

  def as_settings do
    User.Query.select_id_map()
    |> Repo.all()
    |> Enum.map(&setting_projection/1)
    |> MapSet.new()
  end

  def update_last_signed_in(user, %{provider: provider}) do
    method =
      case provider do
        :identity -> "email"
        other -> to_string(other)
      end

    user
    |> User.Changeset.update_last_signed_in(%{
      last_signed_in_at: DateTime.utc_now(),
      last_signed_in_method: method
    })
    |> Repo.update()
  end

  def vpn_session_expires_at(user) do
    DateTime.add(user.last_signed_in_at, Config.fetch_config!(:vpn_session_duration))
  end

  def vpn_session_expired?(user) do
    cond do
      is_nil(user.last_signed_in_at) ->
        false

      not Config.vpn_sessions_expire?() ->
        false

      true ->
        DateTime.diff(vpn_session_expires_at(user), DateTime.utc_now()) <= 0
    end
  end
end
