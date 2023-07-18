defmodule Web.SettingsLive.IdentityProviders.New.Components do
  @moduledoc """
  Provides components that can be shared across forms.
  """
  use Phoenix.Component
  use Web, :verified_routes
  import Web.CoreComponents
  import Web.FormComponents

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
    <h2 class="mb-4 text-xl font-bold text-gray-900 dark:text-white">Provisioning strategy</h2>
    <ul class="mb-4 w-full sm:flex border border-gray-200 rounded-lg dark:bg-gray-700 dark:border-gray-600 dark:text-white">
      <li class="w-full border-b border-gray-200 sm:border-b-0 sm:border-r dark:border-gray-600">
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
        <p class="px-4 py-2 text-sm text-gray-500 dark:text-gray-400">
          Provision users and groups on the fly when they first sign in.
        </p>
      </li>
      <li class="w-full border-b border-gray-200 sm:border-b-0 sm:border-r dark:border-gray-600">
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
        <p class="px-4 py-2 text-sm text-gray-500 dark:text-gray-400">
          Provision users using the SCIM 2.0 protocol. Requires a supported identity provider.
        </p>
      </li>
      <li class="w-full border-b border-gray-200 sm:border-b-0 sm:border-r dark:border-gray-600">
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
        <p class="px-4 py-2 text-sm text-gray-500 dark:text-gray-400">
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
          <p class="ml-8 text-sm text-gray-500 dark:text-gray-400">
            <.link
              class="text-blue-600 dark:text-blue-500 hover:underline"
              href="https://www.firezone.dev/docs/authenticate/jit-provisioning#extract-group-membership-information"
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
end
