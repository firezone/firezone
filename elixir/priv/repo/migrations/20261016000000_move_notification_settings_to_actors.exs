defmodule Portal.Repo.Migrations.MoveNotificationSettingsToActors do
  @moduledoc """
  Email notification choices move from the account to each admin's own
  preferences. Every admin of an account that turned a notification off keeps
  it off, stored as an empty channel list. All other choices stay unset, so the
  defaults apply.
  """
  use Ecto.Migration

  def change do
    execute(
      """
      UPDATE actors
      SET preferences = jsonb_set(
        COALESCE(actors.preferences, '{}'::jsonb),
        '{notifications}',
        COALESCE(NULLIF(actors.preferences->'notifications', 'null'::jsonb), '{}'::jsonb)
          || jsonb_strip_nulls(jsonb_build_object(
            'outdated_gateways',
            CASE WHEN accounts.config->'notifications'->'outdated_gateway'->>'enabled' = 'false'
              THEN '[]'::jsonb END,
            'seat_limit_warnings',
            CASE WHEN accounts.config->'notifications'->'seats_warning'->>'enabled' = 'false'
              THEN '[]'::jsonb END
          ))
      )
      FROM accounts
      WHERE accounts.id = actors.account_id
        AND actors.type = 'account_admin_user'
        AND (
          accounts.config->'notifications'->'outdated_gateway'->>'enabled' = 'false'
          OR accounts.config->'notifications'->'seats_warning'->>'enabled' = 'false'
        )
      """,
      ""
    )
  end
end
