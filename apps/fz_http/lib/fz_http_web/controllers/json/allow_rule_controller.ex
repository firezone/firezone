defmodule FzHttpWeb.JSON.AllowRuleController do
  @moduledoc """
  REST API Controller for Rules.
  """

  use FzHttpWeb, :controller

  action_fallback(FzHttpWeb.JSON.FallbackController)

  alias FzHttp.{AllowRules, Gateways}

  def index(conn, _params) do
    # XXX: Add user-scoped rules
    rules = AllowRules.list_allow_rules()
    render(conn, "index.json", allow_rules: rules)
  end

  def create(conn, %{"allow_rule" => rule_params}) do
    with {:ok, rule} <-
           rule_params
           |> Map.put_new("gateway_id", Gateways.get_gateway!().id)
           |> AllowRules.create_allow_rule() do
      conn
      |> put_status(:created)
      |> put_resp_header("location", ~p"/v1/allow_rules/#{rule}")
      |> render("show.json", allow_rule: rule)
    end
  end

  def show(conn, %{"id" => id}) do
    rule = AllowRules.get_allow_rule!(id)
    render(conn, "show.json", allow_rule: rule)
  end

  def delete(conn, %{"id" => id}) do
    rule = AllowRules.get_allow_rule!(id)

    with {:ok, _rule} <- AllowRules.delete_allow_rule(rule) do
      send_resp(conn, :no_content, "")
    end
  end
end
