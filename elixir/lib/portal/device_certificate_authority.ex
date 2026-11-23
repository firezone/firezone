defmodule Portal.DeviceCertificateAuthority do
  @moduledoc """
  The CA of one account that issues the certificates its devices connect with. Its private key
  never leaves the key store that `key_id` names, and `certificate` is the CA certificate in DER.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @type t :: %__MODULE__{}

  @primary_key false
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec]

  schema "device_certificate_authorities" do
    belongs_to :account, Portal.Account, primary_key: true
    field :key_id, :string
    field :certificate, :binary

    timestamps(updated_at: false)
  end

  def changeset(%Ecto.Changeset{} = changeset) do
    changeset
    |> validate_required([:account_id, :key_id, :certificate])
    |> assoc_constraint(:account)
    |> unique_constraint(:account_id, name: :device_certificate_authorities_pkey)
  end
end
