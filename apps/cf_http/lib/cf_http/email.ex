defmodule CfHttp.Email do
  @moduledoc """
  Handles Email for the app
  """

  use Bamboo.Phoenix, view: CfHttpWeb.EmailView
  alias CfHttp.Users.PasswordReset

  @from "noreply@#{Application.compile_env(:cf_http, CfHttpWeb.Endpoint)[:url][:host]}"

  defp base_email(to) do
    new_email()
    |> put_html_layout({CfHttpWeb.LayoutView, "email.html"})
    |> from(@from)
    |> to(to)
  end

  def password_reset(%PasswordReset{} = password_reset) do
    base_email(password_reset.email)
    |> subject("CloudFire password reset")
    |> assign(:reset_token, password_reset.reset_token)
    |> render(:password_reset)
  end
end
