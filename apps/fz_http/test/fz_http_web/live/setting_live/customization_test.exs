defmodule FzHttpWeb.SettingLive.CustomizationTest do
  use FzHttpWeb.ConnCase, async: true

  describe "logo" do
    setup %{admin_conn: conn} = context do
      FzHttp.Config.put_config!(:logo, context[:logo])

      path = ~p"/settings/customization"
      {:ok, view, html} = live(conn, path)

      {:ok, view: view, html: html}
    end

    @tag logo: nil
    test "show default", %{html: html} do
      assert html =~ ~s|value="Default" checked|
    end

    @tag logo: %{url: "test"}
    test "show url", %{html: html} do
      assert html =~ ~s|value="URL" checked|
    end

    @tag logo: %{data: "test", type: "test"}
    test "show upload", %{html: html} do
      assert html =~ ~s|value="Upload" checked|
    end

    test "click default radio", %{view: view} do
      assert view
             |> element("input[value=Default]")
             |> render_click() =~ ~s|<form id="default-form"|
    end

    test "click url radio", %{view: view} do
      assert view
             |> element("input[value=URL]")
             |> render_click() =~ ~s|<form id="url-form"|
    end

    test "click upload radio", %{view: view} do
      assert view
             |> element("input[value=Upload]")
             |> render_click() =~ ~s|<form id="upload-form"|
    end

    @tag logo: %{url: "test"}
    test "reset to default", %{view: view, html: html} do
      html =~ ~s|<form id="url-form"|
      view |> element("input[value=Default]") |> render_click()
      view |> element("form") |> render_submit()

      assert FzHttp.Config.fetch_config!(:logo) == nil
    end

    test "change to url", %{view: view, html: html} do
      html =~ ~s|<form id="default-form"|
      view |> element("input[value=URL]") |> render_click()
      view |> render_submit("save", %{"url" => "new"})

      assert %{url: "new"} = FzHttp.Config.fetch_config!(:logo)
    end

    test "change to upload", %{view: view, html: html} do
      html =~ ~s|<form id="default-form"|
      view |> element("input[value=Upload]") |> render_click()

      view
      |> file_input("#upload-form", :logo, [
        %{
          last_modified: 0,
          name: "logo.jpeg",
          content: "new",
          size: 3,
          type: "image/jpeg"
        }
      ])
      |> render_upload("logo.jpeg")

      view |> render_submit("save", %{})

      data = Base.encode64("new")
      assert %{data: ^data, type: "image/jpeg"} = FzHttp.Config.fetch_config!(:logo)
    end
  end
end
