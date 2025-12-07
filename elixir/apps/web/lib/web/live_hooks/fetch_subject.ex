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

        with {:ok, fragment} <-
               fetch_token(session, account),
             {:ok, subject} <- Domain.Auth.authenticate(fragment, context) do
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

  defp fetch_token(session, _account) do
    case session["token"] do
      nil -> {:error, :unauthorized}
      token -> {:ok, token}
    end
  end
end
