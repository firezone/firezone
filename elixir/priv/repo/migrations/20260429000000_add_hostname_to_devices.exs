defmodule Portal.Repo.Migrations.AddHostnameToDevices do
  use Ecto.Migration

  def up do
    execute("CREATE EXTENSION IF NOT EXISTS citext")

    # `citext` gives us case-insensitive equality and uniqueness for free, so DNS
    # comparisons against device hostnames work regardless of how the FQDN was cased
    # in the original write. Casing is preserved on read; only comparisons fold case.
    alter table(:devices) do
      add(:hostname, :citext, null: true)
    end

    create(
      constraint(:devices, :devices_hostname_length,
        check: "hostname IS NULL OR (char_length(hostname) BETWEEN 3 AND 255)"
      )
    )

    create(
      unique_index(:devices, [:account_id, :hostname],
        where: "hostname IS NOT NULL",
        name: :devices_account_id_hostname_index
      )
    )
  end

  def down do
    drop(index(:devices, [:account_id, :hostname], name: :devices_account_id_hostname_index))
    drop(constraint(:devices, :devices_hostname_length))

    alter table(:devices) do
      remove(:hostname)
    end

    # Leave the `citext` extension in place — it's already used for account slugs and
    # user emails, so dropping it here would break unrelated columns.
  end
end
