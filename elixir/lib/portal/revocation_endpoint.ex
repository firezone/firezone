defmodule Portal.RevocationEndpoint do
  @moduledoc """
  Where an issuing CA publishes revocation information, and how the last fetch
  went.

  One row per issuer per account. A certificate advertises the endpoint that
  covers itself, not the ones covering the certificates it goes on to issue, so
  a CA certificate names the list that would revoke the CA. The list covering
  devices is named only by the leaves, which is why a row appears when the
  first device attests rather than when the anchor is uploaded.

  The issuer is the DER encoding of the name exactly as the certificate carries
  it. RFC 5280 4.1.2.4 lets a CA encode its name as either a PrintableString or
  a UTF8String and both are still in wide use, so there is no single spelling to
  fold to. Normalizing would also sort the relative names, which would key two
  issuers whose names are permutations of each other to the same row. A CA emits
  the same bytes in the certificates it issues and in the CRL it publishes for
  them, which 5.1.2.3 requires, so the raw encoding is what joins them.

  A CA may split its list across several distribution points and bind each
  certificate to one, so a row is one partition rather than one issuer. The
  addresses within a partition are alternates for the same list, commonly a CDN
  and an origin, and any one answering is enough.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key false
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec]

  @type t :: %__MODULE__{
          account_id: Ecto.UUID.t(),
          issuer: binary(),
          distribution_point: String.t(),
          crl_urls: [String.t()],
          ocsp_urls: [String.t()],
          crl_number: integer() | nil,
          crl_this_update: DateTime.t() | nil,
          crl_next_update: DateTime.t() | nil,
          crl_fetched_at: DateTime.t() | nil,
          crl_error: String.t() | nil,
          ocsp_checked_at: DateTime.t() | nil,
          ocsp_error: String.t() | nil,
          delta_number: integer() | nil,
          delta_this_update: DateTime.t() | nil,
          delta_next_update: DateTime.t() | nil,
          delta_fetched_at: DateTime.t() | nil,
          delta_error: String.t() | nil,
          errored_at: DateTime.t() | nil,
          is_disabled: boolean(),
          disabled_reason: String.t() | nil,
          inserted_at: DateTime.t(),
          updated_at: DateTime.t()
        }

  schema "revocation_endpoints" do
    belongs_to :account, Portal.Account, primary_key: true

    field :issuer, :binary, primary_key: true
    field :distribution_point, :string, primary_key: true

    field :crl_urls, {:array, :string}, default: []
    field :ocsp_urls, {:array, :string}, default: []

    field :crl_number, :integer
    # Taken from the list itself, which RFC 5280 records to the second.
    field :crl_this_update, :utc_datetime
    field :crl_next_update, :utc_datetime
    field :crl_fetched_at, :utc_datetime_usec
    field :crl_error, :string

    field :ocsp_checked_at, :utc_datetime_usec
    field :ocsp_error, :string

    # The delta published on top of the list above, tracked separately because a
    # CA commonly leaves the complete list valid for a week while replacing the
    # delta daily.
    field :delta_number, :integer
    field :delta_this_update, :utc_datetime
    field :delta_next_update, :utc_datetime
    field :delta_fetched_at, :utc_datetime_usec
    field :delta_error, :string

    # Shared by the list and the responder: what gets reported is whether
    # revocation works for this CA at all, so a streak ends only once both are
    # healthy.
    field :errored_at, :utc_datetime_usec
    field :is_disabled, :boolean, default: false
    field :disabled_reason, :string

    timestamps()
  end

  def changeset(%Ecto.Changeset{} = changeset) do
    changeset
    |> validate_required([:issuer, :distribution_point])
    |> validate_length(:issuer, max: 1024, count: :bytes)
    |> validate_length(:distribution_point, max: 255)
    |> validate_urls(:crl_urls)
    |> validate_urls(:ocsp_urls)
    |> validate_length(:crl_error, max: 255)
    |> validate_length(:ocsp_error, max: 255)
    |> validate_length(:delta_error, max: 255)
    |> validate_length(:disabled_reason, max: 255)
    |> assoc_constraint(:account)
  end

  defp validate_urls(changeset, field) do
    changeset
    |> validate_length(field, max: 10)
    |> validate_change(field, fn ^field, urls ->
      if Enum.all?(urls, &(byte_size(&1) <= 255)), do: [], else: [{field, "is too long"}]
    end)
  end
end
