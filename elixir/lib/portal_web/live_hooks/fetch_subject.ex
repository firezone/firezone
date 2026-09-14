defmodule PortalWeb.LiveHooks.FetchSubject do
  import Phoenix.LiveView
  alias Portal.Account
  alias Portal.Authentication
  alias Portal.Presence

  def on_mount(stage, _params, session, %{assigns: %{account: %Account{} = account}} = socket)
      when stage in [:default, :oauth] do
    session_key = session_key(stage)

    socket =
      Phoenix.Component.assign_new(socket, :subject, fn ->
        user_agent = get_connect_info(socket, :user_agent)
        real_ip = PortalWeb.Authentication.real_ip(socket)
        x_headers = get_connect_info(socket, :x_headers)
        context = Authentication.Context.build(real_ip, user_agent, x_headers, :portal)

        with {:ok, session_id} <- Map.fetch(session, session_key),
             {:ok, portal_session} <- Authentication.fetch_portal_session(account.id, session_id),
             {:ok, subject} <- Authentication.build_subject(portal_session, context) do
          subject
        else
          _ -> nil
        end
      end)

    # Track portal session presence when connected
    if stage == :default and connected?(socket) and socket.assigns.subject do
      Presence.PortalSessions.track(
        socket.assigns.subject.actor.id,
        socket.assigns.subject.credential.id
      )
    end

    {:cont, socket}
  end

  def on_mount(stage, _params, _session, socket) when stage in [:default, :oauth] do
    {:cont, socket}
  end

  # Read from separate keys on purpose. Sharing one would mean a session created
  # to approve an app connection could stand in for a portal session, which is
  # exactly what keeping the two apart is for.
  defp session_key(:default), do: "portal_session_id"
  defp session_key(:oauth), do: "oauth_session_id"
end
