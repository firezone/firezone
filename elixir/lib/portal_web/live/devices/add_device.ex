defmodule PortalWeb.Devices.AddDevice do
  @moduledoc """
  The add-device flow shared by the Sites and Devices pages: a form that
  picks what the device connects as and which sites it serves, then the
  install instructions for the token it was given.

  A device that a service account connects as is created here with a token
  of its own. A device a user signs in on creates its row on first connect,
  so that choice creates nothing and shows the client install instructions.
  """
  use PortalWeb, :component_library
  alias PortalWeb.Sites.Components, as: SiteComponents

  @user_sign_in "user"

  @type state :: %{
          step: :form | :instructions | :user | nil,
          form: Phoenix.HTML.Form.t() | nil,
          service_accounts: [Portal.Actor.t()],
          sites: [Portal.Site.t()],
          device: Portal.Device.t() | nil,
          token: Portal.ClientToken.t() | nil,
          env: [{String.t(), String.t()}] | nil,
          tab: String.t(),
          connected?: boolean()
        }

  @doc "The state for a freshly opened flow, with `site_ids` preselected."
  @spec open(Portal.Authentication.Subject.t(), [Ecto.UUID.t()]) :: state()
  def open(subject, site_ids \\ []) do
    %{
      closed()
      | step: :form,
        form: to_form(%{"name" => "", "actor_id" => "", "site_ids" => site_ids}, as: :device),
        service_accounts: Portal.Devices.list_service_accounts(subject),
        sites: Portal.Devices.list_sites(subject)
    }
  end

  @doc "The state of a flow that is not open."
  @spec closed() :: state()
  def closed do
    %{
      step: nil,
      form: nil,
      service_accounts: [],
      sites: [],
      device: nil,
      token: nil,
      env: nil,
      tab: "debian-instructions",
      connected?: false
    }
  end

  @doc """
  Creates the device the form describes and moves the flow to the
  instructions, or to the client sign-in note when a user will sign in.
  """
  @spec submit(state(), map(), Portal.Authentication.Subject.t()) ::
          {:ok, state()} | {:error, term()}
  def submit(state, %{"actor_id" => @user_sign_in} = params, _subject) do
    {:ok, %{state | step: :user, form: to_form(params, as: :device)}}
  end

  def submit(state, params, subject) do
    name = blank_to_nil(Map.get(params, "name"))
    site_ids = Map.get(params, "site_ids", []) |> List.wrap() |> Enum.reject(&(&1 == ""))
    sites = Portal.Devices.fetch_sites(site_ids, subject)

    with {:ok, actor} <- PortalAPI.DeviceTokenOwner.fetch(blank_to_nil(params["actor_id"]), subject),
         {:ok, device, token, encoded_token} <-
           Portal.Devices.provision_device(sites, actor, name, subject) do
      {:ok,
       %{
         state
         | step: :instructions,
           form: to_form(params, as: :device),
           device: device,
           token: token,
           env: SiteComponents.gateway_env(encoded_token),
           connected?: false
       }}
    end
  end

  @doc "Whether a presence join is the device this flow is waiting for."
  @spec connected?(state(), map()) :: boolean()
  def connected?(%{token: %{id: token_id}, connected?: false}, joins) do
    Enum.any?(joins, fn {_device_id, %{metas: metas}} ->
      Enum.any?(metas, &(Map.get(&1, :token_id) == token_id))
    end)
  end

  def connected?(_state, _joins), do: false

  defp blank_to_nil(nil), do: nil
  defp blank_to_nil(""), do: nil
  defp blank_to_nil(value), do: value

  attr :state, :map, required: true
  attr :site, :any, default: nil, doc: "the site the flow was started from, if any"

  def add_device_form(assigns) do
    ~H"""
    <.form
      :let={f}
      for={@state.form}
      id="add-device-form"
      phx-change="add_device_change"
      phx-submit="add_device_submit"
      class="px-5 py-4 space-y-5"
    >
      <Form.input
        label="Name"
        field={f[:name]}
        placeholder="Leave blank for a generated name"
        phx-debounce="300"
      />
      <Form.input
        type="select"
        label="Connects as"
        field={f[:actor_id]}
        options={connect_as_options(@state.service_accounts)}
      />
      <p class="text-xs text-subtle -mt-3">
        A service account gets a token of its own for this device. A user signs in
        on the device, which registers it on first connect.
      </p>
      <Form.input
        type="select"
        label="Serves sites"
        field={f[:site_ids]}
        options={Enum.map(@state.sites, &{&1.name, &1.id})}
        multiple
      />
      <p class="text-xs text-subtle -mt-3">
        Optional. The device serves the resources of every site picked here; sites
        can be changed later from the device.
      </p>
      <div class="flex items-center justify-end gap-2">
        <Form.button type="button" phx-click="close_add_device">Cancel</Form.button>
        <Form.button type="submit" style="primary">Continue</Form.button>
      </div>
    </.form>
    """
  end

  defp connect_as_options(service_accounts) do
    Enum.map(service_accounts, fn actor ->
      label = if actor.managed_by == :system, do: "#{actor.name} (default)", else: actor.name
      {label, if(actor.managed_by == :system, do: "", else: actor.id)}
    end) ++ [{"A user will sign in", @user_sign_in}]
  end

  attr :account, :any, required: true
  attr :state, :map, required: true
  attr :navigate, :string, required: true, doc: "where to go once the device connects"

  def add_device_instructions(assigns) do
    ~H"""
    <div class="flex flex-1 min-h-0 flex-col overflow-hidden">
      <div class="flex-1 overflow-y-auto">
        <div :if={@state.device} class="px-5 pt-4 text-xs text-subtle">
          Device <span class="font-mono text-heading">{@state.device.slug}</span> was created.
          <span :if={@state.device.site_devices != [] and is_list(@state.device.site_devices)}>
            It serves {length(@state.device.site_devices)} site(s).
          </span>
        </div>
        <SiteComponents.site_deploy_tabs deploy_tab={@state.tab} />
        <SiteComponents.site_deploy_instructions deploy_tab={@state.tab} deploy_env={@state.env} />
      </div>
      <div class="shrink-0 px-5 py-3 border-t border-border bg-raised flex items-center justify-between gap-4">
        <p class="text-xs text-subtle">
          Device not connecting? See our
          <Navigation.website_link path="/kb/administer/troubleshooting" fragment="gateway-not-connecting">
            troubleshooting guide.
          </Navigation.website_link>
        </p>
        <Core.initial_connection_status
          :if={@state.env}
          type="gateway"
          navigate={@navigate}
          connected?={@state.connected?}
        />
      </div>
    </div>
    """
  end

  def add_device_user_note(assigns) do
    ~H"""
    <div class="px-5 py-4 space-y-3 text-sm text-body">
      <p>
        Nothing to create: a device a user signs in on registers itself the first
        time the user connects.
      </p>
      <p>
        Install the Firezone client on the device and sign in. See the
        <Navigation.website_link path="/kb/client-apps">client install guides</Navigation.website_link>.
      </p>
      <div class="flex items-center justify-end">
        <Form.button type="button" phx-click="close_add_device">Done</Form.button>
      </div>
    </div>
    """
  end
end
