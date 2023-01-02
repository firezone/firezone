defmodule FzHttpWeb.LayoutView do
  use FzHttpWeb, :view
  import FzHttpWeb.Endpoint, only: [static_path: 1]

  @doc """
  Generate a random feedback email to avoid spam.
  """
  def feedback_recipient do
    "feedback@firezone.dev"
  end

  @doc """
  The application version from mix.exs.
  """
  def application_version do
    Application.spec(:fz_http, :vsn)
  end
end
