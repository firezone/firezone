defmodule FgHttp.PasswordResets do
  @moduledoc """
  The PasswordResets context.
  """

  import Ecto.Query, warn: false
  alias FgHttp.Repo

  alias FgHttp.Users.PasswordReset

  @doc """
  Gets a single password_reset.

  Raises `Ecto.NoResultsError` if the Password reset does not exist.

  ## Examples

      iex> get_password_reset!(123)
      %PasswordReset{}

      iex> get_password_reset!(456)
      ** (Ecto.NoResultsError)

  """
  def get_password_reset!(email: email) do
    Repo.get_by(
      PasswordReset,
      email: email
    )
  end

  def get_password_reset!(reset_token: reset_token) do
    validity_secs = -1 * PasswordReset.token_validity_secs()
    now = DateTime.truncate(DateTime.utc_now(), :second)

    query =
      from p in PasswordReset,
        where:
          p.reset_token == ^reset_token and is_nil(p.reset_consumed_at) and
            p.reset_sent_at > datetime_add(^now, ^validity_secs, "second")

    Repo.one(query)
  end

  @doc """
  Updates a User with the password reset fields

  ## Examples

      iex> update_password_reset(%{field: value})
      {:ok, %PasswordReset{}}

      iex> update_password_reset(%{field: bad_value})
      {:error, %Ecto.Changeset{}}

  """
  def create_password_reset(%PasswordReset{} = record, attrs) do
    record
    |> PasswordReset.create_changeset(attrs)
    |> Repo.update()
  end
end
