defmodule CfHttpWeb.FirewallRuleController do
  use CfHttpWeb, :controller

  alias CfHttp.FirewallRules
  alias CfHttp.FirewallRules.FirewallRule
  alias CfHttp.Devices

  plug CfHttpWeb.Plugs.Authenticator

  def index(conn, %{"device_id" => device_id}) do
    device = Devices.get_device!(device_id)

    render(conn, "index.html", device: device, firewall_rules: device.firewall_rules)
  end

  def new(conn, %{"device_id" => device_id}) do
    device = Devices.get_device!(device_id)

    changeset = FirewallRules.change_firewall_rule(%FirewallRule{device_id: device_id})
    render(conn, "new.html", changeset: changeset, device: device)
  end

  def create(conn, %{"firewall_rule" => firewall_rule_params}) do
    case FirewallRules.create_firewall_rule(firewall_rule_params) do
      {:ok, firewall_rule} ->
        conn
        |> put_flash(:info, "Firewall rule created successfully.")
        |> redirect(to: Routes.firewall_rule_path(conn, :show, firewall_rule))

      {:error, %Ecto.Changeset{} = changeset} ->
        render(conn, "new.html", changeset: changeset)
    end
 end

  def show(conn, %{"id" => id}) do
    firewall_rule = FirewallRules.get_firewall_rule!(id)
    render(conn, "show.html", firewall_rule: firewall_rule)
  end

  def edit(conn, %{"id" => id}) do
    firewall_rule = FirewallRules.get_firewall_rule!(id)
    changeset = FirewallRules.change_firewall_rule(firewall_rule)
    render(conn, "edit.html", firewall_rule: firewall_rule, changeset: changeset)
  end

  def update(conn, %{"id" => id, "firewall_rule" => firewall_rule_params}) do
    firewall_rule = FirewallRules.get_firewall_rule!(id)

    case FirewallRules.update_firewall_rule(firewall_rule, firewall_rule_params) do
      {:ok, firewall_rule} ->
        conn
        |> put_flash(:info, "Firewall rule updated successfully.")
        |> redirect(to: Routes.firewall_rule_path(conn, :show, firewall_rule))

      {:error, %Ecto.Changeset{} = changeset} ->
        render(conn, "edit.html", firewall_rule: firewall_rule, changeset: changeset)
    end
  end

  def delete(conn, %{"id" => id}) do
    firewall_rule = FirewallRules.get_firewall_rule!(id)
    {:ok, _firewall_rule} = FirewallRules.delete_firewall_rule(firewall_rule)

    conn
    |> put_flash(:info, "Firewall rule deleted successfully.")
    |> redirect(to: Routes.firewall_rule_path(conn, :index, firewall_rule.device))
  end
end
