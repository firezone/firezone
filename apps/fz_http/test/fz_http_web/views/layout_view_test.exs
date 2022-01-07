defmodule FzHttpWeb.LayoutViewTest do
  use FzHttpWeb.ConnCase, async: true

  alias FzHttpWeb.LayoutView

  # When testing helpers, you may want to import Phoenix.HTML and
  # use functions such as safe_to_string() to convert the helper
  # result into an HTML string.
  # import Phoenix.HTML
  describe "nav_class/2" do
    test "it computes nav class for root route" do
      assert LayoutView.nav_class(%{request_path: "/"}, ~r"devices") == "is-active has-icon"
    end

    test "it computes nav class for account route" do
      assert LayoutView.nav_class(%{request_path: "/account"}, ~r"account") ==
               "is-active has-icon"
    end

    test "it defaults to has-icon" do
      assert LayoutView.nav_class(%{request_path: "Blah"}, ~r"foo") == "has-icon"
    end
  end
end
