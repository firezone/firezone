defmodule PortalWeb.Components.CoreTest do
  use PortalWeb.ConnCase, async: true

  alias PortalWeb.Components.Core

  describe "Core.copy/1" do
    test "renders the messages the CopyClipboard hook swaps after a copy" do
      html =
        render_component(&Core.copy/1, id: "slug", inner_block: [%{inner_block: fn _, _ -> "acme" end}])
        |> Floki.parse_fragment!()

      assert [_] = Floki.find(html, "#slug[phx-hook=CopyClipboard]")
      assert [_] = Floki.find(html, ~s(button[data-copy-to-clipboard-target="slug-code"]))
      assert Floki.find(html, "#slug-code") |> Floki.text() == "acme"

      assert [_] = Floki.find(html, "#slug-default-message:not(.hidden)")
      assert [success] = Floki.find(html, "#slug-success-message.hidden[role=status]")
      assert Floki.text(success) =~ "Copied"
    end
  end

  describe "Core.relative_datetime/1" do
    test "renders Never for a nil datetime without a popover" do
      html = render_component(&Core.relative_datetime/1, datetime: nil, popover: false)

      assert html =~ "Never"
    end

    test "renders Never for a nil datetime with the default popover" do
      html = render_component(&Core.relative_datetime/1, datetime: nil)

      assert html =~ "Never"
    end

    test "renders custom empty text for a nil datetime" do
      html = render_component(&Core.relative_datetime/1, datetime: nil, empty: "Unknown")

      assert html =~ "Unknown"
      refute html =~ "Never"
    end

    test "renders relative text for a datetime without a popover" do
      html =
        render_component(&Core.relative_datetime/1,
          datetime: ~U[2026-01-27 11:55:00Z],
          relative_to: ~U[2026-01-27 12:00:00Z],
          popover: false
        )

      assert html =~ "5 minutes ago"
    end
  end
end
