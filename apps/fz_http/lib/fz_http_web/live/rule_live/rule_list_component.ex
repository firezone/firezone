defmodule FzHttpWeb.RuleLive.RuleListComponent do
  @moduledoc """
  Manages the Allowlist view.
  """
  use FzHttpWeb, :live_component

  alias FzHttp.AllowRules
  alias FzHttp.Users

  @impl Phoenix.LiveComponent
  def update(assigns, socket) do
    {:ok,
     socket
     |> assign(assigns)
     |> assign(AllowRules.defaults())
     |> assign(
       action: action(assigns.id),
       rule_list: rule_list(),
       users: users(),
       changeset: AllowRules.new_rule()
     )}
  end

  @impl Phoenix.LiveComponent
  def handle_event("change", %{"rule" => rule_params}, socket) do
    changeset = AllowRules.new_rule(rule_params)

    {:noreply,
     socket
     |> assign(:changeset, changeset)
     |> assign(AllowRules.defaults(changeset))}
  end

  @impl Phoenix.LiveComponent
  def handle_event("add_rule", %{"rule" => rule_params}, socket) do
    case AllowRules.create_allow_rule(rule_params) do
      {:ok, _rule} ->
        {:noreply,
         assign(socket, changeset: AllowRules.new_rule(), rule_list: rule_list())
         |> assign(AllowRules.defaults())}

      {:error, changeset} ->
        {:noreply, assign(socket, changeset: changeset)}
    end
  end

  @impl Phoenix.LiveComponent
  def handle_event("delete_rule", %{"rule_id" => rule_id}, socket) do
    rule = AllowRules.get_allow_rule!(rule_id)

    case AllowRules.delete_allow_rule(rule) do
      {:ok, _rule} ->
        {:noreply, assign(socket, rule_list: rule_list())}

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

  defp rule_list() do
    AllowRules.list_allow_rules()
  end

  defp users do
    Users.list_users()
    |> Stream.map(&{&1.id, &1.email})
    |> Map.new()
  end

  defp user_options(users) do
    Enum.map(users, fn {id, email} -> {email, id} end)
  end

  defp port_type_options do
    %{TCP: :tcp, UDP: :udp}
  end

  defp port_type_display(nil), do: nil
  defp port_type_display(:tcp), do: "TCP"
  defp port_type_display(:udp), do: "UDP"
end
