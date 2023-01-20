defmodule FzHttpWeb.MFA.RegisterComponent do
  @moduledoc """
  MFA registration container
  """
  use FzHttpWeb, :live_component
  alias FzHttp.MFA

  @steps [
    {:pick_type, fields: ~w[type]a},
    {:register, fields: ~w[name]a},
    {:verify, fields: ~w[code]a},
    {:save, []}
  ]

  @impl Phoenix.LiveComponent
  def mount(socket) do
    secret = NimbleTOTP.secret()

    socket =
      socket
      |> assign(:secret, secret)
      |> assign(:params, %{"payload" => %{"secret" => Base.encode64(secret)}})
      |> assign(:remaining_steps, @steps)

    {:ok, socket}
  end

  @impl Phoenix.LiveComponent
  def update(assigns, socket) do
    changeset = MFA.create_method_changeset(socket.assigns.params, assigns.user.id)

    socket =
      socket
      |> assign(assigns)
      |> assign(:changeset, changeset)

    {:ok, socket}
  end

  @impl Phoenix.LiveComponent
  def render(%{remaining_steps: [{step, _opts} | _rest]} = assigns) do
    assigns = Map.put(assigns, :step, step)

    ~H"""
    <div id="register-mfa">
      <%= live_modal(
        FzHttpWeb.MFA.RegisterStepsComponent.render_step(%{
          secret: @secret,
          step: @step,
          changeset: @changeset,
          parent: @myself,
          user: @user
        }),
        return_to: @return_to,
        id: "register-mfa-modal",
        title: "Registering MFA Method",
        form: "mfa-method-form",
        button_text: if(@step == :save, do: "Save", else: "Next")
      ) %>
    </div>
    """
  end

  @impl Phoenix.LiveComponent
  def handle_event(
        "next",
        params,
        %{assigns: %{remaining_steps: [{_step, step_opts} | rest_steps]}} = socket
      ) do
    params = Map.merge(socket.assigns.params, params)
    changeset = MFA.create_method_changeset(params, socket.assigns.user.id)

    step_fields = Keyword.fetch!(step_opts, :fields)
    error_fields = changeset.errors |> Keyword.keys()

    if Enum.any?(step_fields, &(&1 in error_fields)) do
      socket = assign(socket, :changeset, render_changeset_errors(changeset))
      {:noreply, socket}
    else
      socket =
        socket
        # XXX: The form helpers should not render errors if changeset.action is nil,
        # but we use custom form helpers and they do not respect this,
        # so we need to reset list of errors every time we move to the next step.
        # https://hexdocs.pm/phoenix_html/Phoenix.HTML.Form.html#module-a-note-on-errors
        |> assign(:changeset, %{changeset | errors: []})
        |> assign(:params, params)
        |> assign(:remaining_steps, rest_steps)

      {:noreply, socket}
    end
  end

  @impl Phoenix.LiveComponent
  def handle_event("save", params, socket) do
    params = Map.merge(socket.assigns.params, params)

    case MFA.create_method(params, socket.assigns.user.id) do
      {:ok, _method} ->
        socket =
          socket
          |> put_flash(:info, "MFA method added!")
          |> push_redirect(to: socket.assigns.return_to)

        {:noreply, socket}

      {:error, changeset} ->
        socket =
          socket
          |> assign(:changeset, changeset)
          |> assign(:step, :save)

        {:noreply, socket}
    end
  end
end
