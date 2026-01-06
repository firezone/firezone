defmodule Portal.Repo.Migrations.MigrateEmailDataAgain do
  use Ecto.Migration

  def change do
    execute("""
      UPDATE auth_identities AS ai
      SET email =
        CASE
          WHEN p.adapter = 'email' OR p.adapter = 'userpass' THEN ai.provider_identifier
          ELSE COALESCE(
            provider_state #>> '{claims,email}',
            provider_state #>> '{userinfo,email}'
          )
        END
      FROM auth_providers AS p
      WHERE ai.provider_id = p.id
        AND ai.email IS NULL
        AND ai.deleted_at IS NULL
    """)
  end
end
