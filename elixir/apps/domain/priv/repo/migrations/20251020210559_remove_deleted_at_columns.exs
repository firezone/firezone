defmodule Domain.Repo.Migrations.RemoveDeletedAtColumns do
  use Ecto.Migration

  # Remove deleted_at columns from all tables that had soft delete functionality
  def change do
    alter table(:accounts) do
      remove(:deleted_at, :utc_datetime_usec)
    end

    alter table(:actors) do
      remove(:deleted_at, :utc_datetime_usec)
    end

    alter table(:actor_groups) do
      remove(:deleted_at, :utc_datetime_usec)
    end

    alter table(:auth_providers) do
      remove(:deleted_at, :utc_datetime_usec)
    end

    alter table(:auth_identities) do
      remove(:deleted_at, :utc_datetime_usec)
    end

    alter table(:clients) do
      remove(:deleted_at, :utc_datetime_usec)
    end

    alter table(:gateways) do
      remove(:deleted_at, :utc_datetime_usec)
    end

    alter table(:gateway_groups) do
      remove(:deleted_at, :utc_datetime_usec)
    end

    alter table(:policies) do
      remove(:deleted_at, :utc_datetime_usec)
    end

    alter table(:relays) do
      remove(:deleted_at, :utc_datetime_usec)
    end

    alter table(:relay_groups) do
      remove(:deleted_at, :utc_datetime_usec)
    end

    alter table(:resources) do
      remove(:deleted_at, :utc_datetime_usec)
    end

    alter table(:tokens) do
      remove(:deleted_at, :utc_datetime_usec)
    end
  end
end
