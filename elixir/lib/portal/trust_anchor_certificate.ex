defmodule Portal.TrustAnchorCertificate do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key false
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec]

  @type t :: %__MODULE__{
          id: Ecto.UUID.t(),
          account_id: Ecto.UUID.t(),
          trust_anchor_id: Ecto.UUID.t(),
          pem: String.t(),
          fingerprint: String.t(),
          crl_url: String.t() | nil,
          ocsp_url: String.t() | nil,
          crl_this_update: DateTime.t() | nil,
          crl_next_update: DateTime.t() | nil,
          crl_fetched_at: DateTime.t() | nil,
          crl_error: String.t() | nil,
          inserted_at: DateTime.t(),
          updated_at: DateTime.t()
        }

  schema "trust_anchor_certificates" do
    belongs_to :account, Portal.Account, primary_key: true
    field :id, :binary_id, primary_key: true, autogenerate: true

    belongs_to :trust_anchor, Portal.TrustAnchor

    field :pem, :string
    # Hex-encoded SHA-256 over the certificate's DER bytes.
    field :fingerprint, :string

    # Learned from the first leaf that chains to this certificate: a CA
    # advertises revocation endpoints in what it issues, not in itself, so
    # these are unknown until a device connects.
    field :crl_url, :string
    field :ocsp_url, :string

    field :crl_this_update, :utc_datetime_usec
    field :crl_next_update, :utc_datetime_usec
    field :crl_fetched_at, :utc_datetime_usec
    field :crl_error, :string

    has_many :revocations, Portal.CrlRevocation,
      foreign_key: :trust_anchor_certificate_id,
      references: :id

    timestamps()
  end

  def changeset(%Ecto.Changeset{} = changeset) do
    changeset
    |> validate_required([:pem, :fingerprint])
    |> assoc_constraint(:account)
    |> assoc_constraint(:trust_anchor)
    |> unique_constraint(:fingerprint,
      name: :trust_anchor_certificates_account_id_fingerprint_index,
      message: "this certificate is already used by another trust anchor"
    )
  end
end
