defmodule PortalWeb.Components.NavigationLinkTest do
  use ExUnit.Case, async: true
  use Phoenix.Component

  import Phoenix.LiveViewTest

  alias PortalWeb.Components.Navigation

  test "renders text links with the default styling and slot content" do
    html = render_link(%{href: "/resources"})

    assert Floki.attribute(html, "a", "href") == ["/resources"]
    assert Floki.attribute(html, "a", "class") == ["text-link hover:underline"]
    assert Floki.text(html) == "Resources"
  end

  test "custom classes replace the defaults" do
    html = render_link(%{href: "/resources", class: ["button", nil, "active"]})

    assert Floki.attribute(html, "a", "class") == ["button active"]
    assert Floki.attribute(render_link(%{href: "/resources", class: nil}), "a", "class") == []
  end

  test "forwards live navigation and history replacement" do
    for {attribute, kind} <- [navigate: "redirect", patch: "patch"], replace <- [false, true] do
      html = render_link(%{attribute => "/resources", :replace => replace})

      assert Floki.attribute(html, "a", "href") == ["/resources"]
      assert Floki.attribute(html, "a", "data-phx-link") == [kind]
      assert Floki.attribute(html, "a", "data-phx-link-state") ==
               [if(replace, do: "replace", else: "push")]
    end
  end

  test "forwards non-GET methods and CSRF options" do
    html = render_link(%{href: "/sign_out", method: "delete", csrf_token: "test-token"})

    assert Floki.attribute(html, "a", "data-method") == ["delete"]
    assert Floki.attribute(html, "a", "data-to") == ["/sign_out"]
    assert Floki.attribute(html, "a", "data-csrf") == ["test-token"]

    html = render_link(%{href: "/sign_out", method: "delete", csrf_token: false})
    assert Floki.attribute(html, "a", "data-csrf") == []
  end

  test "forwards global and anchor attributes" do
    html =
      render_link(%{
        href: "https://example.com",
        target: "_blank",
        rel: "noopener noreferrer",
        download: "resources.csv",
        "aria-label": "Download resources",
        "phx-click": "download"
      })

    for {attribute, value} <- [
          {"target", "_blank"},
          {"rel", "noopener noreferrer"},
          {"download", "resources.csv"},
          {"aria-label", "Download resources"},
          {"phx-click", "download"}
        ] do
      assert Floki.attribute(html, "a", attribute) == [value]
    end
  end

  test "preserves Phoenix fallback links and rejects unsafe destinations" do
    assert Floki.attribute(render_link(%{}), "a", "href") == ["#"]

    assert_raise ArgumentError, fn ->
      render_link(%{href: "javascript:alert(1)"})
    end
  end

  defp render_link(attrs) do
    render_component(&link_fixture/1, attrs: attrs)
    |> Floki.parse_fragment!()
  end

  defp link_fixture(assigns) do
    ~H"""
    <Navigation.link {@attrs}><span>Resources</span></Navigation.link>
    """
  end
end
