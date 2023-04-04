defmodule Web.SettingLive.Account do
  @moduledoc """
  Handles Account-related things for admins.
  """
  use Web, :live_view

  alias Domain.{
    ApiTokens,
    Auth.MFA,
    Users
  }

  alias Web.{
    Endpoint,
    Presence
  }

  @live_sessions_topic "notification:session"
  @page_title "Account Settings"
  @page_subtitle "Configure settings related to your Firezone web portal account."

  @impl Phoenix.LiveView
  def mount(params, _session, socket) do
    Endpoint.subscribe(@live_sessions_topic)
    {:ok, methods} = MFA.list_methods_for_user(socket.assigns.current_user)

    {:ok, api_tokens} =
      ApiTokens.list_api_tokens_by_user_id(socket.assigns.current_user.id, socket.assigns.subject)

    socket =
      socket
      |> assign(:api_token_id, params["api_token_id"])
      |> assign(:subscribe_link, subscribe_link())
      |> assign(:allow_delete, Users.count_by_role(:admin) > 1)
      |> assign(:api_tokens, api_tokens)
      |> assign(:changeset, Users.change_user(socket.assigns.current_user))
      |> assign(:methods, methods)
      |> assign(:page_title, @page_title)
      |> assign(:page_subtitle, @page_subtitle)
      |> assign(:rules_path, ~p"/rules")
      |> assign(
        :metas,
        get_metas(Presence.list(@live_sessions_topic), socket.assigns.current_user.id)
      )

    {:ok, socket}
  end

  @impl Phoenix.LiveView
  def handle_params(%{"api_token_id" => api_token_id}, _url, socket) do
    {:ok, api_token} = ApiTokens.fetch_unexpired_api_token_by_id(api_token_id)
    {:noreply, assign(socket, :api_token, api_token)}
  end

  @impl Phoenix.LiveView
  def handle_params(_params, _url, socket) do
    {:ok, api_tokens} =
      ApiTokens.list_api_tokens_by_user_id(socket.assigns.current_user.id, socket.assigns.subject)

    socket =
      socket
      |> assign(:allow_delete, Users.count_by_role(:admin) > 1)
      |> assign(:api_tokens, api_tokens)

    {:noreply, socket}
  end

  @impl Phoenix.LiveView
  def handle_event("delete_api_token", %{"id" => id}, socket) do
    case ApiTokens.delete_api_token_by_id(id, socket.assigns.subject) do
      {:ok, _api_token} ->
        {:ok, api_tokens} =
          ApiTokens.list_api_tokens_by_user_id(
            socket.assigns.current_user.id,
            socket.assigns.subject
          )

        {:noreply, assign(socket, :api_tokens, api_tokens)}

      {:error, :not_found} ->
        {:noreply, socket}
    end
  end

  @impl Phoenix.LiveView
  def handle_event("delete_authenticator", %{"id" => id}, socket) do
    with {:ok, _method} <- MFA.delete_method_by_id(id, socket.assigns.current_user) do
      {:ok, methods} = MFA.list_methods_for_user(socket.assigns.current_user)
      {:noreply, assign(socket, :methods, methods)}
    else
      {:error, :not_found} ->
        {:ok, methods} = MFA.list_methods_for_user(socket.assigns.current_user)
        {:noreply, assign(socket, :methods, methods)}

      false ->
        {:noreply, socket}
    end
  end

  @impl Phoenix.LiveView
  def handle_info(
        %{event: "presence_diff", payload: %{joins: joins, leaves: leaves}},
        %{assigns: %{metas: metas}} = socket
      ) do
    metas =
      (metas ++
         get_metas(joins, socket.assigns.current_user.id)) --
        get_metas(leaves, socket.assigns.current_user.id)

    {:noreply, assign(socket, :metas, metas)}
  end

  defp get_metas(presences, user_id) do
    get_in(presences, [user_id, :metas]) || []
  end

  defp subscribe_link do
    "https://www.firezone.dev/sales?utm_source=product&uid=#{Domain.Telemetry.id()}"
  end
end
