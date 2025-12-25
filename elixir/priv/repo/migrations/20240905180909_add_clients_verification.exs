defmodule Portal.Repo.Migrations.AddClientsVerification do
  use Ecto.Migration

  def change do
    alter table(:clients) do
      add(:verified_at, :utc_datetime_usec, default: nil)
      add(:verified_by, :string)
      add(:verified_by_actor_id, references(:actors, type: :binary_id))
      add(:verified_by_identity_id, references(:auth_identities, type: :binary_id))
    end

    create(
      constraint(:clients, :verified_fields_set,
        check: """
        (
          verified_at IS NULL
          AND (verified_by IS NULL AND verified_by_actor_id IS NULL AND verified_by_identity_id IS NULL )
        )
        OR
        (
          verified_at IS NOT NULL
          AND (
            (verified_by = 'system' AND verified_by_actor_id IS NULL AND verified_by_identity_id IS NULL)
            OR (verified_by = 'actor' AND verified_by_actor_id IS NOT NULL AND verified_by_identity_id IS NULL)
            OR (verified_by = 'identity' AND verified_by_actor_id IS NOT NULL AND verified_by_identity_id IS NOT NULL)
          )
        )
        """
      )
    )
  end
end
