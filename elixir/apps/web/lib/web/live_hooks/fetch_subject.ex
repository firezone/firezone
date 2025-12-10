defmodule Web.LiveHooks.FetchSubject do
  import Phoenix.LiveView
  alias Domain.Account

  def on_mount(:default, params, session, %{assigns: %{account: %Account{} = account}} = socket) do
    socket =
      Phoenix.Component.assign_new(socket, :subject, fn ->
        context_type = context_type(params)
        user_agent = get_connect_info(socket, :user_agent)
        real_ip = Web.Auth.real_ip(socket)
        x_headers = get_connect_info(socket, :x_headers)
        context = Domain.Auth.Context.build(real_ip, user_agent, x_headers, context_type)

        with {:ok, token_id} <- Map.fetch(session, "token_id"),
             {:ok, token} <- Domain.Auth.fetch_token(account.id, token_id, context_type),
             {:ok, subject} <- Domain.Auth.build_subject(token, context) do
          subject
        else
          _ -> nil
        end
      end)

    {:cont, socket}
  end

  def on_mount(:default, _params, _session, socket) do
    {:cont, socket}
  end

  defp context_type(%{"as" => "client"}), do: :client
  defp context_type(_), do: :browser
end
