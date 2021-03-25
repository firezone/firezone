defmodule FgHttpWeb.DeviceLive.RulelistComponent do
  @moduledoc """
  Manages the Allowlist view.
  """
  use FgHttpWeb, :live_component

  alias FgHttp.Rules

  @impl true
  def update(assigns, socket) do
    {:ok,
     socket
     |> assign(assigns)
     |> assign(
       action: action(assigns.id),
       rule_list: rule_list(assigns),
       changeset: Rules.new_rule(%{"device_id" => assigns.device_id})
     )}
  end

  @impl true
  def handle_event("add_rule", params, socket) do
    # XXX: Authorization
    case Rules.create_rule(params["rule"]) do
      {:ok, _rule} ->
        {:noreply, assign(socket, rule_list: rule_list(socket.assigns))}

      {:error, changeset} ->
        {:noreply, assign(socket, changeset: changeset)}
    end
  end

  @impl true
  def handle_event("delete_rule", %{"rule_id" => rule_id}, socket) do
    # XXX: Authorization
    rule = Rules.get_rule!(rule_id)

    case Rules.delete_rule(rule) do
      {:ok, _rule} ->
        {:noreply, assign(socket, rule_list: rule_list(socket.assigns))}

      {:error, msg} ->
        {:noreply, put_flash(socket, :error, "Couldn't delete rule. #{msg}")}
    end
  end

  defp action(id) do
    case id do
      :allowlist ->
        "allow"

      :denylist ->
        "deny"
    end
  end

  defp rule_list(assigns) do
    case assigns.id do
      :allowlist ->
        Rules.allowlist(assigns.device_id)

      :denylist ->
        Rules.denylist(assigns.device_id)
    end
  end
end
