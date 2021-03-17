defmodule FgHttpWeb.RulesLive do
  @moduledoc """
  Handles live views for Rules.
  """

  alias FgHttp.Rules
  use Phoenix.LiveView
  use Phoenix.HTML

  def mount(_params, session, socket) do
    locals = %{
      action_value: session["action_value"],
      rules: session["rules"],
      changeset: session["changeset"],
      device: session["device"]
    }

    {:ok, assign(socket, locals)}
  end

  def handle_event("save", params, socket) do
    # XXX: Check that user_id is allowed to save
    case Rules.create_rule(params["rule"]) do
      {:ok, rule} ->
        rules = Rules.like(rule)
        {:noreply, assign(socket, rules: rules)}

      {:error, changeset} ->
        {:noreply, assign(socket, changeset: changeset)}
    end
  end
end
