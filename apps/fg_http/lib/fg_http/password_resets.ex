defmodule FgHttp.PasswordResets do
  @moduledoc """
  The PasswordResets context.
  """

  import Ecto.Query, warn: false
  alias FgHttp.Repo

  alias FgHttp.Users.PasswordReset

  @doc """
  Returns the list of password_resets.

  ## Examples

      iex> list_password_resets()
      [%PasswordReset{}, ...]

  """
  def list_password_resets do
    Repo.all(PasswordReset)
  end

  def load_user_from_valid_token!(token) when is_binary(token) do
    Repo.get_by!(
      PasswordReset,
      reset_token: token,
      consumed_at: nil,
      reset_sent_at: DateTime.utc_now() - PasswordReset.token_validity_secs()
    )
  end

  @doc """
  Gets a single password_reset.

  Raises `Ecto.NoResultsError` if the Password reset does not exist.

  ## Examples

      iex> get_password_reset!(123)
      %PasswordReset{}

      iex> get_password_reset!(456)
      ** (Ecto.NoResultsError)

  """
  def get_password_reset!(id), do: Repo.get!(PasswordReset, id)

  @doc """
  Creates a password_reset.

  ## Examples

      iex> create_password_reset(%{field: value})
      {:ok, %PasswordReset{}}

      iex> create_password_reset(%{field: bad_value})
      {:error, %Ecto.Changeset{}}

  """
  def create_password_reset(attrs \\ %{}) do
    %PasswordReset{}
    |> PasswordReset.create_changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Updates a password_reset.

  ## Examples

      iex> update_password_reset(password_reset, %{field: new_value})
      {:ok, %PasswordReset{}}

      iex> update_password_reset(password_reset, %{field: bad_value})
      {:error, %Ecto.Changeset{}}

  """
  def update_password_reset(%PasswordReset{} = password_reset, attrs) do
    password_reset
    |> PasswordReset.update_changeset(attrs)
    |> Repo.update()
  end

  @doc """
  Deletes a password_reset.

  ## Examples

      iex> delete_password_reset(password_reset)
      {:ok, %PasswordReset{}}

      iex> delete_password_reset(password_reset)
      {:error, %Ecto.Changeset{}}

  """
  def delete_password_reset(%PasswordReset{} = password_reset) do
    Repo.delete(password_reset)
  end

  @doc """
  Returns an `%Ecto.Changeset{}` for tracking password_reset changes.

  ## Examples

      iex> change_password_reset(password_reset)
      %Ecto.Changeset{data: %PasswordReset{}}

  """
  def change_password_reset(%PasswordReset{} = password_reset, attrs \\ %{}) do
    PasswordReset.changeset(password_reset, attrs)
  end
end
