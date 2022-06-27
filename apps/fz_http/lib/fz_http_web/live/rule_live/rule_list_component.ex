defmodule FzHttpWeb.RuleLive.RuleListComponent do
  @moduledoc """
  Manages the Allowlist view.
  """
  use FzHttpWeb, :live_component

  alias FzHttp.Rules
  alias FzHttp.Users

  @events_module Application.compile_env!(:fz_http, :events_module)

  @impl Phoenix.LiveComponent
  def update(assigns, socket) do
    {:ok,
     socket
     |> assign(assigns)
     |> assign(
       action: action(assigns.id),
       rule_list: rule_list(assigns),
       user_list: user_list(assigns.current_user.id),
       changeset: Rules.new_rule()
     )}
  end

  @impl true
  def handle_event("add_rule", %{"rule" => rule_params}, socket) do
    case Rules.create_rule(rule_params) do
      {:ok, rule} ->
        @events_module.add_rule(rule)

        {:noreply,
         assign(socket, changeset: Rules.new_rule(), rule_list: rule_list(socket.assigns))}

      {:error, changeset} ->
        {:noreply, assign(socket, changeset: changeset)}
    end
  end

  @impl Phoenix.LiveComponent
  def handle_event("delete_rule", %{"rule_id" => rule_id}, socket) do
    rule = Rules.get_rule!(rule_id)

    case Rules.delete_rule(rule) do
      {:ok, _rule} ->
        @events_module.delete_rule(rule)
        {:noreply, assign(socket, rule_list: rule_list(socket.assigns))}

      {:error, msg} ->
        {:noreply, put_flash(socket, :error, "Couldn't delete rule. #{msg}")}
    end
  end

  def action(id) do
    case id do
      :allowlist ->
        :accept

      :denylist ->
        :drop
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

  defp user_list(current_user_id) do
    Users.list_users()
    |> Enum.filter(fn user -> user.id != current_user_id end)
    |> Enum.map(fn user -> {user.email, user.id} end)
  end

  defp get_scoped_user(user_id) do
    if user_id do
      Users.get_user(user_id).email
    end
  end
end
