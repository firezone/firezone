defmodule PortalWeb.LiveHooks.FetchSubject do
  import Phoenix.LiveView
  alias Portal.Account
  alias Portal.Authentication
  alias Portal.Presence

  def on_mount(:default, _params, session, %{assigns: %{account: %Account{} = account}} = socket) do
    socket =
      Phoenix.Component.assign_new(socket, :subject, fn ->
        user_agent = get_connect_info(socket, :user_agent)
        real_ip = PortalWeb.Authentication.real_ip(socket)
        x_headers = get_connect_info(socket, :x_headers)
        context = Auth.Context.build(real_ip, user_agent, x_headers, :portal)

        with {:ok, session_id} <- Map.fetch(session, "portal_session_id"),
             {:ok, portal_session} <- Auth.fetch_portal_session(account.id, session_id),
             {:ok, subject} <- Auth.build_subject(portal_session, context) do
          subject
        else
          _ -> nil
        end
      end)

    # Track portal session presence when connected
    if connected?(socket) and socket.assigns.subject do
      Presence.PortalSessions.track(
        socket.assigns.subject.actor.id,
        socket.assigns.subject.credential.id
      )
    end

    {:cont, socket}
  end

  def on_mount(:default, _params, _session, socket) do
    {:cont, socket}
  end
end
