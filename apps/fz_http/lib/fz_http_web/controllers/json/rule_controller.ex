defmodule FzHttpWeb.JSON.RuleController do
  @moduledoc """
  REST API Controller for Rules.
  """

  use FzHttpWeb, :controller

  action_fallback FzHttpWeb.JSON.FallbackController

  alias FzHttp.Rules

  def index(conn, _params) do
    # XXX: Add user-scoped rules
    rules = Rules.list_rules()
    render(conn, "index.json", rules: rules)
  end

  def create(conn, %{"rule" => rule_params}) do
    with {:ok, rule} <- Rules.create_rule(rule_params) do
      conn
      |> put_status(:created)
      |> put_resp_header("location", ~p"/v1/rules/#{rule}")
    end
  end

  def show(conn, %{"id" => id}) do
    rule = Rules.get_rule!(id)
    render(conn, "show.json", rule: rule)
  end

  def update(conn, %{"id" => id, "rule" => rule_params}) do
    rule = Rules.get_rule!(id)

    with {:ok, rule} <- Rules.update_rule(rule, rule_params) do
      render(conn, "show.json", rule: rule)
    end
  end

  def delete(conn, %{"id" => id}) do
    rule = Rules.get_rule!(id)

    with {:ok, _rule} <- Rules.delete_rule(rule) do
      send_resp(conn, :no_content, "")
    end
  end
end
