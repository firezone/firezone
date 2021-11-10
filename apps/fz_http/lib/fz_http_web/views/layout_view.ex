defmodule FzHttpWeb.LayoutView do
  use FzHttpWeb, :view

  alias FzCommon.FzCrypto

  require Logger

  @github_sha Application.compile_env(:fz_http, :github_sha, "master")

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
    @github_sha
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
