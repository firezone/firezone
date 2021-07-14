defmodule FzHttpWeb.RuleLive.RuleListComponent do
  @moduledoc """
  Manages the Allowlist view.
  """
  use FzHttpWeb, :live_component

  alias FzHttp.Rules

  @impl true
  def update(assigns, socket) do
    {:ok,
     socket
     |> assign(assigns)
     |> assign(
       action: action(assigns.id),
       rule_list: rule_list(assigns),
       changeset: Rules.new_rule()
     )}
  end

  @impl true
  def handle_event("add_rule", %{"rule" => rule_params}, socket) do
    case Rules.create_rule(rule_params) do
      {:ok, _rule} ->
        {:noreply, assign(socket, rule_list: rule_list(socket.assigns))}

      {:error, changeset} ->
        {:noreply, assign(socket, changeset: changeset)}
    end
  end

  @impl true
  def handle_event("delete_rule", %{"rule_id" => rule_id}, socket) do
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
        :allow

      :denylist ->
        :deny
    end
  end

  defp rule_list(assigns) do
    case assigns.id do
      :allowlist ->
        Rules.allowlist()

      :denylist ->
        Rules.denylist()
    end
  end
end
