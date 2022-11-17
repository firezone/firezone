defmodule FzHttpWeb.MFA.RegisterComponent do
  @moduledoc """
  MFA registration container
  """
  use FzHttpWeb, :live_component

  import Ecto.Changeset
  alias FzHttp.{MFA, Repo}

  @steps ~w(pick_type register verify save)a
  @next_steps @steps |> Enum.zip(Enum.drop(@steps, 1)) |> Map.new()

  @impl Phoenix.LiveComponent
  def mount(socket) do
    {:ok, socket |> assign(%{step: :pick_type, changeset: MFA.new_method()})}
  end

  @impl Phoenix.LiveComponent
  def render(assigns) do
    ~H"""
    <div id="register-mfa">
      <%= live_modal(
        FzHttpWeb.MFA.RegisterStepsComponent.render_step(%{
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
  def handle_event("next", params, %{assigns: %{step: :verify, changeset: changeset}} = socket) do
    changeset = MFA.change_method(apply_changes(changeset), params)

    next_step =
      if changeset.valid? do
        Map.fetch!(@next_steps, :verify)
      else
        :verify
      end

    {:noreply,
     socket
     |> assign(:changeset, changeset)
     |> assign(:step, next_step)}
  end

  @impl Phoenix.LiveComponent
  def handle_event("next", params, %{assigns: %{step: step, changeset: changeset}} = socket) do
    {:noreply,
     socket
     |> assign(:changeset, MFA.change_method(apply_changes(changeset), params))
     |> assign(:step, Map.fetch!(@next_steps, step))}
  end

  @impl Phoenix.LiveComponent
  def handle_event("save", _params, %{assigns: %{changeset: changeset}} = socket) do
    changeset = put_change(changeset, :user_id, socket.assigns.user.id)

    case Repo.insert(changeset) do
      {:ok, _method} ->
        {:noreply,
         socket
         |> put_flash(:info, "MFA method added!")
         |> push_redirect(to: socket.assigns.return_to)}

      {:error, changeset} ->
        {:noreply,
         socket
         |> assign(:changeset, changeset)
         |> assign(:step, :save)}
    end
  end
end
