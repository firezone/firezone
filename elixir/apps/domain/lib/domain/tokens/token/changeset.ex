defmodule Domain.Tokens.Token.Changeset do
  use Domain, :changeset
  alias Domain.Auth
  alias Domain.Tokens.Token

  @required_attrs ~w[
    type
    account_id
    secret_fragment
    created_by_user_agent created_by_remote_ip
    expires_at
  ]a

  @create_attrs ~w[identity_id secret_nonce]a ++ @required_attrs
  @update_attrs ~w[expires_at]a

  def create(attrs) do
    %Token{}
    |> cast(attrs, @create_attrs)
    |> validate_required(@required_attrs)
    |> validate_inclusion(:type, [:email, :browser, :client])
    |> changeset()
    |> put_change(:created_by, :system)
  end

  def create(attrs, %Auth.Subject{} = subject) do
    %Token{}
    |> cast(attrs, @create_attrs)
    |> put_change(:account_id, subject.account.id)
    |> validate_required(@required_attrs)
    |> validate_inclusion(:type, [:client, :relay, :gateway, :api_client])
    |> changeset()
    |> put_change(:created_by, :identity)
    |> put_change(:created_by_identity_id, subject.identity.id)
  end

  defp changeset(changeset) do
    changeset
    |> put_change(:secret_salt, Domain.Crypto.random_token(16))
    |> validate_format(:secret_nonce, ~r/^[^\.]{0,128}$/)
    |> put_hash(:secret_fragment, :sha3_256,
      with_nonce: :secret_nonce,
      with_salt: :secret_salt,
      to: :secret_hash
    )
    |> delete_change(:secret_nonce)
    |> validate_datetime(:expires_at, greater_than: DateTime.utc_now())
    |> validate_required(~w[secret_salt secret_hash]a)
    |> validate_required_assocs()
    |> assoc_constraint(:account)
  end

  defp validate_required_assocs(changeset) do
    case fetch_field(changeset, :context) do
      {_data_or_changes, :browser} ->
        changeset
        |> validate_required(:identity_id)
        |> assoc_constraint(:identity)

      {_data_or_changes, :client} ->
        changeset
        |> validate_required(:identity_id)
        |> assoc_constraint(:identity)

      # TODO: relay, gateway, api_client

      _ ->
        changeset
    end
  end

  def update(%Token{} = token, attrs) do
    token
    |> cast(attrs, @update_attrs)
    |> validate_required(@update_attrs)
    |> validate_datetime(:expires_at, greater_than: DateTime.utc_now())
  end

  def use(%Token{} = token, %Auth.Context{} = context) do
    token
    |> change()
    |> put_change(:last_seen_user_agent, context.user_agent)
    |> put_change(:last_seen_remote_ip, %Postgrex.INET{address: context.remote_ip})
    |> put_change(:last_seen_remote_ip_location_region, context.remote_ip_location_region)
    |> put_change(:last_seen_remote_ip_location_city, context.remote_ip_location_city)
    |> put_change(:last_seen_remote_ip_location_lat, context.remote_ip_location_lat)
    |> put_change(:last_seen_remote_ip_location_lon, context.remote_ip_location_lon)
    |> put_change(:last_seen_at, DateTime.utc_now())
    |> validate_required(~w[last_seen_user_agent last_seen_remote_ip]a)
  end

  def delete(%Token{} = token) do
    token
    |> change()
    |> put_default_value(:deleted_at, DateTime.utc_now())
  end
end
