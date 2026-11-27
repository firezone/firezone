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
          system: boolean(),
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
    # Set on the certificate of the account's Firezone device CA, so queries for the
    # organization's own anchors can leave it out without a join.
    field :system, :boolean, default: false

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
