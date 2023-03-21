defmodule FzHttpWeb.JSON.RuleController do
  @moduledoc api_doc: [title: "Rules", group: "Rules"]
  @moduledoc """
  This endpoint allows an adminisrator to manage Rules.
  """
  use FzHttpWeb, :controller

  action_fallback(FzHttpWeb.JSON.FallbackController)

  alias FzHttp.Rules

  @doc api_doc: [summary: "List all Rules"]
  def index(conn, _params) do
    # XXX: Add user-scoped rules
    rules = Rules.list_rules()
    render(conn, "index.json", rules: rules)
  end

  @doc api_doc: [summary: "Create a Rule"]
  def create(conn, %{"rule" => rule_params}) do
    with {:ok, rule} <- Rules.create_rule(rule_params) do
      conn
      |> put_status(:created)
      |> put_resp_header("location", ~p"/v0/rules/#{rule}")
      |> render("show.json", rule: rule)
    end
  end

  @doc api_doc: [summary: "Get Rule by ID"]
  def show(conn, %{"id" => id}) do
    with {:ok, rule} <- Rules.fetch_rule_by_id(id) do
      render(conn, "show.json", rule: rule)
    end
  end

  @doc api_doc: [summary: "Update a Rule"]
  def update(conn, %{"id" => id, "rule" => rule_params}) do
    with {:ok, rule} <- Rules.fetch_rule_by_id(id),
         {:ok, rule} <- Rules.update_rule(rule, rule_params) do
      render(conn, "show.json", rule: rule)
    end
  end

  @doc api_doc: [summary: "Delete a Rule"]
  def delete(conn, %{"id" => id}) do
    with {:ok, rule} <- Rules.fetch_rule_by_id(id), {:ok, _rule} <- Rules.delete_rule(rule) do
      send_resp(conn, :no_content, "")
    end
  end
end
