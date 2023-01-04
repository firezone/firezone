defmodule FzHttp.Users do
  import Ecto.Changeset
  import Ecto.Query, warn: false
  alias FzHttp.Repo
  alias FzHttp.Validator
  alias FzHttp.Telemetry
  alias FzHttp.Users.User

  def count do
    User.Query.all()
    |> Repo.aggregate(:count)
  end

  def count_by_role(role) do
    User.Query.by_role(role)
    |> Repo.aggregate(:count)
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

  def fetch_user_by_id_or_email(id_or_email) do
    if Validator.valid_uuid?(id_or_email) do
      fetch_user_by_id(id_or_email)
    else
      fetch_user_by_email(id_or_email)
    end
  end

  def list_users(opts \\ []) do
    {hydrate, _opts} = Keyword.pop(opts, :hydrate, [])

    User.Query.all()
    |> hydrate_fields(hydrate)
    |> Repo.all()
  end

  defp hydrate_fields(queryable, []), do: queryable

  defp hydrate_fields(queryable, [:device_count | rest]) do
    queryable
    |> User.Query.hydrate_device_count()
    |> hydrate_fields(rest)
  end

  def create_admin_user(attrs) do
    create_user_with_role(attrs, :admin)
  end

  def create_unprivileged_user(attrs) do
    create_user_with_role(attrs, :unprivileged)
  end

  defp create_user_with_role(attrs, role) do
    attrs
    |> Enum.into(%{})
    |> create_user(role: role)
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
    if FzCommon.FzCrypto.equal?(token, user.sign_in_token_hash) do
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

  ####

  def create_user(attrs, overwrites \\ []) do
    changeset = User.Changeset.create_changeset(attrs)

    result =
      overwrites
      |> Enum.reduce(changeset, fn {k, v}, cs -> put_change(cs, k, v) end)
      |> Repo.insert()

    case result do
      {:ok, _user} ->
        Telemetry.add_user()

      _ ->
        nil
    end

    result
  end

  def admin_update_user(%User{} = user, attrs) do
    user
    |> User.Changeset.update_email(attrs)
    |> User.update_role(attrs)
    |> User.Changeset.update_password(attrs)
    |> Repo.update()
  end

  def admin_update_self(%User{} = user, attrs) do
    user
    |> User.Changeset.update_email(attrs)
    |> User.Changeset.update_password(attrs)
    |> User.Changeset.require_current_password(attrs)
    |> Repo.update()
  end

  def unprivileged_update_self(%User{} = user, attrs) do
    user
    |> User.Changeset.require_password_change(attrs)
    |> User.Changeset.update_password(attrs)
    |> Repo.update()
  end

  def update_user_role(%User{} = user, role) do
    user
    |> User.Changeset.update_role(%{role: role})
    |> Repo.update()
  end

  def delete_user(%User{} = user) do
    Telemetry.delete_user()
    Repo.delete(user)
  end

  def change_user(%User{} = user \\ %User{}) do
    change(user)
  end

  def as_settings do
    Repo.all(from u in User, select: %{id: u.id})
    |> Enum.map(&setting_projection/1)
    |> MapSet.new()
  end

  def setting_projection(user) do
    user.id
  end

  def update_last_signed_in(user, %{provider: provider} = _auth) do
    method =
      case provider do
        :identity -> "email"
        m -> to_string(m)
      end

    user
    |> User.Changeset.update_last_signed_in(%{
      last_signed_in_at: DateTime.utc_now(),
      last_signed_in_method: method
    })
    |> Repo.update()
  end

  @doc """
  Returns DateTime that VPN sessions expire based on last_signed_in_at
  and the security.require_auth_for_vpn_frequency setting.
  """
  def vpn_session_expires_at(user, duration) do
    DateTime.add(user.last_signed_in_at, duration)
  end

  def vpn_session_expired?(user, duration) do
    max = FzHttp.Configurations.Configuration.max_vpn_session_duration()

    case duration do
      0 ->
        false

      ^max ->
        is_nil(user.last_signed_in_at)

      _num ->
        is_nil(user.last_signed_in_at) ||
          DateTime.diff(vpn_session_expires_at(user, duration), DateTime.utc_now()) <= 0
    end
  end
end
