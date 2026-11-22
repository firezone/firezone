defmodule PortalWeb.Components.PageTest do
  use PortalWeb.ConnCase, async: true

  alias PortalWeb.Components.Page

  describe "Page.account_button/1" do
    setup do
      %{account: %Portal.Account{id: Ecto.UUID.generate(), name: "Acme", slug: "acme"}}
    end

    test "links the account and shows the chevron by default", %{account: account} do
      html =
        render_component(&Page.account_button/1, account: account, href: "/acme/sign_in")
        |> Floki.parse_fragment!()

      assert Floki.attribute(html, "a", "href") == ["/acme/sign_in"]
      assert Floki.text(html) =~ "Acme"
      assert [_chevron] = Floki.find(html, ".ri-arrow-right-s-line")
    end

    test "hides the chevron and adds classes when asked", %{account: account} do
      html =
        render_component(&Page.account_button/1,
          account: account,
          href: "/acme/sign_in",
          arrow: false,
          class: "pr-14"
        )
        |> Floki.parse_fragment!()

      assert Floki.find(html, ".ri-arrow-right-s-line") == []
      assert [class] = Floki.attribute(html, "a", "class")
      assert class =~ "pr-14"
    end
  end

  describe "Page.account_slug_form/1" do
    test "shows the portal's URL and a slash in front of the slug input" do
      %URI{scheme: scheme, host: host, port: port} = PortalWeb.Endpoint.struct_url()

      html =
        render_component(&Page.account_slug_form/1, action: "/sign_in")
        |> Floki.parse_fragment!()

      assert html |> Floki.find("#account-slug-host") |> Floki.text() |> String.trim() == "#{scheme}://#{host}:#{port}/"
      assert [input] = Floki.find(html, "form[action='/sign_in'] label > input[name=account_id_or_slug]")
      assert [_host] = Floki.find(html, "label > #account-slug-host")
      assert Floki.attribute(input, "aria-describedby") == ["account-slug-host"]
      assert Floki.attribute(input, "aria-label") == ["Organization sign-in URL"]
      assert Floki.text(html) =~ "Your organization's sign-in URL"
      refute Floki.text(html) =~ "slug"
      assert Floki.attribute(input, "placeholder") == ["acme_corp"]
    end
  end
end
