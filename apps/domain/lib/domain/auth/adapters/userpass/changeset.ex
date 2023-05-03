defmodule Domain.Auth.Adapters.UserPass.Changeset do
  # @min_password_length 12
  # @max_password_length 64

  # defp change_password_changeset(%Ecto.Changeset{} = changeset) do
  #   changeset
  #   |> validate_required([:password])
  #   |> validate_confirmation(:password, required: true)
  #   |> validate_length(:password, min: @min_password_length, max: @max_password_length)
  #   |> put_hash(:password, to: :password_hash)
  #   |> redact_field(:password)
  #   |> redact_field(:password_confirmation)
  #   |> validate_required([:password_hash])
  # end
end
