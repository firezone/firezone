defmodule Web.Settings.IdentityProviders.SAML.Components do
  @moduledoc """
  Provides components that can be shared across forms.
  """
  use Phoenix.Component
  use Web, :verified_routes
  import Web.CoreComponents
  import Web.FormComponents
  alias Phoenix.LiveView.JS

  @doc """
  Conditionally renders form fields corresponding to a given provisioning strategy type.

  ## Examples

    <.provisioning_strategy_form form={%{
      provisioning_strategy: "jit",
      jit_user_filter_type: "email_allowlist",
      jit_user_filter_value: "jamil@foo.dev,andrew@foo.dev",
      jit_extract_groups: true
    }} />

    <.provisioning_strategy_form form={@form} />
  """
  attr :form, :map, required: true, doc: "The form to which this component belongs."

  def provisioning_strategy_form(assigns) do
    ~H"""
    <h2 class="mb-4 text-xl font-bold text-neutral-900">Provisioning strategy</h2>
    <ul class="mb-4 w-full sm:flex border border-neutral-200 rounded">
      <li class="w-full border-b border-neutral-200 sm:border-b-0 sm:border-r">
        <div class="text-lg font-medium p-3">
          <.input
            id="provisioning_strategy_jit"
            label="Just-in-time"
            type="radio"
            value="jit"
            field={@form[:provisioning_strategy]}
            checked={@form[:provisioning_strategy].value == "jit"}
            required
          />
        </div>
        <p class="px-4 py-2 text-sm text-neutral-500">
          Provision users and groups on the fly when they first sign in.
        </p>
      </li>
      <li class="w-full border-b border-neutral-200 sm:border-b-0 sm:border-r">
        <div class="text-lg font-medium p-3">
          <.input
            id="provisioning_strategy_scim"
            label="SCIM 2.0"
            type="radio"
            value="scim"
            field={@form[:provisioning_strategy]}
            checked={@form[:provisioning_strategy].value == "scim"}
            required
          />
        </div>
        <p class="px-4 py-2 text-sm text-neutral-500">
          Provision users using the SCIM 2.0 protocol. Requires a supported identity provider.
        </p>
      </li>
      <li class="w-full border-b border-neutral-200 sm:border-b-0 sm:border-r">
        <div class="text-lg font-medium p-3">
          <.input
            id="provisioning_strategy_manual"
            label="Manual"
            type="radio"
            value="manual"
            field={@form[:provisioning_strategy]}
            checked={@form[:provisioning_strategy].value == "manual"}
            required
          />
        </div>
        <p class="px-4 py-2 text-sm text-neutral-500">
          Disable automatic provisioning and manually manage users and groups.
        </p>
      </li>
    </ul>
    <%= if @form[:provisioning_strategy].value == "jit" do %>
      <div class="grid grid-cols-1 gap-4 sm:grid-cols-2 mb-4">
        <div>
          <.input
            label="User filter"
            type="select"
            field={@form[:jit_user_filter_type]}
            options={[
              [value: "email_allowlist", key: "Email allowlist"],
              [value: "same_domain", key: "Allow from same email domain"],
              [value: "allow_all", key: "Allow any authenticated user"]
            ]}
          >
          </.input>
        </div>
        <div>
          <%= if @form[:jit_user_filter_type].value == "email_allowlist" do %>
            <.input
              label="Email allowlist"
              autocomplete="off"
              field={@form[:jit_user_filter_value]}
              placeholder="Comma-delimited list of email addresses"
              required
            />
          <% end %>
        </div>
      </div>
      <div class="grid grid-cols-1 gap-4 sm:grid-cols-2 mb-4">
        <div class="col-offset-1">
          <.input
            label="Extract group membership information"
            type="checkbox"
            field={@form[:jit_extract_groups]}
          />
          <p class="ml-8 text-sm text-neutral-500">
            <.link
              class="text-accent-500 hover:underline"
              href="https://www.firezone.dev/kb/authenticate/user-group-sync?utm_source=product"
              target="_blank"
            >
              Read more about group extraction.
              <.icon name="hero-arrow-top-right-on-square" class="-ml-1 mb-3 w-3 h-3" />
            </.link>
          </p>
        </div>
      </div>
    <% end %>
    """
  end

  def provisioning_status(assigns) do
    ~H"""
    <!-- Provisioning details -->
    <.header>
      <:title>Provisioning</:title>
    </.header>
    <div class="bg-white overflow-hidden">
      <table class="w-full text-sm text-left text-neutral-500">
        <tbody>
          <tr class="border-b border-neutral-200">
            <th
              scope="row"
              class="text-right px-6 py-4 font-medium text-neutral-900 whitespace-nowrap bg-neutral-50"
            >
              Type
            </th>
            <td class="px-6 py-4">
              SCIM 2.0
            </td>
          </tr>
          <tr class="border-b border-neutral-200">
            <th
              scope="row"
              class="text-right px-6 py-4 font-medium text-neutral-900 whitespace-nowrap bg-neutral-50"
            >
              Endpoint
            </th>
            <td class="px-6 py-4">
              <div class="flex items-center">
                <button
                  phx-click={JS.dispatch("phx:copy", to: "#endpoint-value")}
                  title="Copy Endpoint"
                  class="text-accent-500"
                >
                  <.icon name="hero-document-duplicate" class="w-5 h-5 mr-1" />
                </button>
                <code id="endpoint-value" data-copy={"/#{@account}/scim/v2"}>
                  <%= "/#{@account}/scim/v2" %>
                </code>
              </div>
            </td>
          </tr>
          <tr class="border-b border-neutral-200">
            <th
              scope="row"
              class="text-right px-6 py-4 font-medium text-neutral-900 whitespace-nowrap bg-neutral-50"
            >
              Token
            </th>
            <td class="px-6 py-4">
              <div class="flex items-center">
                <button
                  phx-click={JS.dispatch("phx:copy", to: "#visible-token")}
                  title="Copy SCIM token"
                  class="text-accent-500"
                >
                  <.icon name="hero-document-duplicate" class="w-5 h-5 mr-1" />
                </button>
                <button
                  phx-click={toggle_scim_token()}
                  title="Show SCIM token"
                  class="text-accent-500"
                >
                  <.icon name="hero-eye" class="w-5 h-5 mr-1" />
                </button>

                <span id="hidden-token">
                  •••••••••••••••••••••••••••••••••••••••••••••
                </span>
                <span
                  id="visible-token"
                  style="display: none"
                  data-copy={@identity_provider.scim_token}
                >
                  <code><%= @identity_provider.scim_token %></code>
                </span>
              </div>
            </td>
          </tr>
        </tbody>
      </table>
    </div>
    """
  end

  def toggle_scim_token(js \\ %JS{}) do
    js
    |> JS.toggle(to: "#visible-token")
    |> JS.toggle(to: "#hidden-token")
  end
end
