defmodule Domain.AuthProvider do
  use Domain, :schema

  @provider_types %{
    "google" => Domain.Google.AuthProvider,
    "okta" => Domain.Okta.AuthProvider,
    "entra" => Domain.Entra.AuthProvider,
    "oidc" => Domain.OIDC.AuthProvider,
    "email_otp" => Domain.EmailOTP.AuthProvider,
    "userpass" => Domain.Userpass.AuthProvider
  }

  @primary_key false
  schema "auth_providers" do
    belongs_to :account, Domain.Account, primary_key: true
    field :id, :binary_id, primary_key: true
    field :type, Ecto.Enum, values: ~w[google okta entra oidc email_otp userpass]a

    has_one :email_otp_auth_provider, Domain.EmailOTP.AuthProvider,
      references: :id,
      foreign_key: :id,
      where: [type: :email_otp]

    has_one :userpass_auth_provider, Domain.Userpass.AuthProvider,
      references: :id,
      foreign_key: :id,
      where: [type: :userpass]

    has_one :google_auth_provider, Domain.Google.AuthProvider,
      references: :id,
      foreign_key: :id,
      where: [type: :google]

    has_one :okta_auth_provider, Domain.Okta.AuthProvider,
      references: :id,
      foreign_key: :id,
      where: [type: :okta]

    has_one :entra_auth_provider, Domain.Entra.AuthProvider,
      references: :id,
      foreign_key: :id,
      where: [type: :entra]

    has_one :oidc_auth_provider, Domain.OIDC.AuthProvider,
      references: :id,
      foreign_key: :id,
      where: [type: :oidc]
  end

  def module!(type) do
    Map.fetch!(@provider_types, type)
  end

  def type!(module) do
    @provider_types
    |> Enum.find(fn {_type, mod} -> mod == module end)
    |> case do
      {type, _mod} -> type
      nil -> raise ArgumentError, "unknown auth provider module #{inspect(module)}"
    end
  end

  def changeset(changeset) do
    changeset
    |> validate_required(~w[type]a)
    |> assoc_constraint(:account)
    |> unique_constraint(:id, name: :auth_providers_pkey)
    |> check_constraint(:type, name: :type_must_be_valid, message: "is not valid")
  end
end
