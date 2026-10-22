defmodule Portal.Repo.Migrations.AllowFlowLogOpenOuters do
  use Ecto.Migration

  def up do
    replace_constraint(open_outers_check())
  end

  def down do
    replace_constraint(closed_outers_check())
  end

  defp replace_constraint(check) do
    drop(constraint(:flow_logs, :flow_logs_outers_match_flow_state))

    create(
      constraint(:flow_logs, :flow_logs_outers_match_flow_state,
        check: check
      )
    )
  end

  defp open_outers_check do
    """
    (flow_end IS NULL AND outers IS NULL) OR
    (outers IS NOT NULL AND
     jsonb_typeof(outers) = 'array' AND
     jsonb_array_length(outers) > 0)
    """
  end

  defp closed_outers_check do
    """
    (flow_end IS NULL AND outers IS NULL) OR
    (flow_end IS NOT NULL AND
     jsonb_typeof(outers) = 'array' AND
     jsonb_array_length(outers) > 0)
    """
  end
end
