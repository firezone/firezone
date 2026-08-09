defmodule Portal.Repo.Migrations.AddCrlRevocation do
  @moduledoc """
  Caches the certificate revocation lists published by each issuing CA.

  Rows are keyed on the issuer rather than on the trust anchor the chain
  validated against. RFC 5280 4.1.2.2 scopes a serial to its issuer, and the two
  are not the same thing here: an account that uploads both a root and its
  intermediate has two anchors that can each validate the same leaf, so keying
  on the anchor could check a leaf issued by the intermediate against the root's
  list.

  The issuer is stored as the DER encoding of the name exactly as the
  certificate carries it. RFC 5280 4.1.2.4 lets a CA encode its name as either a
  PrintableString or a UTF8String and both remain in wide use, so there is no one
  spelling to fold to; 5.1.2.3 requires a CRL to carry the same issuer name as
  the certificates it covers, which is what makes the two tables join. Postgres
  cannot decode a name, so the readable form is rendered on read rather than
  stored.

  Keyed on the distribution point as well, because a CA may partition its list
  across several of them and bind each certificate to one through its own
  distribution point. Replacing per issuer would then wipe the partitions a
  fetch never saw. The connect path still looks up on issuer and serial alone,
  which is a prefix of the revocations key, so the union of the partitions is
  what it reads.

  `crl_urls` holds every address the certificate advertised for one partition.
  They are alternates for the same list, commonly a CDN and an origin, so they
  are tried in order and any one answering is enough.

  Revocation endpoints are advertised by the certificates a CA issues, not by
  the CA certificate itself, so a CA certificate names the list that would
  revoke the CA. The list covering devices is named only by the leaves, which is
  why a row appears when the first device attests.

  Revoked serials live in their own table because the connect path checks one
  serial at a time. Holding them as an array on the endpoint row would mean
  loading every revoked serial for an issuer on every connect, when all the
  connect needs is whether one row exists.

  Serials are stored uppercase hex, matching `devices.last_attested_cert_serial`,
  so the two compare directly.

  A CA may publish a delta alongside its complete list, naming it from the
  complete list's Freshest CRL extension, and typically republishes the delta far
  more often. The delta's own freshness is tracked in its own columns, because a
  complete list that is still inside its own validity says nothing about whether
  the delta on top of it has since been replaced.
  """
  use Ecto.Migration

  def change do
    alter table(:devices) do
      add(:last_attested_cert_issuer, :binary)
    end

    create(
      index(:devices, [:account_id, :last_attested_cert_issuer, :last_attested_cert_serial],
        where: "last_attested_cert_issuer IS NOT NULL",
        name: :devices_attested_issuer_serial_index
      )
    )

    create table(:revocation_endpoints, primary_key: false) do
      add(:account_id, references(:accounts, type: :binary_id, on_delete: :delete_all),
        null: false,
        primary_key: true
      )

      add(:issuer, :binary, null: false, primary_key: true)
      add(:distribution_point, :string, null: false, primary_key: true)

      add(:crl_urls, {:array, :string}, null: false, default: [])
      add(:ocsp_urls, {:array, :string}, null: false, default: [])

      add(:crl_number, :bigint)
      add(:crl_this_update, :timestamptz)
      add(:crl_next_update, :timestamptz)
      add(:crl_fetched_at, :timestamptz)
      add(:crl_error, :string)

      add(:delta_number, :bigint)
      add(:delta_this_update, :timestamptz)
      add(:delta_next_update, :timestamptz)
      add(:delta_fetched_at, :timestamptz)
      add(:delta_error, :string)

      timestamps()
    end

    create table(:crl_revocations, primary_key: false) do
      add(:account_id, references(:accounts, type: :binary_id, on_delete: :delete_all),
        null: false,
        primary_key: true
      )

      add(:issuer, :binary, null: false, primary_key: true)
      add(:serial, :string, null: false, primary_key: true)
      add(:distribution_point, :string, null: false, primary_key: true)

      add(:revoked_at, :timestamptz, null: false)
      add(:reason, :string)

      timestamps(updated_at: false)
    end
  end
end
