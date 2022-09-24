defmodule FzHttpWeb.RuleLive.RuleListComponent do
  @moduledoc """
  Manages the Allowlist view.
  """
  use FzHttpWeb, :live_component

  alias FzHttp.Rules
  alias FzHttp.Users

  @impl Phoenix.LiveComponent
  def update(assigns, socket) do
    {:ok,
     socket
     |> assign(assigns)
     |> assign(Rules.defaults())
     |> assign(
       action: action(assigns.id),
       rule_list: rule_list(assigns),
       users: users(),
       changeset: Rules.new_rule(),
       port_rules_supported: Rules.port_rules_supported?()
     )}
  end

  @impl Phoenix.LiveComponent
  def handle_event("change", %{"rule" => rule_params}, socket) do
    changeset = Rules.new_rule(rule_params)

    {:noreply,
     socket
     |> assign(:changeset, changeset)
     |> assign(Rules.defaults(changeset))}
  end

  @impl Phoenix.LiveComponent
  def handle_event("add_rule", %{"rule" => rule_params}, socket) do
    if Rules.port_rules_supported?() || Map.get(rule_params, :port_type) == nil do
      case Rules.create_rule(rule_params) do
        {:ok, _rule} ->
          {:noreply,
           assign(socket, changeset: Rules.new_rule(), rule_list: rule_list(socket.assigns))
           |> assign(Rules.defaults())}

        {:error, changeset} ->
          {:noreply, assign(socket, changeset: changeset)}
      end
    else
      # While using the UI this should never happen
      {:noreply,
       put_flash(socket, :error, "Couldn't add rule. Port-based rules are not supported.")}
    end
  end

  @impl Phoenix.LiveComponent
  def handle_event("delete_rule", %{"rule_id" => rule_id}, socket) do
    rule = Rules.get_rule!(rule_id)

    if Rules.port_rules_supported?() || rule.port_type == nil do
      case Rules.delete_rule(rule) do
        {:ok, _rule} ->
          {:noreply, assign(socket, rule_list: rule_list(socket.assigns))}

        {:error, msg} ->
          {:noreply, put_flash(socket, :error, "Couldn't delete rule. #{msg}")}
      end
    else
      # While using the UI this should never happen
      {:noreply,
       put_flash(socket, :error, "Couldn't delete rule. Port-based rules are not supported.")}
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
