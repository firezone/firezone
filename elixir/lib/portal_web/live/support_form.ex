defmodule PortalWeb.SupportForm do
  use PortalWeb, :live_component

  alias __MODULE__.Database
  alias Portal.Mailer.FeedbackEmail

  @impl true
  def mount(socket) do
    {:ok,
     socket
     |> assign(open?: false, error: nil, sent?: false, url: nil)
     |> assign_form(%{})
     |> allow_upload(:screenshot,
       accept: ~w(.png .jpg .jpeg .gif .webp),
       max_entries: 1,
       max_file_size: 2 * 1024 * 1024
     )}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div>
      <button
        id="support-link"
        type="button"
        phx-hook="SupportForm"
        phx-target={@myself}
        class="text-sm text-body hover:text-heading"
      >Feedback</button>
      <.modal :if={@open?} id="support-modal" on_close="close" target={@myself}>
        <:title>{if @sent?, do: "Thank you for your feedback", else: "Submit feedback"}</:title>
        <:body>
          <div :if={@sent?} role="status" class="space-y-3">
            <p>Your feedback has been sent.</p>
            <p>We read every submission. We may follow up with questions or clarifications.</p>
          </div>
          <.form
            :if={!@sent?}
            for={@form}
            id="support-form"
            phx-target={@myself}
            phx-change="validate"
            phx-submit="submit"
            class="space-y-4"
          >
            <.input
              field={@form[:message]}
              type="textarea"
              label="What would you like to see improved?"
              maxlength="1000"
              required
              rows="6"
            />
            <p class="text-sm text-subtle">Up to 1,000 characters.</p>
            <.file_upload
              upload={@uploads.screenshot}
              label="Screenshot (optional)"
              cancel_event="cancel-upload"
              target={@myself}
              error_message={&upload_error/1}
            >
              <:hint>One PNG, JPEG, GIF, or WebP image, up to 2 MB.</:hint>
            </.file_upload>
            <.error :if={@error} role="alert">{@error}</.error>
          </.form>
        </:body>
        <:footer>
          <.button
            :if={@sent?}
            type="button"
            style="primary"
            phx-click="close"
            phx-target={@myself}
            class="ml-auto"
          >
            Done
          </.button>
          <.button
            :if={!@sent?}
            type="submit"
            form="support-form"
            style="primary"
            phx-disable-with="Sending…"
            class="ml-auto"
          >
            Submit feedback
          </.button>
        </:footer>
      </.modal>
    </div>
    """
  end

  @impl true
  def handle_event("open", %{"url" => url}, socket) do
    {:noreply, assign(socket, open?: true, url: url, sent?: false, error: nil)}
  end

  def handle_event("close", _, socket) do
    socket =
      Enum.reduce(
        socket.assigns.uploads.screenshot.entries,
        socket,
        &cancel_upload(&2, :screenshot, &1.ref)
      )

    {:noreply, socket |> assign(open?: false, error: nil) |> assign_form(%{})}
  end

  def handle_event("validate", %{"support" => params}, socket) do
    {:noreply, assign_form(socket, params, :validate)}
  end

  def handle_event("cancel-upload", %{"ref" => ref}, socket) do
    {:noreply, cancel_upload(socket, :screenshot, ref)}
  end

  def handle_event("submit", %{"support" => params}, socket) do
    changeset = changeset(params)
    {completed, pending} = uploaded_entries(socket, :screenshot)
    upload = socket.assigns.uploads.screenshot

    cond do
      socket.assigns.sent? ->
        {:noreply, socket}

      not changeset.valid? ->
        {:noreply, assign_form(socket, params, :validate)}

      pending != [] or upload_errors(upload) != [] or
          Enum.any?(completed, &(upload_errors(upload, &1) != [])) ->
        {:noreply, assign(socket, error: "Please upload one image up to 2 MB.")}

      true ->
        case submit(socket, params, completed) do
          {:ok, _} ->
            {:noreply, assign(socket, sent?: true, error: nil)}

          {:error, :rate_limited} ->
            {:noreply,
             assign(socket, error: "You're doing that too frequently. Please slow down.")}

          {:error, :invalid_image} ->
            {:noreply,
             assign(socket, error: "Please upload a PNG, JPEG, GIF, or WebP image up to 2 MB.")}

          {:error, _} ->
            {:noreply, assign(socket, error: "We couldn't send your feedback. Please try again.")}
        end
    end
  end

  defp submit(socket, params, []) do
    deliver_feedback(socket.assigns.subject, params, socket.assigns.url)
  end

  # sobelow_skip ["Traversal.FileModule"]
  defp submit(socket, params, [_entry]) do
    # `path` is LiveView's own temp upload path, not a client-supplied filename.
    socket
    |> consume_uploaded_entries(:screenshot, fn %{path: path}, _entry ->
      result =
        deliver_feedback(
          socket.assigns.subject,
          params,
          socket.assigns.url,
          File.read!(path)
        )

      case result do
        {:ok, _} -> {:ok, result}
        {:error, _} -> {:postpone, result}
      end
    end)
    |> List.first()
  end

  defp assign_form(socket, params, action \\ nil) do
    changeset = %{changeset(params) | action: action}
    assign(socket, form: to_form(changeset, as: :support))
  end

  defp upload_error(:too_large), do: "Image must be 2 MB or smaller."
  defp upload_error(:too_many_files), do: "Only one screenshot is allowed."
  defp upload_error(:not_accepted), do: "Use a PNG, JPEG, GIF, or WebP image."
  defp upload_error(_), do: "The image could not be uploaded. Please try again."

  defp changeset(params) do
    {%{}, %{message: :string}}
    |> Ecto.Changeset.cast(params, [:message])
    |> Ecto.Changeset.validate_required([:message])
    |> Ecto.Changeset.validate_length(:message, max: 1000)
  end

  defp deliver_feedback(subject, params, url, screenshot \\ nil) do
    with {:ok, %{message: message}} <- Ecto.Changeset.apply_action(changeset(params), :insert),
         :ok <- validate_url(url),
         {:ok, attachment} <- attachment(screenshot),
         {:ok, :reserved} <- Database.reserve(subject.account.id) do
      subject
      |> FeedbackEmail.feedback_email(message, url, attachment)
      |> Portal.Mailer.deliver()
    end
  end

  defp validate_url(url) when is_binary(url) and byte_size(url) <= 16_384 do
    case URI.parse(url) do
      %URI{scheme: scheme, host: host} when scheme in ["http", "https"] and is_binary(host) -> :ok
      _ -> {:error, :invalid_url}
    end
  end

  defp validate_url(_), do: {:error, :invalid_url}

  defp attachment(nil), do: {:ok, nil}

  defp attachment(data) when is_binary(data) and byte_size(data) <= 2 * 1024 * 1024 do
    case image_type(data) do
      {extension, type} ->
        {:ok,
         Swoosh.Attachment.new({:data, data},
           filename: "screenshot.#{extension}",
           content_type: type
         )}

      nil ->
        {:error, :invalid_image}
    end
  end

  defp attachment(_), do: {:error, :invalid_image}

  defp image_type(<<137, "PNG\r\n", 26, "\n", _::binary>>), do: {"png", "image/png"}
  defp image_type(<<255, 216, 255, _::binary>>), do: {"jpg", "image/jpeg"}

  defp image_type(<<"GIF", version::binary-size(3), _::binary>>) when version in ["87a", "89a"],
    do: {"gif", "image/gif"}

  defp image_type(<<"RIFF", _::binary-size(4), "WEBP", _::binary>>), do: {"webp", "image/webp"}
  defp image_type(_), do: nil

  defmodule Database do
    @moduledoc false
    alias Portal.Safe

    # Serialize reservations across nodes. Store only timestamps, never feedback or images.
    def reserve(account_id) do
      account_id = Ecto.UUID.dump!(account_id)

      Safe.unscoped()
      |> Safe.transaction(fn ->
        query!("SELECT id FROM accounts WHERE id = $1 FOR UPDATE", [account_id])

        query!(
          "DELETE FROM feedback_submissions WHERE account_id = $1 AND inserted_at <= now() - interval '24 hours'",
          [account_id]
        )

        %{rows: [[count]]} =
          query!("SELECT count(*) FROM feedback_submissions WHERE account_id = $1", [account_id])

        if count >= 10 do
          {:error, :rate_limited}
        else
          query!(
            "INSERT INTO feedback_submissions (account_id, inserted_at) VALUES ($1, clock_timestamp())",
            [account_id]
          )

          {:ok, :reserved}
        end
      end)
    end

    defp query!(sql, params) do
      {:ok, result} = Safe.unscoped() |> Safe.query(sql, params)
      result
    end
  end
end
