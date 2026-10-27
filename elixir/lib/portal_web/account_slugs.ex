defmodule PortalWeb.AccountSlugs do
  @moduledoc """
  Tells an old account slug in a URL apart from the current one, and builds the
  path that the request moves to.
  """

  @spec old_slug?(String.t(), Portal.Account.t()) :: boolean()
  def old_slug?(account_id_or_slug, %Portal.Account{} = account) do
    account_id_or_slug != account.id and
      String.downcase(account_id_or_slug) != String.downcase(account.slug || "")
  end

  @spec current_path(Portal.Account.t(), [String.t()], String.t()) :: String.t()
  def current_path(%Portal.Account{} = account, rest, query_string) do
    path =
      Enum.map_join([account.slug | rest], "/", fn segment ->
        URI.encode(segment, &URI.char_unreserved?/1)
      end)

    if query_string == "" do
      "/" <> path
    else
      "/" <> path <> "?" <> query_string
    end
  end
end
