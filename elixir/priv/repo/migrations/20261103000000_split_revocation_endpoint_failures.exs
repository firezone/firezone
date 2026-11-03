defmodule Portal.Repo.Migrations.SplitRevocationEndpointFailures do
  use Ecto.Migration

  def up do
    alter table(:revocation_endpoints) do
      add_if_not_exists(:crl_errored_at, :timestamptz)
      add_if_not_exists(:crl_is_disabled, :boolean, null: false, default: false)
      add_if_not_exists(:ocsp_errored_at, :timestamptz)
      add_if_not_exists(:ocsp_is_disabled, :boolean, null: false, default: false)
    end

    # The shared streak is credited to whichever mechanism holds an error. A row
    # disabled with neither error set starts fetching again, which is the safe
    # side: it disables itself once more if the fault is still there.
    execute("""
    UPDATE revocation_endpoints
    SET crl_errored_at = CASE WHEN crl_error IS NOT NULL THEN errored_at END,
        ocsp_errored_at = CASE WHEN ocsp_error IS NOT NULL THEN errored_at END,
        crl_is_disabled = is_disabled AND crl_error IS NOT NULL,
        ocsp_is_disabled = is_disabled AND ocsp_error IS NOT NULL
    WHERE errored_at IS NOT NULL OR is_disabled
    """)
  end

  def down do
    execute("""
    UPDATE revocation_endpoints
    SET errored_at = LEAST(crl_errored_at, ocsp_errored_at),
        is_disabled = crl_is_disabled OR ocsp_is_disabled,
        disabled_reason = CASE WHEN crl_is_disabled OR ocsp_is_disabled THEN 'Fetch error' END
    """)

    alter table(:revocation_endpoints) do
      remove_if_exists(:crl_errored_at, :timestamptz)
      remove_if_exists(:crl_is_disabled, :boolean)
      remove_if_exists(:ocsp_errored_at, :timestamptz)
      remove_if_exists(:ocsp_is_disabled, :boolean)
    end
  end
end
