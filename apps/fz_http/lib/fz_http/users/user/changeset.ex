defmodule FzHttp.Users.User.Changeset do
  use FzHttp, :changeset
  alias FzHttp.Users

  @min_password_length 12
  @max_password_length 64

  def create_changeset(attrs) do
    %Users.User{}
    |> cast(attrs, ~w[
      email
      password
      password_confirmation
    ]a)
    |> trim_change(:email)
    |> validate_required([:email])
    |> validate_email(:email)
    |> unique_constraint(:email)
    |> set_password_changeset()
  end

  defp set_password_changeset(%Ecto.Changeset{} = changeset) do
    with {:ok, _value} <- fetch_change(changeset, :password) do
      changeset
      |> validate_confirmation(:password, required: true)
      |> validate_length(:password, min: @min_password_length, max: @max_password_length)
      |> put_hash(:password, to: :password_hash)
      |> redact_field(:password)
      |> redact_field(:password_confirmation)
      |> validate_required([:password_hash])
    else
      :error -> changeset
    end
  end

  def generate_sign_in_token(%Users.User{} = user) do
    user
    |> change()
    |> put_change(:sign_in_token, FzCommon.FzCrypto.rand_string())
    |> put_hash(:sign_in_token, to: :sign_in_token_hash)
    |> put_change(:sign_in_token_created_at, DateTime.utc_now())
  end

  ####

  def require_current_password(user, attrs) do
    user
    |> cast(attrs, [:current_password])
    |> validate_required([:current_password])
    |> verify_current_password()
  end

  def update_password(user, attrs) do
    user
    |> cast(attrs, [:password, :password_confirmation])
    |> then(fn
      %{changes: %{password: _}} = changeset ->
        validate_length(changeset, :password, min: @min_password_length, max: @max_password_length)

      changeset ->
        changeset
    end)
    |> validate_confirmation(:password)
    |> put_hash(:password, to: :password_hash)
    |> delete_change(:password)
    |> delete_change(:password_confirmation)
    |> validate_required([:password_hash])
  end

  def require_password_change(user, attrs) do
    user
    |> cast(attrs, [:password, :password_confirmation])
    |> validate_required([:password, :password_confirmation])
  end

  def update_email(user, attrs) do
    user
    |> cast(attrs, [:email])
    |> trim_change(:email)
    |> validate_required([:email])
    |> validate_format(:email, ~r/@/)
  end

  def update_role(user, attrs) do
    user
    |> cast(attrs, [:role])
    |> validate_required([:role])
  end

  def update_last_signed_in(user, attrs) do
    cast(user, attrs, [:last_signed_in_method, :last_signed_in_at])
  end

  defp verify_current_password(
         %Ecto.Changeset{
           data: %{password_hash: password_hash},
           changes: %{current_password: current_password}
         } = changeset
       ) do
    if Argon2.verify_pass(current_password, password_hash) do
      delete_change(changeset, :current_password)
    else
      add_error(changeset, :current_password, "invalid password")
    end
  end

  defp verify_current_password(changeset), do: changeset
end
