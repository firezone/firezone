defmodule Portal.AuthProvider do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key false
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec]

  @provider_types %{
    "google" => Portal.Google.AuthProvider,
    "okta" => Portal.Okta.AuthProvider,
    "entra" => Portal.Entra.AuthProvider,
    "oidc" => Portal.OIDC.AuthProvider,
    "email_otp" => Portal.EmailOTP.AuthProvider,
    "userpass" => Portal.Userpass.AuthProvider
  }

  schema "auth_providers" do
    belongs_to :account, Portal.Account, primary_key: true
    field :id, :binary_id, primary_key: true
    field :type, Ecto.Enum, values: ~w[google okta entra oidc email_otp userpass]a

    has_one :email_otp_auth_provider, Portal.EmailOTP.AuthProvider,
      references: :id,
      foreign_key: :id,
      where: [type: :email_otp]

    has_one :userpass_auth_provider, Portal.Userpass.AuthProvider,
      references: :id,
      foreign_key: :id,
      where: [type: :userpass]

    has_one :google_auth_provider, Portal.Google.AuthProvider,
      references: :id,
      foreign_key: :id,
      where: [type: :google]

    has_one :okta_auth_provider, Portal.Okta.AuthProvider,
      references: :id,
      foreign_key: :id,
      where: [type: :okta]

    has_one :entra_auth_provider, Portal.Entra.AuthProvider,
      references: :id,
      foreign_key: :id,
      where: [type: :entra]

    has_one :oidc_auth_provider, Portal.OIDC.AuthProvider,
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

  def changeset(%Ecto.Changeset{} = changeset) do
    changeset
    |> validate_required(~w[type]a)
    |> assoc_constraint(:account)
    |> unique_constraint(:id, name: :auth_providers_pkey)
    |> check_constraint(:type, name: :type_must_be_valid, message: "is not valid")
  end
end
