defmodule FzHttpWeb.LayoutView do
  use FzHttpWeb, :view

  alias FzCommon.FzCrypto

  require Logger

  @doc """
  Generate a random feedback email to avoid spam.
  """
  def feedback_recipient do
    "feedback-#{FzCrypto.rand_string(8)}@firez.one"
  end

  @doc """
  The application version from mix.exs.
  """
  def application_version do
    Application.spec(:fz_http, :vsn)
  end

  @doc """
  The current github sha, used to link to our Github repo
  """
  def github_sha do
    case System.cmd("git", ["rev-parse", "--short", "HEAD"]) do
      {result, 0} ->
        result |> String.trim()

      {_, _} ->
        Logger.warn("Could not get github SHA. Is this a git repo?")
        "deadbeef"
    end
  end

  @doc """
  Generate class for nav links
  """
  def nav_class("/", :devices), do: "is-active has-icon"
  def nav_class("/devices", :devices), do: "is-active has-icon"
  def nav_class("/rules", :rules), do: "is-active has-icon"
  def nav_class("/account", :account), do: "is-active has-icon"
  def nav_class(_, _), do: "has-icon"
end
