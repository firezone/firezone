defmodule PortalWeb.CoreComponentsTest do
  use PortalWeb.ConnCase, async: true

  import PortalWeb.CoreComponents

  describe "relative_datetime/1" do
    test "renders Never for a nil datetime without a popover" do
      html = render_component(&relative_datetime/1, datetime: nil, popover: false)

      assert html =~ "Never"
    end

    test "renders Never for a nil datetime with the default popover" do
      html = render_component(&relative_datetime/1, datetime: nil)

      assert html =~ "Never"
    end

    test "renders custom empty text for a nil datetime" do
      html = render_component(&relative_datetime/1, datetime: nil, empty: "Unknown")

      assert html =~ "Unknown"
      refute html =~ "Never"
    end

    test "renders relative text for a datetime without a popover" do
      html =
        render_component(&relative_datetime/1,
          datetime: ~U[2026-01-27 11:55:00Z],
          relative_to: ~U[2026-01-27 12:00:00Z],
          popover: false
        )

      assert html =~ "5 minutes ago"
    end
  end
end
