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

  `ocsp_statuses` is separate from `crl_revocations` because absence means
  different things in the two. A CRL is the whole truth for its issuer, so a
  serial missing from `crl_revocations` is not revoked. OCSP answers one
  certificate at a time, so a serial missing there has never been asked about.
  Holding both in one table would leave the connect path unable to tell which it
  was reading. OCSP also answers "good", which a CRL cannot express, and bounds
  that answer with its own `next_update`, so the row carries a status with an
  expiry rather than only recording the revoked. Its timestamps come from the
  responder, which RFC 6960 records to the second.

  `errored_at`, `is_disabled` and `disabled_reason` stop an endpoint that keeps
  failing from being fetched from forever. `errored_at` is when the current run
  of failures started, and is what the 24 hour rule for transient faults
  measures. It is shared by the list and the responder rather than kept per
  mechanism, because what gets reported is whether revocation works for this CA
  at all, and clearing it needs both to be healthy at once. An endpoint is
  discovered from a certificate rather than configured, so there is nothing of
  its own for an admin to edit: saving the trust anchor the issuer belongs to is
  what clears it.
  """
  use Ecto.Migration

  def change do
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

      add(:ocsp_checked_at, :timestamptz)
      add(:ocsp_error, :string)

      add(:errored_at, :timestamptz)
      add(:is_disabled, :boolean, null: false, default: false)
      add(:disabled_reason, :string)

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

    create table(:ocsp_statuses, primary_key: false) do
      add(:account_id, references(:accounts, type: :binary_id, on_delete: :delete_all),
        null: false,
        primary_key: true
      )

      add(:issuer, :binary, null: false, primary_key: true)
      add(:serial, :string, null: false, primary_key: true)

      add(:status, :string, null: false)
      add(:revoked_at, :timestamptz)
      add(:reason, :string)

      add(:produced_at, :timestamptz)
      add(:this_update, :timestamptz)
      add(:next_update, :timestamptz)

      timestamps(inserted_at: false)
    end
  end
end
