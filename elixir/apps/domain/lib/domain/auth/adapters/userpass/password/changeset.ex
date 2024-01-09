defmodule Domain.Auth.Adapters.UserPass.Password.Changeset do
  use Domain, :changeset
  alias Domain.Auth.Adapters.UserPass.Password

  @fields ~w[password password_confirmation]a
  @min_password_length 12
  @max_password_length 72

  def changeset(%Password{} = struct, attrs) do
    struct
    |> cast(attrs, @fields)
    |> validate_required(@fields)
    |> validate_confirmation(:password, required: true)
    |> validate_length(:password,
      min: @min_password_length,
      max: @max_password_length,
      count: :bytes
    )
    # We can improve password strength checks later if we decide to run this provider in production.
    # |> validate_format(:password, ~r/[a-z]/, message: "at least one lower case character")
    # |> validate_format(:password, ~r/[A-Z]/, message: "at least one upper case character")
    # |> validate_format(:password, ~r/[!?@#$%^&*_0-9]/, message: "at least one digit or punctuation character")
    # |> validate_no_repetitive_characters(:password)
    # |> validate_no_sequential_characters(:password)
    # |> validate_no_public_context(:password)
    |> put_hash(:password, :argon2, to: :password_hash)
    |> validate_required([:password_hash])
  end
end
