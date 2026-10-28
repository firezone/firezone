defmodule PortalWeb.LiveHooks.FetchAccount do
  import Phoenix.LiveView

  def on_mount(:default, %{"account_id_or_slug" => account_id_or_slug}, _session, socket)
      when is_binary(account_id_or_slug) do
    case PortalWeb.Accounts.get_by_id_or_slug(account_id_or_slug) do
      # The authentication hooks run next and would send an unknown account to
      # sign-in, so a slug another region holds moves there from the mount.
      nil ->
        case PortalWeb.Accounts.other_region_url(account_id_or_slug, [], "") do
          nil -> {:cont, socket}
          url -> {:halt, redirect(socket, external: url)}
        end

      %Portal.Account{} = account ->
        socket =
          socket
          |> Phoenix.Component.assign(:account, account)
          |> attach_hook(:redirect_old_slug, :handle_params, &redirect_old_slug/3)

        {:cont, socket}
    end
  end

  def on_mount(:default, _params, _session, socket) do
    {:cont, socket}
  end

  # Live navigation can still carry an old slug, so the mount moves to the
  # current one before the view renders.
  defp redirect_old_slug(%{"account_id_or_slug" => account_id_or_slug}, uri, socket) do
    account = socket.assigns.account

    if PortalWeb.Accounts.old_slug?(account_id_or_slug, account) do
      {rest, query} = split_uri(uri)
      {:halt, redirect(socket, to: PortalWeb.Accounts.current_path(account, rest, query))}
    else
      {:cont, socket}
    end
  end

  defp redirect_old_slug(_params, _uri, socket), do: {:cont, socket}

  defp split_uri(uri) do
    %URI{path: path, query: query} = URI.parse(uri)
    [_first | rest] = path |> String.trim_leading("/") |> String.split("/") |> Enum.map(&URI.decode/1)
    {rest, query || ""}
  end

end
