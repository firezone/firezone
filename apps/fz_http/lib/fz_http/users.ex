defmodule FzHttp.Users do
  @moduledoc """
  The Users context.
  """

  import Ecto.Query, warn: false

  alias FzCommon.{FzCrypto, FzMap}
  alias FzHttp.{Devices.Device, Mailer, Repo, Sites.Site, Telemetry, Users.User}

  require Logger

  # one hour
  @sign_in_token_validity_secs 3600

  def count do
    Repo.one(from u in User, select: count(u.id))
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

  def create_user_with_role(attrs, role) when is_map(attrs) do
    attrs
    |> Map.put(:role, role)
    |> create_user()
  end

  def create_user_with_role(attrs, role) when is_list(attrs) do
    attrs
    |> Map.new()
    |> Map.put(:role, role)
    |> create_user()
  end

  def create_user(attrs) when is_map(attrs) do
    result =
      struct(User, sign_in_keys())
      |> User.create_changeset(attrs)
      |> Repo.insert()

    case result do
      {:ok, user} -> Telemetry.add_user(user)
      _ -> nil
    end

    result
  end

  def sign_in_keys do
    %{
      sign_in_token: FzCrypto.rand_string(),
      sign_in_token_created_at: DateTime.utc_now()
    }
  end

  def update_user(%User{} = user, attrs) do
    user
    |> User.update_changeset(attrs)
    |> Repo.update()
  end

  def delete_user(%User{} = user) do
    Telemetry.delete_user(user)
    Repo.delete(user)
  end

  def change_user(%User{} = user \\ struct(User)) do
    User.changeset(user, %{})
  end

  def new_user do
    change_user(%User{})
  end

  def list_users do
    Repo.all(User)
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

    update_user(user, %{last_signed_in_at: DateTime.utc_now(), last_signed_in_method: method})
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
         {:ok, user} <- update_user(user, sign_in_keys()) do
      # send email in a separate process so that the time this function takes
      # doesn't reflect whether a user exists or not
      Task.start(fn ->
        # blow up if it failed, it won't affect the request handling process.
        # we want it to blow up so that it leaves something in the logs.
        Mailer.AuthEmail.magic_link(user) |> Mailer.deliver!()
      end)

      :ok
    else
      nil ->
        # no user was found, we don't act any differently
        Logger.info("Attempt to reset password of non-existing email: #{email}")
        :ok

      {:error, _changeset} ->
        # failed to update user, something wrong internally
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
    result = update_user(user, %{sign_in_token: nil, sign_in_token_created_at: nil})

    case result do
      {:ok, user} -> {:ok, user}
      _ -> {:error, "Unexpected error attempting to clear sign in token."}
    end
  end
end
