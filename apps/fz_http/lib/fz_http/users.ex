defmodule FzHttp.Users do
  @moduledoc """
  The Users context.
  """

  import Ecto.Changeset
  import Ecto.Query, warn: false

  alias FzHttp.{Devices.Device, Mailer, Repo, Sites.Site, Telemetry, Users.User}

  require Logger

  # one hour
  @sign_in_token_validity_secs 3600

  def count do
    Repo.one(from u in User, select: count(u.id))
  end

  def count(role: role) do
    Repo.one(from u in User, select: count(u.id), where: u.role == ^role)
  end

  def consume_sign_in_token(token) when is_binary(token) do
    case find_and_clear_token(token) do
      {:ok, {:ok, user}} -> {:ok, user}
      {:ok, {:error, msg}} -> {:error, msg}
    end
  end

  def exists?(user_id) when is_nil(user_id) do
    false
  end

  def exists?(user_id) do
    Repo.exists?(from u in User, where: u.id == ^user_id)
  end

  def list_admins do
    Repo.all(from User, where: [role: :admin])
  end

  def get_user!(email: email) do
    Repo.get_by!(User, email: email)
  end

  def get_user!(id), do: Repo.get!(User, id)

  def get_user(id), do: Repo.get(User, id)

  def get_by_email(email) do
    Repo.get_by(User, email: email)
  end

  def create_admin_user(attrs) do
    create_user_with_role(attrs, :admin)
  end

  def create_unprivileged_user(attrs) do
    create_user_with_role(attrs, :unprivileged)
  end

  def create_user_with_role(attrs, role) do
    attrs
    |> Enum.into(%{})
    |> create_user(role: role)
  end

  def create_user(attrs, overwrites \\ []) do
    changeset =
      User
      |> struct(sign_in_keys())
      |> User.create_changeset(attrs)

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

  def sign_in_keys do
    %{
      sign_in_token: FzCommon.FzCrypto.rand_string(),
      sign_in_token_created_at: DateTime.utc_now()
    }
  end

  def admin_update_user(%User{} = user, attrs) do
    user
    |> User.update_email(attrs)
    |> User.update_password(attrs)
    |> Repo.update()
  end

  def admin_update_self(%User{} = user, attrs) do
    user
    |> User.update_email(attrs)
    |> User.update_password(attrs)
    |> User.require_current_password(attrs)
    |> Repo.update()
  end

  def unprivileged_update_self(%User{} = user, attrs) do
    user
    |> User.require_password_change(attrs)
    |> User.update_password(attrs)
    |> Repo.update()
  end

  def update_user_role(%User{} = user, role) do
    user
    |> User.update_role(%{role: role})
    |> Repo.update()
  end

  def update_user_sign_in_token(%User{} = user, attrs) do
    user
    |> User.update_sign_in_token(attrs)
    |> Repo.update()
  end

  def delete_user(%User{} = user) do
    Telemetry.delete_user()
    Repo.delete(user)
  end

  def change_user(%User{} = user \\ struct(User)) do
    change(user)
  end

  def new_user do
    change_user(%User{})
  end

  def list_users do
    Repo.all(User)
  end

  def as_settings do
    Repo.all(from u in User, select: %{id: u.id})
    |> Enum.map(&setting_projection/1)
    |> MapSet.new()
  end

  def setting_projection(user) do
    user.id
  end

  @doc """
  Fetches all users and groups into an Enumerable that can be used for an HTML form input.
  """
  def as_options_for_select do
    Repo.all(from u in User, select: {u.email, u.id})
  end

  def list_users(:with_device_counts) do
    query =
      from(
        user in User,
        left_join: device in Device,
        on: device.user_id == user.id,
        group_by: user.id,
        select_merge: %{device_count: count(device.id)}
      )

    Repo.all(query)
  end

  def update_last_signed_in(user, %{provider: provider} = _auth) do
    method =
      case provider do
        :identity -> "email"
        m -> to_string(m)
      end

    user
    |> User.update_last_signed_in(%{
      last_signed_in_at: DateTime.utc_now(),
      last_signed_in_method: method
    })
    |> Repo.update()
  end

  def enable_vpn_connection(user, %{provider: :identity}), do: user
  def enable_vpn_connection(user, %{provider: :magic_link}), do: user

  def enable_vpn_connection(user, %{provider: _oidc_provider}) do
    user
    |> change()
    |> put_change(:disabled_at, nil)
    |> Repo.update!()
  end

  @doc """
  Returns DateTime that VPN sessions expire based on last_signed_in_at
  and the security.require_auth_for_vpn_frequency setting.
  """
  def vpn_session_expires_at(user, duration) do
    DateTime.add(user.last_signed_in_at, duration)
  end

  def vpn_session_expired?(user, duration) do
    max = Site.max_vpn_session_duration()

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

  def reset_sign_in_token(email) do
    with %User{} = user <- Repo.get_by(User, email: email),
         {:ok, user} <- update_user_sign_in_token(user, sign_in_keys()) do
      Mailer.AuthEmail.magic_link(user) |> Mailer.deliver!()
      :ok
    else
      nil ->
        Logger.info("Attempt to reset password of non-existing email: #{email}")
        :ok

      {:error, _changeset} ->
        # failed to update user, something wrong internally
        Logger.error("Could not update user #{email} for magic link.")
        :error
    end
  end

  defp find_by_token(token) do
    validity_secs = -1 * @sign_in_token_validity_secs
    now = DateTime.utc_now()

    Repo.one(
      from(u in User,
        where:
          u.sign_in_token == ^token and
            u.sign_in_token_created_at > datetime_add(^now, ^validity_secs, "second")
      )
    )
  end

  defp find_and_clear_token(token) do
    Repo.transaction(fn ->
      case find_by_token(token) do
        nil -> {:error, "Token invalid."}
        user -> clear_token(user)
      end
    end)
  end

  defp clear_token(user) do
    result = update_user_sign_in_token(user, %{sign_in_token: nil, sign_in_token_created_at: nil})

    case result do
      {:ok, user} -> {:ok, user}
      _ -> {:error, "Unexpected error attempting to clear sign in token."}
    end
  end
end
