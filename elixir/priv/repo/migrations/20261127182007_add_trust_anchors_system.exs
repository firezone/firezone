defmodule Portal.Repo.Migrations.AddTrustAnchorsSystem do
  use Ecto.Migration

  # The account's Firezone device CA is a system trust anchor. Its certificate rows carry the flag
  # too, so every query for the organization's own anchors can filter without a join.
  def up do
    execute("SET LOCAL lock_timeout TO '2s'")

    alter table(:trust_anchors) do
      add_if_not_exists(:system, :boolean, null: false, default: false)
    end

    alter table(:trust_anchor_certificates) do
      add_if_not_exists(:system, :boolean, null: false, default: false)
    end
  end

  def down do
    execute("SET LOCAL lock_timeout TO '2s'")

    alter table(:trust_anchor_certificates) do
      remove_if_exists(:system, :boolean)
    end

    alter table(:trust_anchors) do
      remove_if_exists(:system, :boolean)
    end
  end
end
