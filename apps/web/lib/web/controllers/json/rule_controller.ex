defmodule Web.JSON.RuleController do
  @moduledoc api_doc: [title: "Rules", group: "Rules"]
  @moduledoc """
  This endpoint allows an adminisrator to manage Rules.
  """
  use Web, :controller
  alias Domain.Rules
  alias Web.Auth.JSON.Authentication

  action_fallback(Web.JSON.FallbackController)

  @doc api_doc: [summary: "List all Rules"]
  def index(conn, _params) do
    subject = Authentication.get_current_subject(conn)

    with {:ok, rules} <- Rules.list_rules(subject) do
      render(conn, "index.json", rules: rules)
    end
  end

  @doc api_doc: [summary: "Create a Rule"]
  def create(conn, %{"rule" => attrs}) do
    subject = Authentication.get_current_subject(conn)

    with {:ok, rule} <- Rules.create_rule(attrs, subject) do
      conn
      |> put_status(:created)
      |> put_resp_header("location", ~p"/v0/rules/#{rule}")
      |> render("show.json", rule: rule)
    end
  end

  @doc api_doc: [summary: "Get Rule by ID"]
  def show(conn, %{"id" => id}) do
    subject = Authentication.get_current_subject(conn)

    with {:ok, rule} <- Rules.fetch_rule_by_id(id, subject) do
      render(conn, "show.json", rule: rule)
    end
  end

  @doc api_doc: [summary: "Update a Rule"]
  def update(conn, %{"id" => id, "rule" => attrs}) do
    subject = Authentication.get_current_subject(conn)

    with {:ok, rule} <- Rules.fetch_rule_by_id(id, subject),
         {:ok, rule} <- Rules.update_rule(rule, attrs, subject) do
      render(conn, "show.json", rule: rule)
    end
  end

  @doc api_doc: [summary: "Delete a Rule"]
  def delete(conn, %{"id" => id}) do
    subject = Authentication.get_current_subject(conn)

    with {:ok, rule} <- Rules.fetch_rule_by_id(id, subject),
         {:ok, _rule} <- Rules.delete_rule(rule, subject) do
      send_resp(conn, :no_content, "")
    end
  end
end
