defmodule FzHttpWeb.JSON.RuleController do
  @moduledoc """
  REST API Controller for Rules.
  """

  use FzHttpWeb, :controller

  action_fallback(FzHttpWeb.JSON.FallbackController)

  alias FzHttp.{AllowRules, Gateways}

  def index(conn, _) do
    send_upgrade_notice(conn)
  end

  def create(conn, _) do
    send_upgrade_notice(conn)
  end

  def show(conn, _) do
    send_upgrade_notice(conn)
  end

  def delete(conn, _) do
    send_upgrade_notice(conn)
  end

  def update(conn, _) do
    send_upgrade_notice(conn)
  end

  defp send_upgrade_notice(conn) do
    # XXX: Update message
    send_resp(conn, 400, "Legacy rules have been removed. Please see: [TODO]")
  end
end
