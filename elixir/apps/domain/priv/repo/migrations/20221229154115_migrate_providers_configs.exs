defmodule Domain.Repo.Migrations.MigrateProvidersConfigs do
  use Ecto.Migration

  def change do
    execute("""
    UPDATE configurations
    SET openid_connect_providers = COALESCE((select jsonb_agg(o.item::jsonb || jsonb_build_object('id', key)) from jsonb_each(openid_connect_providers) as o(key, item)), '[]'::jsonb),
        saml_identity_providers = COALESCE((select jsonb_agg(s.item::jsonb || jsonb_build_object('id', key)) from jsonb_each(saml_identity_providers) as s(key, item)), '[]'::jsonb)
    """)
  end
end
