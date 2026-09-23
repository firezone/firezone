defmodule PortalWeb.SupportFormTest do
  use PortalWeb.ConnCase, async: true

  import Portal.AccountFixtures
  import Portal.ActorFixtures
  import Swoosh.TestAssertions

  setup %{conn: conn} do
    account = account_fixture()
    actor = admin_actor_fixture(account: account)
    {:ok, view, _} = conn |> authorize_conn(actor) |> live(~p"/#{account}/actors")
    url = "https://app.firezone.dev/#{account.slug}/actors?search=test&sort=name#details"
    view |> element("#support-link") |> render_hook("open", %{url: url})
    %{view: view, account: account, actor: actor, url: url}
  end

  test "sends feedback with only requested context", %{
    view: view,
    account: account,
    actor: actor,
    url: url
  } do
    assert view |> form("#support-form", support: %{message: "Please help"}) |> render_submit() =~
             "Your feedback has been sent."

    assert_receive {:email, email}
    assert email.to == [{"", "support@firezone.dev"}]

    assert email.text_body ==
             "Account ID: #{account.id}\nActor ID: #{actor.id}\nURL: #{url}\n\nPlease help\n"

    assert email.reply_to == nil
    assert email.attachments == []
  end

  test "rejects empty and oversized feedback", %{view: view} do
    view |> form("#support-form", support: %{message: " "}) |> render_submit()
    assert has_element?(view, "#support-form")

    view
    |> element("#support-form")
    |> render_submit(%{"support" => %{"message" => String.duplicate("a", 1001)}})

    refute_email_sent()
    assert has_element?(view, "#support-form")
  end

  test "accepts exactly 1000 characters", %{view: view} do
    view
    |> form("#support-form", support: %{message: String.duplicate("a", 1000)})
    |> render_submit()

    assert_email_sent()
  end

  test "attaches an image with a generic filename", %{view: view} do
    content = <<137, "PNG\r\n", 26, "\n", 0, 0, 0, 0>>

    upload =
      file_input(view, "#support-form", :screenshot, [
        %{name: "private-name.png", content: content, type: "image/png"}
      ])

    render_upload(upload, "private-name.png")
    view |> form("#support-form", support: %{message: "Screenshot attached"}) |> render_submit()
    assert_receive {:email, email}
    assert [attachment] = email.attachments
    assert attachment.filename == "screenshot.png"
    assert attachment.data == content
    assert attachment.content_type == "image/png"
  end

  test "rejects uploads over 2 MB", %{view: view} do
    upload =
      file_input(view, "#support-form", :screenshot, [
        %{
          name: "large.png",
          content: String.duplicate("a", 2 * 1024 * 1024 + 1),
          type: "image/png"
        }
      ])

    assert {:error, [[_, :too_large]]} = render_upload(upload, "large.png")
    refute_email_sent()
  end

  test "rejects multiple screenshots", %{view: view} do
    files =
      for name <- ["one.png", "two.png"], do: %{name: name, content: "image", type: "image/png"}

    upload = file_input(view, "#support-form", :screenshot, files)
    assert {:error, _} = render_upload(upload, "one.png")
    refute_email_sent()
  end

  test "rejects unsupported file types", %{view: view} do
    upload =
      file_input(view, "#support-form", :screenshot, [
        %{name: "script.svg", content: "<svg></svg>", type: "image/svg+xml"}
      ])

    assert {:error, [[_, :not_accepted]]} = render_upload(upload, "script.svg")
    refute_email_sent()
  end

  test "rejects non-image contents even with an image extension", %{view: view} do
    upload =
      file_input(view, "#support-form", :screenshot, [
        %{name: "fake.png", content: "not an image", type: "image/png"}
      ])

    render_upload(upload, "fake.png")

    assert view |> form("#support-form", support: %{message: "Help"}) |> render_submit() =~
             "Please upload a PNG"

    refute_email_sent()
  end

  test "limits the account to ten requests and allows requests after expiry", %{
    view: view,
    account: account
  } do
    for _ <- 1..10, do: assert({:ok, :reserved} = Portal.Support.Database.reserve(account.id))

    assert view |> form("#support-form", support: %{message: "Help"}) |> render_submit() =~
             "You&#39;re doing that too frequently. Please slow down."

    refute_email_sent()

    Portal.Repo.query!(
      "UPDATE support_requests SET inserted_at = now() - interval '25 hours' WHERE account_id = $1",
      [Ecto.UUID.dump!(account.id)]
    )

    view |> form("#support-form", support: %{message: "Help"}) |> render_submit()
    assert_email_sent()
  end

  test "closing resets the form", %{view: view} do
    view |> form("#support-form", support: %{message: "Draft"}) |> render_change()
    view |> element("#support-modal button", "Close modal") |> render_click()
    refute has_element?(view, "#support-modal")
  end
end
