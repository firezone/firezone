defmodule PortalWeb.Dev.ColorsLiveTest do
  use PortalWeb.ConnCase, async: true

  @main_css Path.expand("../../../../assets/css/main.css", __DIR__)
  @external_resource @main_css

  test "renders a swatch for every semantic color token", %{conn: conn} do
    {:ok, _lv, html} = live(conn, ~p"/dev/colors")

    [theme] = Regex.run(~r/@theme \{(.*?)\n\}/s, File.read!(@main_css), capture: :all_but_first)
    tokens = Regex.scan(~r/--color-([a-z0-9-]+):/, theme, capture: :all_but_first) |> List.flatten()

    assert tokens != []

    swatch_classes =
      html
      |> Floki.parse_document!()
      |> Floki.find("[phx-value-class]")
      |> Floki.attribute("phx-value-class")

    missing = Enum.reject(tokens, &("bg-#{&1}" in swatch_classes))

    assert missing == [], "Tokens missing from /dev/colors: #{Enum.join(missing, ", ")}"
  end
end
