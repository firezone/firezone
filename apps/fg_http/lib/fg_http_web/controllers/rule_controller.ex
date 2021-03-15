defmodule FgHttpWeb.RuleController do
  @moduledoc """
  Controller logic for Rules
  """

  import Phoenix.LiveView.Controller
  use FgHttpWeb, :controller
  alias FgHttp.{Devices, Rules}

  plug FgHttpWeb.Plugs.SessionLoader

  def create(conn, %{"device_id" => device_id, "rule" => rule_params}) do
    # XXX RBAC
    all_params = Map.merge(rule_params, %{"device_id" => device_id})

    case Rules.create_rule(all_params) do
      {:ok, rule} ->
        # XXX: Create in after-commit
        :ok = @events_module.add_rule(rule)

        conn
        |> put_flash(:info, "Rule created successfully.")

      # |> redirect(to: Routes.device_rule_path(conn, :index, rule.device_id))

      {:error, _changeset} ->
        _device = Devices.get_device!(device_id)
        # render(conn, "new.html", device: device, changeset: changeset)
    end
  end

  def delete(conn, %{"id" => id}) do
    rule = Rules.get_rule!(id)
    _device_id = rule.device_id
    {:ok, _rule} = Rules.delete_rule(rule)

    # XXX: Delete in after-commit
    :ok = @events_module.delete_rule(rule)

    conn
    |> put_flash(:info, "Rule deleted successfully.")

    # |> redirect(to: Routes.device_rule_path(conn, :index, device_id))
  end
end
