defmodule Web.Settings.IdentityProviders.Mock.Components do
  use Web, :component_library

  def provider_form(assigns) do
    ~H"""
    <div class="max-w-2xl px-4 py-8 mx-auto lg:py-12">
      <.form for={@form} phx-change={:change} phx-submit={:submit}>
        <.step>
          <:title>Configure the Mock adapter</:title>
          <:content>
            <.base_error form={@form} field={:base} />

            <div class="grid gap-4 mb-4 sm:grid-cols-1 sm:gap-6 sm:mb-6">
              <div>
                <.input
                  label="Name"
                  autocomplete="off"
                  field={@form[:name]}
                  placeholder="Name this identity provider"
                  required
                />
                <p class="mt-2 text-xs text-neutral-500">
                  A friendly name for this identity provider.
                </p>
              </div>

              <.inputs_for :let={adapter_config_form} field={@form[:adapter_config]}>
                <div>
                  <.input
                    label="Number of actors"
                    autocomplete="off"
                    field={adapter_config_form[:num_actors]}
                    required
                  />
                  <p class="mt-2 text-xs text-neutral-500">
                    The total number of actors to randomly generate.
                  </p>
                </div>

                <div>
                  <.input
                    label="Number of groups"
                    autocomplete="off"
                    field={adapter_config_form[:num_groups]}
                    required
                  />
                  <p class="mt-2 text-xs text-neutral-500">
                    The total number of groups to randomly generate.
                  </p>
                </div>

                <div>
                  <.input
                    label="Max actors per group"
                    autocomplete="off"
                    field={adapter_config_form[:max_actors_per_group]}
                    required
                  />
                  <p class="mt-2 text-xs text-neutral-500">
                    The maximum number of actors per group. A random number of actors will be assigned to each group, up to this limit.
                  </p>
                </div>
              </.inputs_for>
            </div>

            <.submit_button>
              Save Identity Provider
            </.submit_button>
          </:content>
        </.step>
      </.form>
    </div>
    """
  end
end
