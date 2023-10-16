defmodule Domain.Tokens.Token.Changeset do
  use Domain, :changeset
  alias Domain.{Auth, Accounts}
  alias Domain.Tokens.Token

  @create_attrs ~w[context secret user_agent remote_ip expires_at]a
  @required_attrs @create_attrs

  def create(%Accounts.Account{} = account, attrs) do
    %Token{}
    |> cast(attrs, @create_attrs)
    |> validate_required(@required_attrs)
    |> validate_inclusion(:context, [:email])
    |> changeset()
    |> put_change(:account_id, account.id)
    |> put_change(:created_by, :system)
  end

  def create(%Accounts.Account{} = account, attrs, %Auth.Subject{} = subject) do
    %Token{}
    |> cast(attrs, @create_attrs)
    |> validate_required(@required_attrs)
    |> validate_inclusion(:context, [:browser, :client, :relay, :gateway, :api_client])
    |> changeset()
    |> put_change(:account_id, account.id)
    |> put_change(:created_by, :identity)
    |> put_change(:created_by_identity_id, subject.identity.id)
  end

  defp changeset(changeset) do
    changeset
    |> put_change(:secret_salt, Domain.Crypto.random_token(16))
    |> put_hash(:secret, :sha, with_salt: :secret_salt, to: :secret_hash)
    |> validate_datetime(:expires_at, greater_than: DateTime.utc_now())
    |> validate_required(~w[secret_salt secret_hash]a)
  end

  def refresh(%Token{} = token, attrs) do
    token
    |> cast(attrs, ~w[expires_at]a)
    |> validate_required(~w[expires_at]a)
    |> validate_datetime(:expires_at, greater_than: DateTime.utc_now())
  end

  def delete(%Token{} = token) do
    token
    |> change()
    |> put_default_value(:deleted_at, DateTime.utc_now())
  end
end
