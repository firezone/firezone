defmodule Portal.Mailer.YCDealEmail do
  @moduledoc false

  import Portal.Mailer
  import Swoosh.Email

  def promotion_code_email(email, first_name, code, sign_up_url) do
    paragraphs = [
      "Hi #{first_name || "there"},",
      "Thanks for redeeming the Firezone YC deal. Your promo code is: #{code}",
      "To use it:",
      "1. Sign up at #{sign_up_url} (skip this step if you already have an account).",
      "2. As an admin, go to Settings → Account and click Manage billing.",
      "3. Choose a paid plan and enter the code before you confirm.",
      "The code works once. Reply to this email if you need help."
    ]

    default_email()
    |> to(email)
    |> reply_to("support@firezone.dev")
    |> subject("Your Firezone YC deal code")
    |> text_body(Enum.join(paragraphs, "\n\n") <> "\n")
    |> html_body(Enum.map_join(paragraphs, &"<p>#{Plug.HTML.html_escape(&1)}</p>"))
  end
end
