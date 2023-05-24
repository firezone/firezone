defmodule Domain.Auth.Adapters.UserPass.Password.Changeset do
  use Domain, :changeset
  alias Domain.Auth.Adapters.UserPass.Password

  @fields ~w[password]a
  @min_password_length 12
  @max_password_length 64

  def create_changeset(attrs) do
    changeset(%Password{}, attrs)
  end

  def changeset(struct, attrs) do
    struct
    |> cast(attrs, @fields)
    |> validate_required(@fields)
    |> validate_confirmation(:password, required: true)
    |> validate_length(:password, min: @min_password_length, max: @max_password_length)
    |> put_hash(:password, to: :password_hash)
    |> redact_field(:password)
    |> redact_field(:password_confirmation)
    |> validate_required([:password_hash])
  end
end
