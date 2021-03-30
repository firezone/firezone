defmodule FgHttp.Users do
  @moduledoc """
  The Users context.
  """

  import Ecto.Query, warn: false
  alias FgHttp.Repo

  alias FgCommon.FgCrypto
  alias FgHttp.Users.User

  # one hour
  @sign_in_token_validity_secs 3600

  def consume_sign_in_token(token) when is_binary(token) do
    case find_token_transaction(token) do
      {:ok, {:ok, user}} -> {:ok, user}
      {:ok, {:error, msg}} -> {:error, msg}
    end
  end

  def get_user!(email: email) do
    Repo.get_by!(User, email: email)
  end

  def get_user!(id), do: Repo.get!(User, id)

  def create_user(attrs) when is_list(attrs) do
    attrs
    |> Enum.into(%{})
    |> create_user()
  end

  def create_user(attrs) when is_map(attrs) do
    struct(User, sign_in_keys())
    |> User.create_changeset(attrs)
    |> Repo.insert()
  end

  def sign_in_keys do
    %{
      sign_in_token: FgCrypto.rand_string(),
      sign_in_token_created_at: DateTime.utc_now()
    }
  end

  def update_user(%User{} = user, attrs) do
    user
    |> User.update_changeset(attrs)
    |> Repo.update()
  end

  def delete_user(%User{} = user) do
    Repo.delete(user)
  end

  def change_user(%User{} = user) do
    User.changeset(user, %{})
  end

  def new_user do
    change_user(%User{})
  end

  def single_user? do
    Repo.one(from u in User, select: count()) == 1
  end

  # XXX: For now assume first user is the admin.
  def admin do
    User |> first |> Repo.one()
  end

  def admin_email do
    case admin() do
      %User{} = user ->
        user.email

      _ ->
        nil
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

  defp find_token_transaction(token) do
    Repo.transaction(fn ->
      case find_by_token(token) do
        nil -> {:error, "Token invalid."}
        user -> token_update_fn(user)
      end
    end)
  end

  defp token_update_fn(user) do
    result =
      Repo.update_all(
        from(u in User, where: u.id == ^user.id),
        set: [sign_in_token: nil, sign_in_token_created_at: nil]
      )

    case result do
      {1, _result} -> {:ok, user}
      _ -> {:error, "Unexpected error attempting to clear sign in token."}
    end
  end
end
