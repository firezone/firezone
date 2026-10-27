defmodule PortalWeb.LiveHooks.FetchAccount do
  import Phoenix.LiveView
  alias __MODULE__.Database

  def on_mount(:default, %{"account_id_or_slug" => account_id_or_slug}, _session, socket)
      when is_binary(account_id_or_slug) do
    case Database.get_account_by_id_or_slug(account_id_or_slug) do
      nil ->
        {:cont, socket}

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

    if PortalWeb.AccountSlugs.old_slug?(account_id_or_slug, account) do
      %URI{path: path, query: query} = URI.parse(uri)
      [_old_slug | rest] =
        path |> String.trim_leading("/") |> String.split("/") |> Enum.map(&URI.decode/1)

      {:halt,
       redirect(socket, to: PortalWeb.AccountSlugs.current_path(account, rest, query || ""))}
    else
      {:cont, socket}
    end
  end

  defp redirect_old_slug(_params, _uri, socket), do: {:cont, socket}

  defmodule Database do
    import Ecto.Query
    alias Portal.Safe
    alias Portal.Account

    def get_account_by_id_or_slug(id_or_slug) do
      slug_owner =
        from(s in Portal.AccountSlug, where: s.slug == ^id_or_slug, select: s.account_id)

      query =
        if Portal.Repo.valid_uuid?(id_or_slug),
          do:
            from(a in Account,
              where: a.id == ^id_or_slug or a.slug == ^id_or_slug or a.id in subquery(slug_owner)
            ),
          else:
            from(a in Account,
              where: a.slug == ^id_or_slug or a.id in subquery(slug_owner)
            )

      query |> Safe.unscoped() |> Safe.one()
    end
  end
end
