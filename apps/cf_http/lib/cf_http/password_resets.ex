defmodule CfHttp.PasswordResets do
  @moduledoc """
  The PasswordResets context.
  """

  import Ecto.Query, warn: false
  alias CfHttp.Repo

  alias CfHttp.Users.PasswordReset

  def get_password_reset(email: email) do
    Repo.get_by(PasswordReset, email: email)
  end

  def get_password_reset(reset_token: reset_token) do
    query_by_token(reset_token)
    |> Repo.one()
  end

  def get_password_reset!(email: email) do
    Repo.get_by!(PasswordReset, email: email)
  end

  def get_password_reset!(reset_token: reset_token) do
    query_by_token(reset_token)
    |> Repo.one!()
  end

  defp query_by_token(reset_token) do
    validity_secs = -1 * PasswordReset.token_validity_secs()
    now = DateTime.utc_now()

    from p in PasswordReset,
      where:
        p.reset_token == ^reset_token and
          p.reset_sent_at > datetime_add(^now, ^validity_secs, "second")
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

  def new_password_reset do
    PasswordReset.changeset()
  end

  def edit_password_reset(%PasswordReset{} = password_reset) do
    password_reset
    |> PasswordReset.changeset()
  end
end
