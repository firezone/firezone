defmodule Domain.Users.User.Changeset do
  use Domain, :changeset
  alias Domain.{Accounts, Auth}
  alias Domain.Users

  @min_password_length 12
  @max_password_length 64

  def create_changeset(%Accounts.Account{} = account, role, attrs) when is_atom(role) do
    %Users.User{}
    |> cast(attrs, ~w[
      email
      password
      password_confirmation
    ]a)
    |> put_change(:role, role)
    |> put_change(:account_id, account.id)
    |> change_email_changeset()
    |> validate_if_changed(:password, &change_password_changeset/1)
  end

  def update_user_password(user, attrs) do
    user
    |> cast(attrs, [:password])
    |> validate_if_changed(:password, &change_password_changeset/1)
  end

  def update_user_email(user, attrs) do
    user
    |> cast(attrs, [:email])
    |> validate_if_changed(:email, &change_email_changeset/1)
  end

  def update_user_role(user, attrs, %Auth.Subject{actor: {:user, subject_user}}) do
    update_user_role(user, attrs)
    |> validate_if_changed(:role, fn changeset ->
      if subject_user.id == fetch_field!(changeset, :id) do
        add_error(changeset, :role, "You cannot change your own role")
      else
        changeset
      end
    end)
  end

  def update_user_role(user, attrs) do
    user
    |> cast(attrs, [:role])
    |> validate_required([:role])
  end

  def disable_user(user) do
    user
    |> change()
    |> put_default_value(:disabled_at, DateTime.utc_now())
  end

  defp change_email_changeset(%Ecto.Changeset{} = changeset) do
    changeset
    |> trim_change(:email)
    |> validate_required([:email, :role])
    |> validate_email(:email)
    |> unique_constraint(:email)
  end

  defp change_password_changeset(%Ecto.Changeset{} = changeset) do
    changeset
    |> validate_required([:password])
    |> validate_confirmation(:password, required: true)
    |> validate_length(:password, min: @min_password_length, max: @max_password_length)
    |> put_hash(:password, to: :password_hash)
    |> redact_field(:password)
    |> redact_field(:password_confirmation)
    |> validate_required([:password_hash])
  end

  def generate_sign_in_token(%Users.User{} = user) do
    user
    |> change()
    |> put_change(:sign_in_token, Domain.Crypto.rand_string())
    |> put_hash(:sign_in_token, to: :sign_in_token_hash)
    |> put_change(:sign_in_token_created_at, DateTime.utc_now())
  end

  def update_last_signed_in(user, attrs) do
    cast(user, attrs, [:last_signed_in_method, :last_signed_in_at])
  end
end
