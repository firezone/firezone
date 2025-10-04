defmodule Web.UrlGenerator do
  @moduledoc """
  Generates URLs for use in emails and other domain-layer notifications.
  This breaks the circular dependency between Web and Domain apps.
  """

  use Phoenix.VerifiedRoutes,
    endpoint: Web.Endpoint,
    router: Web.Router

  @doc """
  Generates URL for the clients page with outdated clients filter.
  """
  def outdated_clients_url(account_id) do
    url(~p"/#{account_id}/clients?#{[clients_order_by: "clients:asc:last_seen_version"]}")
  end
end
