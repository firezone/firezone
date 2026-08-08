defmodule Portal.Repo.Migrations.AddCrlRevocation do
  @moduledoc """
  Caches each trust anchor's certificate revocation list.

  Revocation endpoints are advertised by the certificates a CA issues, not by
  the CA certificate itself, so the URLs are learned from the first leaf that
  chains to an anchor and recorded here rather than being known at upload.

  Revoked serials are keyed on the issuer rather than on the anchor the chain
  validated against. RFC 5280 4.1.2.2 scopes a serial to its issuer, and the
  two are not the same thing here: an account that uploads both a root and its
  intermediate has two anchors that can each validate the same leaf, so keying
  on the anchor could check a leaf issued by the intermediate against the
  root's list. The anchor is kept only to record which fetch produced a row.

  Revoked serials live in their own table because the connect path checks one
  serial at a time. Holding them as an array on the anchor row would mean
  loading every revoked serial for every anchor on every connect, when all the
  connect needs is whether one row exists.

  Serials are stored uppercase hex, matching `devices.last_attested_cert_serial`,
  so the two compare directly.
  """
  use Ecto.Migration

  def change do
    alter table(:trust_anchor_certificates) do
      add(:crl_url, :string)
      add(:ocsp_url, :string)
      add(:crl_this_update, :timestamptz)
      add(:crl_next_update, :timestamptz)
      add(:crl_fetched_at, :timestamptz)
      add(:crl_error, :string)
    end

    create table(:crl_revocations, primary_key: false) do
      add(:account_id, references(:accounts, type: :binary_id, on_delete: :delete_all),
        null: false,
        primary_key: true
      )

      add(:issuer_hash, :string, null: false, primary_key: true)
      add(:serial, :string, null: false, primary_key: true)

      add(
        :trust_anchor_certificate_id,
        references(:trust_anchor_certificates,
          type: :binary_id,
          on_delete: :delete_all,
          with: [account_id: :account_id]
        ),
        null: false
      )

      add(:revoked_at, :timestamptz, null: false)
      add(:reason, :string)

      timestamps(updated_at: false)
    end
  end
end
