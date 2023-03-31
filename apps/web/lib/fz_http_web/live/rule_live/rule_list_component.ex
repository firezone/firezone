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
     |> assign(
       action: action(assigns.id),
       rule_list: rule_list(assigns),
       users: users(assigns.subject),
       changeset: Rules.new_rule(),
       port_rules_supported: Rules.port_rules_supported?()
     )}
  end

  @impl Phoenix.LiveComponent
  def handle_event("change", %{"rule" => attrs}, socket) do
    changeset = Rules.new_rule(attrs)

    socket =
      socket
      |> assign(:changeset, changeset)

    {:noreply, socket}
  end

  @impl Phoenix.LiveComponent
  def handle_event("add_rule", %{"rule" => attrs}, socket) do
    case Rules.create_rule(attrs, socket.assigns.subject) do
      {:ok, _rule} ->
        socket =
          socket
          |> assign(changeset: Rules.new_rule(), rule_list: rule_list(socket.assigns))

        {:noreply, socket}

      {:error, changeset} ->
        {:noreply, assign(socket, changeset: changeset)}
    end
  end

  @impl Phoenix.LiveComponent
  def handle_event("delete_rule", %{"rule_id" => rule_id}, socket) do
    with {:ok, rule} <- Rules.fetch_rule_by_id(rule_id, socket.assigns.subject),
         {:ok, _rule} <- Rules.delete_rule(rule, socket.assigns.subject) do
      {:noreply, assign(socket, rule_list: rule_list(socket.assigns))}
    else
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

  defp users(subject) do
    {:ok, users} = Users.list_users(subject)

    users
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
