defmodule Web.Actors.Components do
  use Web, :component_library
  alias Domain.Actors

  def actor_type(:service_account), do: "Service Account"
  def actor_type(_type), do: "User"

  def actor_role(:service_account), do: "service account"
  def actor_role(:account_user), do: "user"
  def actor_role(:account_admin_user), do: "admin"

  attr :token, :any, required: true
  attr :class, :string, default: ""

  def token_type_icon(assigns) do
    ~H"""
    <.icon name={token_type_icon_name(@token.type)} class={@class} />
    """
  end

  defp token_type_icon_name(:browser), do: "hero-computer-window"
  defp token_type_icon_name(:client), do: "hero-device-phone-mobile"
  defp token_type_icon_name(:api_client), do: "hero-command-line"

  attr :actor, :any, required: true

  def actor_status(assigns) do
    ~H"""
    <span :if={Actors.actor_disabled?(@actor)} class="text-red-800">
      Disabled
    </span>
    <span :if={Actors.actor_deleted?(@actor)} class="text-red-800">
      Deleted
    </span>
    <span :if={not Actors.actor_disabled?(@actor) and not Actors.actor_deleted?(@actor)}>
      Active
    </span>
    """
  end

  attr :account, :any, required: true
  attr :actor, :any, required: true
  attr :class, :string, default: ""

  def actor_name_and_role(assigns) do
    ~H"""
    <.link
      navigate={actor_show_url(@account, @actor)}
      class={["text-accent-500 hover:underline", @class]}
    >
      {@actor.name}
    </.link>
    <span :if={@actor.type == :account_admin_user} class={["text-xs", @class]}>
      (admin)
    </span>
    <span :if={@actor.type == :service_account} class={["text-xs", @class]}>
      (service account)
    </span>
    <span :if={@actor.type == :api_client} class={["text-xs", @class]}>
      (api client)
    </span>
    """
  end

  attr :type, :atom, required: true
  attr :actor, :any, default: %Actors.Actor{memberships: [], last_synced_at: nil}, required: false
  attr :form, :any, required: true
  attr :subject, :any, required: true

  def actor_form(assigns) do
    ~H"""
    <div>
      <.input
        :if={not Actors.actor_synced?(@actor)}
        label="Full Name"
        field={@form[:name]}
        placeholder={
          if @type == :service_account, do: "E.g. My Backend Service", else: "E.g. John Smith"
        }
        required
      />
    </div>
    <div :if={@type != :service_account}>
      <.input
        type="select"
        label="Role"
        field={@form[:type]}
        options={
          [
            {"User", :account_user},
            {"Admin", :account_admin_user}
          ]
          |> Enum.filter(&Domain.Auth.can_grant_role?(@subject, elem(&1, 1)))
        }
        placeholder="Role"
        required
      />
      <p class="mt-2 text-xs text-gray-500">
        <strong>Admin</strong>
        grants full access to the admin portal and client applications. <strong>User</strong>
        grants access to client applications only.
      </p>
    </div>
    """
  end

  attr :form, :any, required: true
  attr :provider, :map, required: true

  def provider_form(%{provider: %{adapter: :email}} = assigns) do
    ~H"""
    <div>
      <.input
        label="Email"
        placeholder="Enter an email address"
        field={@form[:provider_identifier]}
        autocomplete="off"
      />
    </div>
    <div>
      <.input
        label="Email Confirmation"
        placeholder="Enter the same email as above"
        field={@form[:provider_identifier_confirmation]}
        autocomplete="off"
      />
    </div>
    """
  end

  def provider_form(%{provider: %{adapter: :openid_connect}} = assigns) do
    ~H"""
    <div>
      <.input
        label="Email"
        placeholder="Enter an email address"
        field={@form[:provider_identifier]}
        autocomplete="off"
      />
      <p class="mt-2 text-xs text-neutral-500">
        The token <code>sub</code> claim value or userinfo <code>email</code> value.
        This will be used to match the user to this identity when signing in for the first time.
      </p>
    </div>
    <div>
      <.input
        label="Email Confirmation"
        placeholder="Enter the same email as above"
        field={@form[:provider_identifier_confirmation]}
        autocomplete="off"
      />
    </div>
    """
  end

  def provider_form(%{provider: %{adapter: :userpass}} = assigns) do
    ~H"""
    <div>
      <.input
        label="Username"
        placeholder="Username"
        field={@form[:provider_identifier]}
        autocomplete="off"
      />
    </div>
    <.inputs_for :let={form} field={@form[:provider_virtual_state]}>
      <div>
        <.input
          type="password"
          label="Password"
          placeholder="Password"
          field={form[:password]}
          autocomplete="off"
        />
      </div>
      <div>
        <.input
          type="password"
          label="Password Confirmation"
          placeholder="Password Confirmation"
          field={form[:password_confirmation]}
          autocomplete="off"
        />
      </div>
    </.inputs_for>
    """
  end

  def next_step_path(:service_account, account) do
    ~p"/#{account}/actors/service_accounts/new"
  end

  def next_step_path(_other, account) do
    ~p"/#{account}/actors/users/new"
  end

  def actor_show_url(account, %Domain.Actors.Actor{type: :api_client} = actor) do
    ~p"/#{account}/settings/api_clients/#{actor}"
  end

  def actor_show_url(account, actor) do
    ~p"/#{account}/actors/#{actor}"
  end
end
