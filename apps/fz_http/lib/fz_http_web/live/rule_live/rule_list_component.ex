defmodule FzHttpWeb.RuleLive.RuleListComponent do
  @moduledoc """
  Manages the Allowlist view.
  """
  use FzHttpWeb, :live_component

  alias FzHttp.{AllowRules, Users, Gateways}

  @impl Phoenix.LiveComponent
  def update(assigns, socket) do
    {:ok,
     socket
     |> assign(assigns)
     |> assign(
       rule_list: rule_list(),
       users: users(),
       gateway_id: Gateways.get_gateway!().id,
       changeset: AllowRules.new_rule()
     )}
  end

  @impl Phoenix.LiveComponent
  def handle_event("change", %{"allow_rule" => rule_params}, socket) do
    changeset = AllowRules.new_rule(rule_params)

    {:noreply,
     socket
     |> assign(:changeset, changeset)}
  end

  @impl Phoenix.LiveComponent
  def handle_event("add_rule", %{"allow_rule" => rule_params}, socket) do
    case AllowRules.create_allow_rule(rule_params) do
      {:ok, _rule} ->
        {:noreply, assign(socket, changeset: AllowRules.new_rule(), rule_list: rule_list())}

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

  defp rule_list, do: AllowRules.list_allow_rules()

  defp users do
    Users.list_users()
    |> Stream.map(&{&1.uuid, &1.email})
    |> Map.new()
  end

  defp user_options(users) do
    Enum.map(users, fn {uuid, email} -> {email, uuid} end)
  end

  defp port_type_options do
    %{TCP: :tcp, UDP: :udp}
  end

  defp port_type_display(nil), do: nil
  defp port_type_display(:tcp), do: "TCP"
  defp port_type_display(:udp), do: "UDP"
end
