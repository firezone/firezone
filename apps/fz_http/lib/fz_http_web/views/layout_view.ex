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
  The current github sha, used to link to our Github repo.
  This is set during application compile time.
  """
  def github_sha do
    Application.get_env(:fz_http, :github_sha, "master")
  end

  @doc """
  Generate class for nav links
  """
  def nav_class(request_path, section) do
    top_level =
      request_path
      |> String.split("/", trim: true)
      |> List.first("devices")

    active =
      if top_level == section do
        "is-active"
      else
        ""
      end

    Enum.join([active, "has-icon"], " ")
  end
end
