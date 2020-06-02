defmodule FgHttp.Email do
  @moduledoc """
  Handles Email for the app
  """

  import Bamboo.{Email, Phoenix}
  alias FgHttp.Users.PasswordReset

  @from "noreply@#{Application.get_env(:fg_http, FgHttpWeb.Endpoint)[:url][:host]}"

  defp base_email(to) do
    new_email()
    |> from(@from)
    |> to(to)
  end

  def password_reset(%PasswordReset{} = password_reset) do
    base_email(password_reset.email)
    |> subject("FireGuard password reset")
    |> put_html_layout({FgHttpWeb.LayoutView, "email.html.eex"})
  end
end
