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
    content = image_fixture("png")

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
          content: png_with_size(2 * 1024 * 1024 + 1),
          type: "image/png"
        }
      ])

    assert {:error, [[_, :too_large]]} = render_upload(upload, "large.png")
    view |> form("#support-form", support: %{message: "Image"}) |> render_submit()
    refute_email_sent()
  end

  test "rejects oversized file bytes even when the client understates the size", %{view: view} do
    upload =
      file_input(view, "#support-form", :screenshot, [
        %{name: "oversized.png", content: image_fixture("png"), type: "image/png"}
      ])

    render_upload(upload, "oversized.png", 0)

    assert {:error, %{reason: :file_size_limit_exceeded}} =
             Phoenix.LiveViewTest.UploadClient.simulate_attacker_chunk(
               upload,
               "oversized.png",
               png_with_size(2 * 1024 * 1024 + 1)
             )

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

  for {extension, mime} <- [
        {"png", "image/png"},
        {"jpg", "image/jpeg"},
        {"gif", "image/gif"},
        {"webp", "image/webp"}
      ] do
    test "derives #{mime} from file bytes despite spoofed filename and browser MIME", %{
      view: view
    } do
      content = image_fixture(unquote(extension))
      # Both metadata fields are deliberately wrong; only file bytes are authoritative.
      {name, client_type} =
        if unquote(extension) == "jpg",
          do: {"misleading.png", "image/png"},
          else: {"misleading.jpg", "image/jpeg"}

      upload =
        file_input(view, "#support-form", :screenshot, [
          %{name: name, content: content, type: client_type}
        ])

      render_upload(upload, name)
      view |> form("#support-form", support: %{message: "Image"}) |> render_submit()

      assert_receive {:email, email}
      assert [attachment] = email.attachments
      assert attachment.content_type == unquote(mime)
      assert attachment.filename == "screenshot." <> unquote(extension)
      assert attachment.data == content
    end
  end

  for {kind, content} <- [
        {"HTML", "<!doctype html><script>alert(document.cookie)</script>"},
        {"SVG", "<svg xmlns='http://www.w3.org/2000/svg' onload='alert(1)'/>"},
        {"PDF", "%PDF-1.7"},
        {"executable", <<127, "ELF", 0, 0, 0, 0>>},
        {"ZIP", <<"PK", 3, 4, 0, 0, 0, 0>>},
        {"RIFF video", <<"RIFF", 32, 0, 0, 0, "AVI ", 0, 0, 0, 0>>},
        {"truncated PNG signature", <<137, "PNG\r\n", 26>>}
      ] do
    test "rejects #{kind} disguised as PNG without sending email or consuming quota", %{
      view: view,
      account: account
    } do
      upload =
        file_input(view, "#support-form", :screenshot, [
          %{name: "screenshot.png", content: unquote(content), type: "image/png"}
        ])

      render_upload(upload, "screenshot.png")

      assert view |> form("#support-form", support: %{message: "Image"}) |> render_submit() =~
               "Please upload a PNG, JPEG, GIF, or WebP image up to 2 MB."

      refute_email_sent()

      assert %{rows: [[0]]} =
               Portal.Repo.query!(
                 "SELECT count(*) FROM support_requests WHERE account_id = $1",
                 [Ecto.UUID.dump!(account.id)]
               )
    end
  end

  test "accepts an image exactly 2 MB", %{view: view} do
    content = png_with_size(2 * 1024 * 1024)

    upload =
      file_input(view, "#support-form", :screenshot, [
        %{name: "boundary.png", content: content, type: "image/png"}
      ])

    render_upload(upload, "boundary.png")
    view |> form("#support-form", support: %{message: "Image"}) |> render_submit()
    assert_receive {:email, email}
    assert [attachment] = email.attachments
    assert byte_size(attachment.data) == 2 * 1024 * 1024
  end

  test "cannot submit while an image upload is incomplete", %{view: view} do
    upload =
      file_input(view, "#support-form", :screenshot, [
        %{name: "pending.png", content: image_fixture("png"), type: "image/png"}
      ])

    render_upload(upload, "pending.png", 50)

    assert view |> form("#support-form", support: %{message: "Image"}) |> render_submit() =~
             "Please upload one image up to 2 MB."

    refute_email_sent()
  end

  test "limits the account to ten requests and allows requests after expiry", %{
    view: view,
    account: account
  } do
    for _ <- 1..10,
        do: assert({:ok, :reserved} = PortalWeb.SupportForm.Database.reserve(account.id))

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
    view |> element("#support-modal button[aria-label='Close modal']") |> render_click()
    refute has_element?(view, "#support-modal")
  end

  defp image_fixture(extension) do
    File.read!(Path.expand("../../fixtures/images/feedback.#{extension}", __DIR__))
  end

  # Add a valid PNG text chunk before IEND to reach an exact byte count without
  # using a fake image header or allocating a large decompressed image.
  defp png_with_size(size) do
    png = image_fixture("png")
    split = byte_size(png) - 12
    <<prefix::binary-size(^split), iend::binary>> = png
    data = "Comment" <> <<0>> <> String.duplicate("x", size - byte_size(png) - 20)
    chunk = "tEXt" <> data
    prefix <> <<byte_size(data)::32>> <> chunk <> <<:erlang.crc32(chunk)::32>> <> iend
  end
end
