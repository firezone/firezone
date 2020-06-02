defmodule FgHttpWeb.EmailView do
  use FgHttpWeb, :view

  def password_reset_url(password_reset) do
    link(
      "Click here to reset your password.",
      Routes.password_reset_path(:update, password_reset.reset_token)
    )
  end
end
