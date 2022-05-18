defmodule FzHttpWeb.LayoutView do
  use FzHttpWeb, :view

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

  @doc """
  The current github sha, used to link to our Github repo.
  This is set during application compile time.
  """
  def git_sha do
    Application.fetch_env!(:fz_http, :git_sha)
  end
end
