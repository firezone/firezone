defmodule Portal.Repo.Migrations.AddDeviceAttestedCertIssuer do
  @moduledoc """
  Records who issued the certificate a device last presented.

  A serial identifies a certificate only together with its issuer, so both are
  needed to match a device against a revocation learned after it connected.

  Its own migration rather than an addition to the one that created the other
  attested columns: that one has already run everywhere, so a column added to it
  would never be created on a deployed database while the schema went on
  selecting it.
  """
  use Ecto.Migration

  def change do
    alter table(:devices) do
      add(:last_attested_cert_issuer, :binary)
    end
  end
end
