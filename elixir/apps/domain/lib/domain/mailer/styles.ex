defmodule Domain.Mailer.Styles do
  @moduledoc """
  Provides shared styles for email templates.
  """

  @external_resource Path.join(__DIR__, "styles/dark_mode_styles.html.eex")
  @dark_mode_styles File.read!(Path.join(__DIR__, "styles/dark_mode_styles.html.eex"))

  @doc """
  Returns the dark mode CSS styles for email templates.
  """
  def dark_mode_styles, do: @dark_mode_styles
end
