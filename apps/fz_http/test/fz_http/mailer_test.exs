defmodule FzHttp.MailerTest do
  use ExUnit.Case, async: true

  alias FzHttp.Mailer

  test "default_email contains from_email" do
    assert Mailer.default_email().from == {"", "test@firez.one"}
  end
end
