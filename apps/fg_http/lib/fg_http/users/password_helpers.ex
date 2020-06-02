defmodule FgHttp.Users.PasswordHelpers do
  @moduledoc """
  Helpers for validating changesets with passwords
  """

  import Ecto.Changeset

  def validate_password_equality(%Ecto.Changeset{valid?: true} = changeset) do
    password = changeset.changes[:password]
    password_confirmation = changeset.changes[:password_confirmation]

    if password != password_confirmation do
      add_error(changeset, :password, "does not match password confirmation.")
    else
      changeset
    end
  end

  def validate_password_equality(changeset), do: changeset

  def put_password_hash(
        %Ecto.Changeset{
          valid?: true,
          changes: %{password: password}
        } = changeset
      ) do
    changeset
    |> change(password_hash: Argon2.hash_pwd_salt(password))
    |> delete_change(:password)
    |> delete_change(:password_confirmation)
  end

  def put_password_hash(changeset) do
    changeset
    |> delete_change(:password)
    |> delete_change(:password_confirmation)
  end
end
