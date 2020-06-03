defmodule FgHttp.PasswordResets do
  @moduledoc """
  The PasswordResets context.
  """

  import Ecto.Query, warn: false
  alias FgHttp.Repo

  alias FgHttp.Users.PasswordReset

  def get_password_reset!(email: email) do
    Repo.get_by(
      PasswordReset,
      email: email
    )
  end

  def get_password_reset!(reset_token: reset_token) do
    validity_secs = -1 * PasswordReset.token_validity_secs()
    now = DateTime.utc_now()

    query =
      from p in PasswordReset,
        where:
          p.reset_token == ^reset_token and
            p.reset_sent_at > datetime_add(^now, ^validity_secs, "second")

    Repo.one(query)
  end

  def create_password_reset(%PasswordReset{} = record, attrs) do
    record
    |> PasswordReset.create_changeset(attrs)
    |> Repo.update()
  end

  def update_password_reset(%PasswordReset{} = record, attrs) do
    record
    |> PasswordReset.update_changeset(attrs)
    |> Repo.update()
  end
end
