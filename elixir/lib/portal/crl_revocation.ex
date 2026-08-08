defmodule Portal.CrlRevocation do
  @moduledoc """
  One revoked certificate serial, as published by a trust anchor's CRL.

  Rows are owned entirely by the CRL fetch job: each successful fetch replaces
  the set for that issuer, so a serial that drops out of a published CRL stops
  being revoked here too.

  Keyed on the issuer rather than the anchor, because a serial only identifies
  a certificate together with whoever issued it.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key false
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec]

  @type t :: %__MODULE__{
          account_id: Ecto.UUID.t(),
          issuer_hash: String.t(),
          serial: String.t(),
          trust_anchor_certificate_id: Ecto.UUID.t(),
          revoked_at: DateTime.t(),
          reason: String.t() | nil,
          inserted_at: DateTime.t()
        }

  schema "crl_revocations" do
    belongs_to :account, Portal.Account, primary_key: true

    field :issuer_hash, :string, primary_key: true
    field :serial, :string, primary_key: true

    belongs_to :trust_anchor_certificate, Portal.TrustAnchorCertificate
    field :revoked_at, :utc_datetime_usec
    field :reason, :string

    timestamps(updated_at: false)
  end

  def changeset(%Ecto.Changeset{} = changeset) do
    changeset
    |> validate_required([:issuer_hash, :serial, :revoked_at])
    |> validate_length(:serial, max: 255)
    |> assoc_constraint(:account)
    |> assoc_constraint(:trust_anchor_certificate)
  end
end
