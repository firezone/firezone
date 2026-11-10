defmodule Portal.Repo.Migrations.AddDeviceTokensClientTokenId do
  use Ecto.Migration

  # While client_tokens is the source, deleting a client token deletes its
  # copy here, whichever code or cascade deletes it. Gateway tokens leave the
  # column null, so the key does not apply to them.
  def up do
    execute("SET LOCAL lock_timeout TO '2s'")

    alter table(:device_tokens) do
      add(
        :client_token_id,
        references(:client_tokens,
          with: [account_id: :account_id],
          type: :binary_id,
          on_delete: :delete_all,
          name: :device_tokens_client_token_fkey
        )
      )
    end
  end

  def down do
    execute("SET LOCAL lock_timeout TO '2s'")

    alter table(:device_tokens) do
      remove(:client_token_id)
    end
  end
end
