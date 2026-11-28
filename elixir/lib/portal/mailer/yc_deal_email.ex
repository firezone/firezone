defmodule Portal.Mailer.YCDealEmail do
  @moduledoc false

  import Portal.Mailer
  import Swoosh.Email

  @booking_url "https://meetings.hubspot.com/jamil-bou-kheir"
  @sales_url "https://www.firezone.dev/contact/sales"

  def promotion_code_email(email, first_name, code, sign_up_url, expires_on) do
    steps = [
      {"Create your account.",
       [
         "Sign up at ",
         {:link, sign_up_url, sign_up_url},
         " for a free Starter account. Already on Firezone? Skip ahead."
       ]},
      {"Unlock your credit.",
       [
         "As an admin, open Settings → Account → Manage billing, pick Team or Business, ",
         "and enter your code before you confirm. Looking for Enterprise? ",
         {:link, @sales_url, "Request a demo"},
         " and mention you're YC."
       ]},
      {"Get an expert in your corner.",
       ["Book your free one-hour security review: ", {:link, @booking_url, @booking_url}]},
      {"Rep the brand.",
       ["Claim your T-shirt and sticker pack under Settings → Account → Request swag (US shipping only)."]}
    ]

    intro = [
      "Hi #{first_name || "there"},",
      "You're in! Your Firezone promo code is: #{code}",
      "Here's how to claim your perks:"
    ]

    outro = "The code works once and expires on #{expires_on}. Questions? Just reply to this email."

    default_email()
    |> to(email)
    |> reply_to("support@firezone.dev")
    |> subject("Your Firezone YC deal code")
    |> text_body(text_body(intro, steps, outro))
    |> html_body(html_body(intro, steps, outro))
  end

  defp text_body(intro, steps, outro) do
    numbered =
      steps
      |> Enum.with_index(1)
      |> Enum.map(fn {{title, parts}, index} -> "#{index}. #{title} #{Enum.map_join(parts, &text/1)}" end)

    Enum.join(intro ++ numbered ++ [outro], "\n\n") <> "\n"
  end

  defp html_body(intro, steps, outro) do
    items =
      Enum.map_join(steps, fn {title, parts} ->
        "<li><strong>#{escape(title)}</strong> #{Enum.map_join(parts, &html/1)}</li>"
      end)

    Enum.map_join(intro, &"<p>#{escape(&1)}</p>") <> "<ol>#{items}</ol><p>#{escape(outro)}</p>"
  end

  defp text({:link, url, url}), do: url
  defp text({:link, url, label}), do: "#{label} at #{url}"
  defp text(part), do: part

  defp html({:link, url, label}), do: ~s(<a href="#{escape(url)}">#{escape(label)}</a>)
  defp html(part), do: escape(part)

  defp escape(value), do: Plug.HTML.html_escape(value)
end
