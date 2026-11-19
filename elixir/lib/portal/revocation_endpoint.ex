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
          crl_errored_at: DateTime.t() | nil,
          crl_is_disabled: boolean(),
          ocsp_errored_at: DateTime.t() | nil,
          ocsp_is_disabled: boolean(),
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

    # Kept apart for the list and the responder. Each is what the other falls
    # back on, so a fault in one must never stop the other.
    field :crl_errored_at, :utc_datetime_usec
    field :crl_is_disabled, :boolean, default: false
    field :ocsp_errored_at, :utc_datetime_usec
    field :ocsp_is_disabled, :boolean, default: false

    timestamps()
  end

  @http_list_sql """
  EXISTS (
    SELECT 1 FROM unnest(e.crl_urls) AS u
    WHERE u LIKE 'http://%' OR u LIKE 'https://%'
  )
  """

  # A cached list can answer for its certificates only while it is enabled,
  # unexpired, and so is any delta it names. A delta that was never read leaves
  # delta_fetched_at set with no delta_next_update, so it fails the check too.
  @current_list_sql """
  NOT e.crl_is_disabled
  AND e.crl_next_update > ?
  AND (e.delta_fetched_at IS NULL OR e.delta_next_update > ?)
  """

  @doc """
  True when every distribution point the certificate names has a current list.

  A point we have no row for yet has never been fetched, so it covers nothing.
  The caller passes only the points served over HTTP, since no other list is
  ever fetched, and no such points means no coverage.
  """
  defmacro crl_covers_points?(account_id, issuer, points, now) do
    sql = """
    cardinality(?::text[]) > 0
    AND NOT EXISTS (
      SELECT 1 FROM unnest(?::text[]) AS p(point)
      WHERE NOT EXISTS (
        SELECT 1 FROM revocation_endpoints e
        WHERE e.account_id = ? AND e.issuer = ? AND e.distribution_point = p.point
        AND #{@current_list_sql}
      )
    )
    """

    quote do
      fragment(
        unquote(sql),
        unquote(points),
        unquote(points),
        unquote(account_id),
        unquote(issuer),
        unquote(now),
        unquote(now)
      )
    end
  end

  @doc """
  True when every list the issuer publishes over HTTP is current.

  For work that is not about one certificate, such as the scheduled responder
  run, which asks about every device of the issuer. One partition that is off or
  stale leaves the certificates bound to it uncovered, so any gap counts as no
  coverage.
  """
  defmacro crl_covered?(account_id, issuer, now) do
    sql = """
    EXISTS (
      SELECT 1 FROM revocation_endpoints e
      WHERE e.account_id = ? AND e.issuer = ?
      AND #{@http_list_sql}
    )
    AND NOT EXISTS (
      SELECT 1 FROM revocation_endpoints e
      WHERE e.account_id = ? AND e.issuer = ?
      AND #{@http_list_sql}
      AND NOT COALESCE((#{@current_list_sql}), false)
    )
    """

    quote do
      fragment(
        unquote(sql),
        unquote(account_id),
        unquote(issuer),
        unquote(account_id),
        unquote(issuer),
        unquote(now),
        unquote(now)
      )
    end
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
