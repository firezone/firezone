defmodule PortalWeb.Components.CoreTest do
  use PortalWeb.ConnCase, async: true

  alias PortalWeb.Components.Core

  describe "Core.provider_icon/1" do
    test "adds icon_class to image icons" do
      html =
        render_component(&Core.provider_icon/1, provider: "google", size: "lg", icon_class: "sm:size-8")
        |> Floki.parse_fragment!()

      assert [class] = Floki.attribute(html, "img", "class")
      assert class =~ "size-6"
      assert class =~ "sm:size-8"
    end

    test "adds icon_class to font icons" do
      html =
        render_component(&Core.provider_icon/1, provider: "github", size: "lg", icon_class: "sm:size-8")
        |> Floki.parse_fragment!()

      assert [_icon] = Floki.find(html, ".ri-github-fill.size-6.sm\\:size-8")
    end

    test "only uses the size classes without icon_class" do
      html = render_component(&Core.provider_icon/1, provider: "google", size: "lg") |> Floki.parse_fragment!()

      assert Floki.attribute(html, "img", "class") == ["size-6"]
    end
  end

  describe "Core.avatar/1" do
    test "links the stored photo by its version" do
      account = %Portal.Account{id: Ecto.UUID.generate(), slug: "acme"}
      id = Ecto.UUID.generate()

      html =
        render_component(&Core.avatar/1,
          account: account,
          actor: %Portal.Actor{avatar_identity_id: id, avatar_etag: "etag-1"}
        )
        |> Floki.parse_fragment!()

      assert Floki.attribute(html, "img", "src") == ["/acme/avatars/#{id}?v=#{Portal.Avatars.version("etag-1")}"]
    end

    test "shows a user icon without a photo" do
      html =
        render_component(&Core.avatar/1, account: %Portal.Account{slug: "acme"}, actor: %Portal.Actor{})
        |> Floki.parse_fragment!()

      assert Floki.find(html, "img") == []
      assert [_icon] = Floki.find(html, ".ri-user-line")
    end
  end

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
