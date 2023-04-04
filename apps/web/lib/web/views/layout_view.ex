defmodule Web.LayoutView do
  use Web, :view
  import Web.Endpoint, only: [static_path: 1]

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
    Application.spec(:domain, :vsn)
  end
end
