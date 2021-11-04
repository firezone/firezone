defmodule FzHttpWeb.LayoutView do
  use FzHttpWeb, :view

  alias FzCommon.FzCrypto

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
  Generate class for nav links
  """
  def nav_class("/", :devices), do: "is-active has-icon"
  def nav_class("/devices", :devices), do: "is-active has-icon"
  def nav_class("/rules", :rules), do: "is-active has-icon"
  def nav_class("/account", :account), do: "is-active has-icon"
  def nav_class(_, _), do: "has-icon"
end
