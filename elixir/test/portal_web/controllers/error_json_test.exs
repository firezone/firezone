defmodule PortalWeb.ErrorJSONTest do
  use PortalWeb.ConnCase, async: true

  test "renders 404" do
    assert PortalWeb.ErrorJSON.render("404.json", %{}) == %{errors: %{detail: "Not Found"}}
  end

  test "renders 500" do
    assert PortalWeb.ErrorJSON.render("500.json", %{}) ==
             %{errors: %{detail: "internal_error"}}
  end
end
