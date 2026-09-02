defmodule Portal.Repo.Migrations.CreateOauthTables do
  use Ecto.Migration

  def change do
    # Clients are identified by an HTTPS URL that hosts their metadata document,
    # so this table is a cache of documents we fetched, not a registry of
    # clients we issued credentials to. It is global because a client id means
    # the same thing to every account.
    create table(:oauth_clients, primary_key: false) do
      add(:id, :binary_id, null: false, primary_key: true)

      add(:client_id, :text, null: false)
      add(:client_name, :text, null: false)
      add(:client_uri, :text)
      add(:logo_uri, :text)

      # The icon is fetched once with the document and stored, so the consent
      # screen can inline it rather than hotlinking a URL the client controls.
      add(:logo_data, :binary)
      add(:logo_content_type, :text)

      add(:redirect_uris, {:array, :text}, null: false)

      # Where the document was served from, resolved when it was fetched.
      add(:resolved_ips, {:array, :inet}, null: false, default: [])
      add(:resolved_ip_location_region, :string)
      add(:resolved_ip_location_city, :string)

      add(:metadata_expires_at, :timestamptz, null: false)

      timestamps()
    end

    create(unique_index(:oauth_clients, [:client_id]))

    # One standing consent: this actor allows this client these scopes. Kept
    # apart from the tokens so that it is what the portal shows and revokes,
    # while the tokens under it come and go as the client refreshes.
    create table(:oauth_grants, primary_key: false) do
      add(:account_id, references(:accounts, type: :binary_id, on_delete: :delete_all),
        null: false,
        primary_key: true
      )

      add(:id, :binary_id, null: false, primary_key: true)

      add(
        :actor_id,
        references(:actors,
          type: :binary_id,
          on_delete: :delete_all,
          with: [account_id: :account_id]
        ),
        null: false
      )

      add(:oauth_client_id, references(:oauth_clients, type: :binary_id, on_delete: :delete_all),
        null: false
      )

      add(:scopes, {:array, :text}, null: false)

      timestamps()
    end

    create(
      unique_index(:oauth_grants, [:account_id, :actor_id, :oauth_client_id],
        name: :oauth_grants_account_id_actor_id_oauth_client_id_index
      )
    )

    # Authorization codes are single use and live for about a minute. The row is
    # deleted on exchange, so a replayed code finds nothing.
    create table(:oauth_authorization_codes, primary_key: false) do
      add(:account_id, references(:accounts, type: :binary_id, on_delete: :delete_all),
        null: false,
        primary_key: true
      )

      add(:id, :binary_id, null: false, primary_key: true)

      add(
        :actor_id,
        references(:actors,
          type: :binary_id,
          on_delete: :delete_all,
          with: [account_id: :account_id]
        ),
        null: false
      )

      add(:oauth_client_id, references(:oauth_clients, type: :binary_id, on_delete: :delete_all),
        null: false
      )

      add(
        :oauth_grant_id,
        references(:oauth_grants,
          type: :binary_id,
          on_delete: :delete_all,
          with: [account_id: :account_id]
        ),
        null: false
      )

      add(:secret_hash, :string, null: false)
      add(:secret_salt, :string, null: false)

      # PKCE. Only S256 is accepted, so the method is stored for auditing
      # rather than to choose a verification strategy.
      add(:code_challenge, :string, null: false)
      add(:code_challenge_method, :string, null: false)

      add(:redirect_uri, :text, null: false)
      add(:resource, :text, null: false)
      add(:scopes, {:array, :text}, null: false)

      add(:expires_at, :timestamptz, null: false)

      timestamps(updated_at: false)
    end

    create(index(:oauth_authorization_codes, [:expires_at]))

    # One row per issued token pair. The refresh secret is rotated in place on
    # every refresh, which OAuth 2.1 requires for public clients.
    create table(:oauth_tokens, primary_key: false) do
      add(:account_id, references(:accounts, type: :binary_id, on_delete: :delete_all),
        null: false,
        primary_key: true
      )

      add(:id, :binary_id, null: false, primary_key: true)

      add(
        :actor_id,
        references(:actors,
          type: :binary_id,
          on_delete: :delete_all,
          with: [account_id: :account_id]
        ),
        null: false
      )

      add(
        :oauth_grant_id,
        references(:oauth_grants,
          type: :binary_id,
          on_delete: :delete_all,
          with: [account_id: :account_id]
        ),
        null: false
      )

      add(:secret_hash, :string, null: false)
      add(:secret_salt, :string, null: false)

      add(:refresh_secret_hash, :string)
      add(:refresh_secret_salt, :string)

      add(:scopes, {:array, :text}, null: false)

      # The audience this token is good for. A token minted for one resource is
      # rejected everywhere else, which is what stops a stolen token from being
      # replayed against a different service.
      add(:resource, :text, null: false)

      add(:expires_at, :timestamptz, null: false)
      add(:refresh_expires_at, :timestamptz)

      add(:last_seen_user_agent, :string)
      add(:last_seen_remote_ip, :inet)
      add(:last_seen_remote_ip_location_region, :string)
      add(:last_seen_remote_ip_location_city, :string)
      add(:last_seen_remote_ip_location_lat, :float)
      add(:last_seen_remote_ip_location_lon, :float)
      add(:last_seen_at, :timestamptz)

      timestamps()
    end

    create(index(:oauth_tokens, [:account_id, :oauth_grant_id]))
    create(index(:oauth_tokens, [:expires_at]))
  end
end
