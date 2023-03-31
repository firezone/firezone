defmodule FzHttp.Repo.Migrations.AddDefaultPksValues do
  use Ecto.Migration

  def change do
    execute("""
    ALTER TABLE connectivity_checks
    ALTER COLUMN id
    SET DEFAULT gen_random_uuid();
    """)

    execute("""
    ALTER TABLE oidc_connections
    ALTER COLUMN id
    SET DEFAULT gen_random_uuid();
    """)

    execute("""
    ALTER TABLE api_tokens
    ALTER COLUMN id
    SET DEFAULT gen_random_uuid();
    """)

    execute("""
    ALTER TABLE configurations
    ALTER COLUMN id
    SET DEFAULT gen_random_uuid();
    """)

    execute("""
    ALTER TABLE mfa_methods
    ALTER COLUMN id
    SET DEFAULT gen_random_uuid();
    """)
  end
end
