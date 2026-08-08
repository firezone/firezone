defmodule Portal.CrlRevocation do
  @moduledoc """
  One revoked certificate serial, as published by an issuing CA's CRL.

  Rows are owned entirely by the CRL fetch job: each successful fetch replaces
  the set for that issuer, so a serial that drops out of a published CRL stops
  being revoked here too.

  Keyed on the issuer rather than on a trust anchor, because a serial only
  identifies a certificate together with whoever issued it. The issuer is the
  DER encoding of the name as the certificate carries it; see
  `Portal.RevocationEndpoint` for why it is not folded to a canonical form.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key false
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec]

  @type t :: %__MODULE__{
          account_id: Ecto.UUID.t(),
          issuer: binary(),
          serial: String.t(),
          revoked_at: DateTime.t(),
          reason: String.t() | nil,
          inserted_at: DateTime.t()
        }

  schema "crl_revocations" do
    belongs_to :account, Portal.Account, primary_key: true

    field :issuer, :binary, primary_key: true
    field :serial, :string, primary_key: true

    # RFC 5280 records revocation times as UTCTime or GeneralizedTime, both of
    # which stop at seconds, so there is no sub-second part to keep.
    field :revoked_at, :utc_datetime
    field :reason, :string

    timestamps(updated_at: false)
  end

  def changeset(%Ecto.Changeset{} = changeset) do
    changeset
    |> validate_required([:issuer, :serial, :revoked_at])
    |> validate_length(:issuer, max: 1024, count: :bytes)
    |> validate_length(:serial, max: 255)
    |> assoc_constraint(:account)
  end
end
