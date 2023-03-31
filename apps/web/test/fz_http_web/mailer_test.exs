defmodule FzHttpWeb.MailerTest do
  use ExUnit.Case, async: true

  alias FzHttpWeb.Mailer
  import Swoosh.TestAssertions

  test "default_email contains from_email" do
    assert Mailer.default_email().from == {"", "test@firez.one"}
  end

  describe "with templates" do
    defmodule SampleEmail do
      use Phoenix.Swoosh,
        template_root: "test/fz_http_web/mailer_test",
        template_path: "sample_email"

      def test_heex(number) do
        Mailer.default_email()
        |> subject("testing")
        |> to("test@localhost")
        |> render_body("test_heex.html", %{title: "Testing!", number: number})
      end

      def test_multipart do
        Mailer.default_email()
        |> subject("testing")
        |> to("test@localhost")
        |> render_body(:test_multipart, %{})
      end
    end

    test "heex" do
      email = SampleEmail.test_heex(123)
      assert email.html_body == ~s|<h1 data-number="123">Testing!</h1>|
    end

    test "multipart" do
      email = SampleEmail.test_multipart()
      assert email.text_body == ~s|Welcome to TEXT\n|
      assert email.html_body == ~s|<h1>Welcome to HTML</h1>\n|
    end

    test "delivery" do
      SampleEmail.test_heex(0)
      |> Mailer.deliver!()

      assert_email_sent(
        subject: "testing",
        from: {"", "test@firez.one"},
        to: [{"", "test@localhost"}],
        html_body: ~s|<h1 data-number="0">Testing!</h1>|
      )
    end
  end
end
