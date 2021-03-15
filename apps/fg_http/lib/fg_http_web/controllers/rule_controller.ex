defmodule FgHttpWeb.RuleController do
  @moduledoc """
  Controller logic for Rules
  """

  use FgHttpWeb, :controller
  alias FgHttp.{Devices, Rules, Rules.Rule}

  plug FgHttpWeb.Plugs.SessionLoader

  def index(conn, %{"device_id" => device_id}) do
    device = Devices.get_device!(device_id, :with_rules)
    render(conn, "index.html", device: device, rules: device.rules)
  end

  def create(conn, %{"device_id" => device_id, "rule" => rule_params}) do
    # XXX RBAC
    all_params = Map.merge(rule_params, %{"device_id" => device_id})

    case Rules.create_rule(all_params) do
      {:ok, rule} ->
        # XXX: Create in after-commit
        :rule_added = add_rule_to_firewall(rule)

        conn
        |> put_flash(:info, "Rule created successfully.")
        |> redirect(to: Routes.device_rule_path(conn, :index, rule.device_id))

      {:error, changeset} ->
        device = Devices.get_device!(device_id)
        render(conn, "new.html", device: device, changeset: changeset)
    end
  end

  def delete(conn, %{"id" => id}) do
    rule = Rules.get_rule!(id)
    device_id = rule.device_id
    {:ok, _rule} = Rules.delete_rule(rule)

    # XXX: Delete in after-commit
    :rule_deleted = delete_rule_from_firewall(rule)

    conn
    |> put_flash(:info, "Rule deleted successfully.")
    |> redirect(to: Routes.device_rule_path(conn, :index, device_id))
  end

  defp add_rule_to_firewall(rule) do
    GenServer.call()
  end

  defp delete_rule_from_firewall(rule) do
  end
end
