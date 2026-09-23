defmodule PortalWeb.SupportForm do
  use PortalWeb, :live_component

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
      >Support</button>
      <.modal :if={@open?} id="support-modal" on_close="close" target={@myself}>
        <:title>Contact support</:title>
        <:body>
          <p :if={@sent?} role="status">Your support request has been sent.</p>
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
              label="How can we help?"
              maxlength="1000"
              required
              rows="6"
            />
            <p class="text-sm text-subtle">Up to 1,000 characters.</p>
            <label for={@uploads.screenshot.ref} class="block text-sm">Screenshot (optional)</label>
            <.live_file_input upload={@uploads.screenshot} />
            <p class="text-sm text-subtle">One PNG, JPEG, GIF, or WebP image, up to 2 MB.</p>
            <p :for={error <- upload_errors(@uploads.screenshot)} role="alert">
              {upload_error(error)}
            </p>
            <div :for={entry <- @uploads.screenshot.entries}>
              <span>{entry.client_name}</span>
              <button
                type="button"
                phx-click="cancel-upload"
                phx-target={@myself}
                phx-value-ref={entry.ref}
              >Remove</button>
              <p :for={error <- upload_errors(@uploads.screenshot, entry)} role="alert">
                {upload_error(error)}
              </p>
            </div>
            <p :if={@error} role="alert" class="text-danger">{@error}</p>
            <.button type="submit" phx-disable-with="Sending…">Send request</.button>
          </.form>
        </:body>
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
    changeset = Portal.Support.changeset(params)
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
            {:noreply, assign(socket, error: "We couldn't send your request. Please try again.")}
        end
    end
  end

  defp submit(socket, params, []) do
    Portal.Support.submit(socket.assigns.subject, params, socket.assigns.url)
  end

  defp submit(socket, params, [_entry]) do
    socket
    |> consume_uploaded_entries(:screenshot, fn %{path: path}, _entry ->
      result =
        Portal.Support.submit(
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
    changeset = %{Portal.Support.changeset(params) | action: action}
    assign(socket, form: to_form(changeset, as: :support))
  end

  defp upload_error(:too_large), do: "Image must be 2 MB or smaller."
  defp upload_error(:too_many_files), do: "Only one screenshot is allowed."
  defp upload_error(:not_accepted), do: "Use a PNG, JPEG, GIF, or WebP image."
  defp upload_error(_), do: "The image could not be uploaded. Please try again."
end
