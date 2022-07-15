defmodule FzHttpWeb.SettingLive.CustomizationTest do
  use FzHttpWeb.ConnCase, async: false

  alias FzHttp.Conf

  describe "logo" do
    setup %{admin_conn: conn} = context do
      Conf.update_configuration(%{logo: context[:logo]})

      path = Routes.setting_customization_path(conn, :show)
      {:ok, view, html} = live(conn, path)

      {:ok, view: view, html: html}
    end

    test "show default", %{html: html} do
      assert html =~ ~s|<input type="radio" name="logo" value="Default" checked|
    end

    @tag logo: %{"url" => "test"}
    test "show url", %{html: html} do
      assert html =~ ~s|<input type="radio" name="logo" value="URL" checked|
    end

    @tag logo: %{"data" => "test", "type" => "test"}
    test "show upload", %{html: html} do
      assert html =~ ~s|<input type="radio" name="logo" value="Upload" checked|
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

    @tag logo: %{"url" => "test"}
    test "reset to default", %{view: view, html: html} do
      html =~ ~s|<form id="url-form"|
      view |> element("input[value=Default]") |> render_click()
      view |> element("form") |> render_submit()

      assert nil == Conf.get(:logo)
    end

    test "change to url", %{view: view, html: html} do
      html =~ ~s|<form id="default-form"|
      view |> element("input[value=URL]") |> render_click()
      view |> render_submit("save", %{"url" => "new"})

      assert %{"url" => "new"} == Conf.get(:logo)
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
      assert %{"data" => Base.encode64("new"), "type" => "image/jpeg"} == Conf.get(:logo)
    end
  end
end
