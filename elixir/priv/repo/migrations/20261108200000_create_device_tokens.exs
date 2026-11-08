defmodule Portal.Repo.Migrations.CreateDeviceTokens do
  use Ecto.Migration

  # One table for every credential a device connects with. Gateway tokens are
  # copied in first; client tokens follow once the link back to gateway_tokens
  # is dropped.
  def change do
    create table(:device_tokens, primary_key: false) do
      add(:account_id, references(:accounts, type: :binary_id, on_delete: :delete_all),
        null: false,
        primary_key: true
      )

      # While gateway_tokens is the source, deleting a gateway token deletes its
      # copy here, whichever code or cascade deletes it.
      add(
        :id,
        references(:gateway_tokens,
          with: [account_id: :account_id],
          type: :binary_id,
          on_delete: :delete_all,
          name: :device_tokens_gateway_token_fkey
        ),
        null: false,
        primary_key: true
      )

      add(
        :actor_id,
        references(:actors, with: [account_id: :account_id], type: :binary_id, on_delete: :delete_all),
        null: false
      )

      add(
        :auth_provider_id,
        references(:auth_providers,
          with: [account_id: :account_id],
          type: :binary_id,
          on_delete: :delete_all
        )
      )

      # A device-bound token belongs to one device; a site token puts the
      # devices that first connect with it in the site.
      add(
        :device_id,
        references(:devices, with: [account_id: :account_id], type: :binary_id, on_delete: :delete_all)
      )

      add(
        :site_id,
        references(:sites, with: [account_id: :account_id], type: :binary_id, on_delete: :delete_all)
      )

      add(:secret_salt, :string, null: false)
      add(:secret_hash, :string, null: false)

      add(:expires_at, :timestamptz)
      add(:rotated_at, :timestamptz)

      timestamps()
    end

    create(
      constraint(:device_tokens, :device_tokens_device_or_site,
        check: "num_nonnulls(device_id, site_id) <= 1"
      )
    )

    # At most one active token per device, as for gateway tokens.
    create_if_not_exists(
      unique_index(:device_tokens, [:account_id, :device_id, "(rotated_at IS NULL)"],
        where: "device_id IS NOT NULL",
        name: :device_tokens_device_rotated_state_index
      )
    )

    create_if_not_exists(index(:device_tokens, [:account_id, :actor_id]))

    create_if_not_exists(
      index(:device_tokens, [:account_id, :site_id], where: "site_id IS NOT NULL")
    )

    create_if_not_exists(
      index(:device_tokens, [:account_id, :auth_provider_id], where: "auth_provider_id IS NOT NULL")
    )

    create_if_not_exists(index(:device_tokens, [:rotated_at], where: "rotated_at IS NOT NULL"))
    create_if_not_exists(index(:device_tokens, [:expires_at], where: "expires_at IS NOT NULL"))
  end
end
