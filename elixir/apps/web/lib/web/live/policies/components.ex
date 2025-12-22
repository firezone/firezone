defmodule Web.Policies.Components do
  use Web, :component_library
  alias Domain.Policies.Condition

  @days_of_week [
    {"M", "Monday"},
    {"T", "Tuesday"},
    {"W", "Wednesday"},
    {"R", "Thursday"},
    {"F", "Friday"},
    {"S", "Saturday"},
    {"U", "Sunday"}
  ]

  @all_conditions [
    :remote_ip_location_region,
    :remote_ip,
    :auth_provider_id,
    :client_verified,
    :current_utc_datetime
  ]

  # current_utc_datetime is a condition evaluated at the time of the request,
  # so we don't need to include it in the list of conditions that can be set
  # for internet resources, otherwise it would be blocking all the requests.
  @conditions_by_resource_type %{
    internet: @all_conditions -- [:current_utc_datetime],
    dns: @all_conditions,
    ip: @all_conditions,
    cidr: @all_conditions
  }

  attr(:policy, :map, required: true)

  def policy_name(assigns) do
    ~H"{@policy.group.name} → {@policy.resource.name}"
  end

  def maybe_drop_unsupported_conditions(attrs, socket) do
    if Domain.Account.policy_conditions_enabled?(socket.assigns.account) do
      attrs
    else
      Map.delete(attrs, "conditions")
    end
  end

  def map_condition_params(attrs, opts) do
    Map.update(attrs, "conditions", %{}, fn conditions ->
      for {property, condition_attrs} <- conditions,
          maybe_filter(condition_attrs, opts),
          condition_attrs = map_condition_values(condition_attrs),
          into: %{} do
        {property, condition_attrs}
      end
    end)
  end

  defp maybe_filter(%{"values" => values}, empty_values: :drop) when is_list(values) do
    not (values
         |> List.wrap()
         |> Enum.reject(fn value -> value in [nil, ""] end)
         |> Enum.empty?())
  end

  defp maybe_filter(%{"values" => values}, empty_values: :drop) when is_map(values) do
    not (values
         |> Enum.reject(fn {_key, value} -> value in [nil, ""] end)
         |> Enum.empty?())
  end

  defp maybe_filter(%{}, empty_values: :drop) do
    false
  end

  defp maybe_filter(_condition_attrs, _opts) do
    true
  end

  defp map_condition_values(
         %{
           "operator" => "is_in_day_of_week_time_ranges",
           "timezone" => timezone
         } = condition_attrs
       ) do
    Map.update(condition_attrs, "values", [], fn values ->
      values
      |> Enum.filter(fn {dow, _} -> dow in ["M", "T", "W", "R", "F", "S", "U"] end)
      |> Enum.sort_by(fn {dow, _} -> day_of_week_index(dow) end)
      |> Enum.map(fn {dow, time_ranges} ->
        "#{dow}/#{time_ranges}/#{timezone}"
      end)
    end)
  end

  defp map_condition_values(condition_attrs) do
    condition_attrs
  end

  defp condition_values_empty?(%{data: %{values: values}}) when values != [] do
    false
  end

  defp condition_values_empty?(%{
         params: %{
           "operator" => "is_in_day_of_week_time_ranges",
           "values" => values
         }
       }) do
    values
    |> Enum.reject(fn value ->
      case String.split(value, "/") do
        [_, ranges, _] -> ranges == ""
        _ -> true
      end
    end)
    |> Enum.empty?()
  end

  defp condition_values_empty?(%{
         params: %{"values" => values}
       }) do
    values
    |> List.wrap()
    |> Enum.reject(fn value -> value in [nil, ""] end)
    |> Enum.empty?()
  end

  defp condition_values_empty?(%{}) do
    true
  end

  def conditions(assigns) do
    ~H"""
    <span :if={@conditions == []} class="text-neutral-500">
      There are no conditions defined for this policy.
    </span>
    <span :if={@conditions != []} class="flex flex-wrap">
      <span class="mr-1">This policy can be used</span>
      <.condition
        :for={condition <- @conditions}
        account={@account}
        providers={@providers}
        property={condition.property}
        operator={condition.operator}
        values={condition.values}
      />
    </span>
    """
  end

  defp condition(%{property: :remote_ip_location_region} = assigns) do
    ~H"""
    <span :if={@values != []} class="mr-1">
      <span :if={@operator == :is_in}>from</span>
      <span :if={@operator == :is_not_in}>from any counties except</span>
      <span class="font-medium">
        {@values |> Enum.map(&Domain.Geo.country_common_name!/1) |> Enum.join(", ")}
      </span>
    </span>
    """
  end

  defp condition(%{property: :remote_ip} = assigns) do
    ~H"""
    <span :if={@values != []} class="mr-1">
      <span>from IP addresses that are</span> <span :if={@operator == :is_in_cidr}>in</span>
      <span :if={@operator == :is_not_in_cidr}>not in</span>
      <span class="font-medium">{Enum.join(@values, ", ")}</span>
    </span>
    """
  end

  defp condition(%{property: :auth_provider_id} = assigns) do
    assigns =
      assign(
        assigns,
        :providers,
        assigns.values
        |> Enum.map(fn provider_id ->
          Enum.find(assigns.providers, fn provider ->
            provider.id == provider_id
          end)
        end)
        |> Enum.reject(&is_nil/1)
      )

    ~H"""
    <span :if={@providers != []} class="flex flex-wrap space-x-1 mr-1">
      <span>when signed in</span>
      <span :if={@operator == :is_in}>with</span>
      <span :if={@operator == :is_not_in}>not with</span>
      <.intersperse_blocks>
        <:separator>,</:separator>

        <:item :for={provider <- @providers}>
          <.link
            navigate={~p"/#{@account}/settings/authentication"}
            class={[link_style(), "font-medium"]}
          >
            {provider.name}
          </.link>
        </:item>
      </.intersperse_blocks>
      <span>provider(s)</span>
    </span>
    """
  end

  defp condition(%{property: :client_verified} = assigns) do
    ~H"""
    <span :if={@values != []} class="mr-1">
      <span>by clients that are</span>
      <span :if={@values == ["true"]}>verified</span>
      <span :if={@values == ["false"]}>not verified</span>
    </span>
    """
  end

  defp condition(%{property: :current_utc_datetime, values: values} = assigns) do
    assigns =
      assign_new(assigns, :tz_time_ranges_by_dow, fn ->
        {:ok, ranges} = Domain.Policies.Evaluator.parse_days_of_week_time_ranges(values)

        ranges
        |> Enum.reject(fn {_dow, time_ranges} -> time_ranges == [] end)
        |> Enum.map(fn {dow, time_ranges} ->
          time_ranges_by_timezone =
            time_ranges
            |> Enum.reduce(%{}, fn {starts_at, ends_at, timezone}, acc ->
              range = {starts_at, ends_at}
              Map.update(acc, timezone, [range], fn ranges -> [range | ranges] end)
            end)

          {dow, time_ranges_by_timezone}
        end)
        |> Enum.sort_by(fn {dow, _time_ranges_by_timezone} -> day_of_week_index(dow) end)
      end)

    ~H"""
    <span class="flex flex-wrap space-x-1 mr-1">
      on
      <.intersperse_blocks>
        <:separator>,</:separator>

        <:item :for={{day_of_week, tz_time_ranges} <- @tz_time_ranges_by_dow}>
          <span class="ml-1 font-medium">
            {day_of_week_name(day_of_week) <> "s"}
            <span :for={{timezone, time_ranges} <- tz_time_ranges}>
              {"(" <>
                Enum.map_join(time_ranges, ", ", fn {from, to} ->
                  "#{from} - #{to}"
                end) <> " #{timezone})"}
            </span>
          </span>
        </:item>
      </.intersperse_blocks>
    </span>
    """
  end

  for {code, name} <- @days_of_week do
    defp day_of_week_name(unquote(code)), do: unquote(name)
  end

  for {{code, _name}, index} <- Enum.with_index(@days_of_week) do
    def day_of_week_index(unquote(code)), do: unquote(index)
  end

  defp condition_operator_option_name(:contains), do: "contains"
  defp condition_operator_option_name(:does_not_contain), do: "does not contain"
  defp condition_operator_option_name(:is_in), do: "is in"
  defp condition_operator_option_name(:is), do: "is"
  defp condition_operator_option_name(:is_not_in), do: "is not in"
  defp condition_operator_option_name(:is_in_day_of_week_time_ranges), do: ""
  defp condition_operator_option_name(:is_in_cidr), do: "is in"
  defp condition_operator_option_name(:is_not_in_cidr), do: "is not in"

  def conditions_form(assigns) do
    assigns =
      assigns
      |> assign_new(:policy_conditions_enabled?, fn ->
        Domain.Account.policy_conditions_enabled?(assigns.account)
      end)
      |> assign_new(:enabled_conditions, fn ->
        Map.fetch!(@conditions_by_resource_type, assigns.selected_resource.type)
      end)

    ~H"""
    <fieldset class="flex flex-col gap-2 mt-4">
      <div class="flex items-center justify-between">
        <div>
          <legend class="text-xl mb-2 text-neutral-900">Conditions</legend>
          <p class="my-2 text-sm text-neutral-500">
            All conditions specified below must be met for this policy to be applied.
          </p>
        </div>
        <%= if @policy_conditions_enabled? == false do %>
          <.link navigate={~p"/#{@account}/settings/billing"} class="text-sm text-primary-500">
            <.badge type="primary" title="Feature available on a higher pricing plan">
              <.icon name="hero-lock-closed" class="w-3.5 h-3.5 mr-1" /> UPGRADE TO UNLOCK
            </.badge>
          </.link>
        <% end %>
      </div>

      <div class={@policy_conditions_enabled? == false && "opacity-50"}>
        <.remote_ip_location_region_condition_form
          :if={:remote_ip_location_region in @enabled_conditions}
          form={@form}
          disabled={@policy_conditions_enabled? == false}
        />
        <.remote_ip_condition_form
          :if={:remote_ip in @enabled_conditions}
          form={@form}
          disabled={@policy_conditions_enabled? == false}
        />
        <.provider_id_condition_form
          :if={:auth_provider_id in @enabled_conditions}
          form={@form}
          providers={@providers}
          disabled={@policy_conditions_enabled? == false}
        />
        <.client_verified_condition_form
          :if={:client_verified in @enabled_conditions}
          form={@form}
          disabled={@policy_conditions_enabled? == false}
        />
        <.current_utc_datetime_condition_form
          :if={:current_utc_datetime in @enabled_conditions}
          form={@form}
          timezone={@timezone}
          disabled={@policy_conditions_enabled? == false}
        />
      </div>
    </fieldset>
    """
  end

  defp remote_ip_location_region_condition_form(assigns) do
    ~H"""
    <fieldset class="mb-4">
      <% condition_form = find_condition_form(@form[:conditions], :remote_ip_location_region) %>

      <.input
        type="hidden"
        field={condition_form[:property]}
        name="policy[conditions][remote_ip_location_region][property]"
        id="policy_conditions_remote_ip_location_region_property"
        value="remote_ip_location_region"
      />

      <div
        class="hover:bg-neutral-100 cursor-pointer border border-neutral-200 shadow-b rounded-t px-4 py-2"
        phx-click={
          JS.toggle_class("hidden",
            to: "#policy_conditions_remote_ip_location_region_condition"
          )
          |> JS.toggle_class("bg-neutral-50")
          |> JS.toggle_class("hero-chevron-down",
            to: "#policy_conditions_remote_ip_location_region_chevron"
          )
          |> JS.toggle_class("hero-chevron-up",
            to: "#policy_conditions_remote_ip_location_region_chevron"
          )
        }
      >
        <legend class="flex justify-between items-center text-neutral-700">
          <span class="flex items-center">
            <.icon name="hero-map-pin" class="w-5 h-5 mr-2" /> Client location
          </span>
          <span class="shadow bg-white w-6 h-6 flex items-center justify-center rounded-full">
            <.icon
              id="policy_conditions_remote_ip_location_region_chevron"
              name="hero-chevron-down"
              class="w-5 h-5"
            />
          </span>
        </legend>
      </div>

      <div
        id="policy_conditions_remote_ip_location_region_condition"
        class={[
          "p-4 border-neutral-200 border-l border-r border-b rounded-b",
          condition_values_empty?(condition_form) && "hidden"
        ]}
      >
        <p class="text-sm text-neutral-500 mb-4">
          Allow access when the location of the Client meets the criteria specified below.
        </p>
        <div class="grid gap-2 sm:grid-cols-5 sm:gap-4">
          <.input
            type="select"
            name="policy[conditions][remote_ip_location_region][operator]"
            id="policy_conditions_remote_ip_location_region_operator"
            field={condition_form[:operator]}
            disabled={@disabled}
            options={condition_operator_options(:remote_ip_location_region)}
            value={get_in(condition_form, [:operator, Access.key!(:value)])}
          />

          <%= for {value, index} <- Enum.with_index((condition_form[:values] && condition_form[:values].value || []) ++ [nil]) do %>
            <div :if={index > 0} class="text-right mt-3 text-sm text-neutral-900">
              or
            </div>

            <div class="col-span-4">
              <.input
                type="select"
                field={condition_form[:values]}
                name="policy[conditions][remote_ip_location_region][values][]"
                id={"policy_conditions_remote_ip_location_region_values_#{index}"}
                options={[{"Select Country", nil}] ++ Domain.Geo.all_country_options!()}
                disabled={@disabled}
                value_index={index}
                value={value}
              />
            </div>
          <% end %>
        </div>
      </div>
    </fieldset>
    """
  end

  defp remote_ip_condition_form(assigns) do
    ~H"""
    <fieldset class="mb-4">
      <% condition_form = find_condition_form(@form[:conditions], :remote_ip) %>

      <.input
        type="hidden"
        field={condition_form[:property]}
        name="policy[conditions][remote_ip][property]"
        id="policy_conditions_remote_ip_property"
        value="remote_ip"
      />

      <div
        class="hover:bg-neutral-100 cursor-pointer border border-neutral-200 shadow-b rounded-t px-4 py-2"
        phx-click={
          JS.toggle_class("hidden",
            to: "#policy_conditions_remote_ip_condition"
          )
          |> JS.toggle_class("bg-neutral-50")
          |> JS.toggle_class("hero-chevron-down",
            to: "#policy_conditions_remote_ip_chevron"
          )
          |> JS.toggle_class("hero-chevron-up",
            to: "#policy_conditions_remote_ip_chevron"
          )
        }
      >
        <legend class="flex justify-between items-center text-neutral-700">
          <span class="flex items-center">
            <.icon name="hero-globe-alt" class="w-5 h-5 mr-2" /> IP address
          </span>
          <span class="shadow bg-white w-6 h-6 flex items-center justify-center rounded-full">
            <.icon id="policy_conditions_remote_ip_chevron" name="hero-chevron-down" class="w-5 h-5" />
          </span>
        </legend>
      </div>

      <div
        id="policy_conditions_remote_ip_condition"
        class={[
          "p-4 border-neutral-200 border-l border-r border-b rounded-b",
          condition_values_empty?(condition_form) && "hidden"
        ]}
      >
        <p class="text-sm text-neutral-500 mb-4">
          Allow access when the IP of the Client meets the criteria specified below.
        </p>
        <div class="grid gap-2 sm:grid-cols-5 sm:gap-4">
          <.input
            type="select"
            name="policy[conditions][remote_ip][operator]"
            id="policy_conditions_remote_ip_operator"
            field={condition_form[:operator]}
            disabled={@disabled}
            options={condition_operator_options(:remote_ip)}
            value={get_in(condition_form, [:operator, Access.key!(:value)])}
          />

          <%= for {value, index} <- Enum.with_index((condition_form[:values] && condition_form[:values].value || []) ++ [nil]) do %>
            <div :if={index > 0} class="text-right mt-3 text-sm text-neutral-900">
              or
            </div>

            <div class="col-span-4">
              <.input
                type="text"
                field={condition_form[:values]}
                name="policy[conditions][remote_ip][values][]"
                id={"policy_conditions_remote_ip_values_#{index}"}
                placeholder="E.g. 189.172.0.0/24 or 10.10.10.1"
                disabled={@disabled}
                value_index={index}
                value={value}
              />
            </div>
          <% end %>
        </div>
      </div>
    </fieldset>
    """
  end

  defp provider_id_condition_form(assigns) do
    ~H"""
    <fieldset class="mb-4">
      <% condition_form = find_condition_form(@form[:conditions], :auth_provider_id) %>

      <.input
        type="hidden"
        field={condition_form[:property]}
        name="policy[conditions][auth_provider_id][property]"
        id="policy_conditions_auth_provider_id_property"
        value="auth_provider_id"
      />

      <div
        class="hover:bg-neutral-100 cursor-pointer border border-neutral-200 shadow-b rounded-t px-4 py-2"
        phx-click={
          JS.toggle_class("hidden",
            to: "#policy_conditions_auth_provider_id_condition"
          )
          |> JS.toggle_class("bg-neutral-50")
          |> JS.toggle_class("hero-chevron-down",
            to: "#policy_conditions_auth_provider_id_chevron"
          )
          |> JS.toggle_class("hero-chevron-up",
            to: "#policy_conditions_auth_provider_id_chevron"
          )
        }
      >
        <legend class="flex justify-between items-center text-neutral-700">
          <span class="flex items-center">
            <.icon name="hero-identification" class="w-5 h-5 mr-2" /> Authentication provider
          </span>
          <span class="shadow bg-white w-6 h-6 flex items-center justify-center rounded-full">
            <.icon
              id="policy_conditions_auth_provider_id_chevron"
              name="hero-chevron-down"
              class="w-5 h-5"
            />
          </span>
        </legend>
      </div>

      <div
        id="policy_conditions_auth_provider_id_condition"
        class={[
          "p-4 border-neutral-200 border-l border-r border-b rounded-b",
          condition_values_empty?(condition_form) && "hidden"
        ]}
      >
        <p class="text-sm text-neutral-500 mb-4">
          Allow access when the provider used to sign in meets the criteria specified below.
        </p>
        <div class="grid gap-2 sm:grid-cols-5 sm:gap-4">
          <.input
            type="select"
            name="policy[conditions][auth_provider_id][operator]"
            id="policy_conditions_auth_provider_id_operator"
            field={condition_form[:operator]}
            disabled={@disabled}
            options={condition_operator_options(:auth_provider_id)}
            value={get_in(condition_form, [:operator, Access.key!(:value)])}
          />

          <%= for {value, index} <- Enum.with_index((condition_form[:values] && condition_form[:values].value || []) ++ [nil]) do %>
            <div :if={index > 0} class="text-right mt-3 text-sm text-neutral-900">
              or
            </div>

            <div class="col-span-4">
              <.input
                type="select"
                field={condition_form[:values]}
                name="policy[conditions][auth_provider_id][values][]"
                id={"policy_conditions_auth_provider_id_values_#{index}"}
                options={[{"Select Provider", nil}] ++ Enum.map(@providers, &{&1.name, &1.id})}
                disabled={@disabled}
                value_index={index}
                value={value}
              />
            </div>
          <% end %>
        </div>
      </div>
    </fieldset>
    """
  end

  defp client_verified_condition_form(assigns) do
    ~H"""
    <fieldset class="mb-4">
      <% condition_form = find_condition_form(@form[:conditions], :client_verified) %>

      <.input
        type="hidden"
        field={condition_form[:property]}
        name="policy[conditions][client_verified][property]"
        id="policy_conditions_client_verified_property"
        value="client_verified"
      />

      <.input
        type="hidden"
        name="policy[conditions][client_verified][operator]"
        id="policy_conditions_client_verified_operator"
        field={condition_form[:operator]}
        value={:is}
      />

      <div
        class="hover:bg-neutral-100 cursor-pointer border border-neutral-200 shadow-b rounded-t px-4 py-2"
        phx-click={
          JS.toggle_class("hidden",
            to: "#policy_conditions_client_verified_condition"
          )
          |> JS.toggle_class("bg-neutral-50")
          |> JS.toggle_class("hero-chevron-down",
            to: "#policy_conditions_client_verified_chevron"
          )
          |> JS.toggle_class("hero-chevron-up",
            to: "#policy_conditions_client_verified_chevron"
          )
        }
      >
        <legend class="flex justify-between items-center text-neutral-700">
          <span class="flex items-center">
            <.icon name="hero-shield-check" class="w-5 h-5 mr-2" /> Client verification
          </span>
          <span class="shadow bg-white w-6 h-6 flex items-center justify-center rounded-full">
            <.icon
              id="policy_conditions_client_verified_chevron"
              name="hero-chevron-down"
              class="w-5 h-5"
            />
          </span>
        </legend>
      </div>

      <div
        id="policy_conditions_client_verified_condition"
        class={[
          "p-4 border-neutral-200 border-l border-r border-b rounded-b",
          condition_values_empty?(condition_form) && "hidden"
        ]}
      >
        <p class="text-sm text-neutral-500 mb-4">
          Allow access when the Client is manually verified by the administrator.
        </p>
        <div class="space-y-2" phx-update="ignore" id="conditions-client-verified-values">
          <.input
            type="checkbox"
            label="Require client verification"
            name="policy[conditions][client_verified][values][]"
            id="policy_conditions_client_verified_value"
            disabled={@disabled}
            checked={List.first(List.wrap(condition_form[:values].value)) == "true"}
            value="true"
            unchecked_value={nil}
          />
        </div>
      </div>
    </fieldset>
    """
  end

  defp current_utc_datetime_condition_form(assigns) do
    assigns = assign_new(assigns, :days_of_week, fn -> @days_of_week end)

    ~H"""
    <fieldset class="mb-2">
      <% condition_form = find_condition_form(@form[:conditions], :current_utc_datetime) %>

      <.input
        type="hidden"
        field={condition_form[:property]}
        name="policy[conditions][current_utc_datetime][property]"
        id="policy_conditions_current_utc_datetime_property"
        value="current_utc_datetime"
      />

      <.input
        type="hidden"
        name="policy[conditions][current_utc_datetime][operator]"
        id="policy_conditions_current_utc_datetime_operator"
        field={condition_form[:operator]}
        value={:is_in_day_of_week_time_ranges}
      />

      <div
        class="hover:bg-neutral-100 cursor-pointer border border-neutral-200 shadow-b rounded-t px-4 py-2"
        phx-click={
          JS.toggle_class("hidden",
            to: "#policy_conditions_current_utc_datetime_condition"
          )
          |> JS.toggle_class("bg-neutral-50")
          |> JS.toggle_class("hero-chevron-down",
            to: "#policy_conditions_current_utc_datetime_chevron"
          )
          |> JS.toggle_class("hero-chevron-up",
            to: "#policy_conditions_current_utc_datetime_chevron"
          )
        }
      >
        <legend class="flex justify-between items-center text-neutral-700">
          <span class="flex items-center">
            <.icon name="hero-clock" class="w-5 h-5 mr-2" /> Current time
          </span>
          <span class="shadow bg-white w-6 h-6 flex items-center justify-center rounded-full">
            <.icon
              id="policy_conditions_current_utc_datetime_chevron"
              name="hero-chevron-down"
              class="w-5 h-5"
            />
          </span>
        </legend>
      </div>

      <div
        id="policy_conditions_current_utc_datetime_condition"
        class={[
          "p-4 border-neutral-200 border-l border-r border-b rounded-b",
          condition_values_empty?(condition_form) && "hidden"
        ]}
      >
        <p class="text-sm text-neutral-500 mb-4">
          Allow access during the time windows specified below. 24hr format and multiple time ranges per day are supported.
        </p>
        <div class="space-y-2">
          <.input
            type="select"
            label="Timezone"
            name="policy[conditions][current_utc_datetime][timezone]"
            id="policy_conditions_current_utc_datetime_timezone"
            field={condition_form[:timezone]}
            options={Tzdata.zone_list()}
            disabled={@disabled}
            value={condition_form[:timezone].value || @timezone}
          />

          <div class="space-y-2">
            <.current_utc_datetime_condition_day_input
              :for={{code, _name} <- @days_of_week}
              disabled={@disabled}
              condition_form={condition_form}
              day={code}
            />
          </div>
        </div>
      </div>
    </fieldset>
    """
  end

  defp find_condition_form(form_field, property) do
    condition_form =
      form_field.value
      |> Enum.find_value(fn
        %Ecto.Changeset{} = condition ->
          if Ecto.Changeset.get_field(condition, :property) == property do
            to_form(condition)
          end

        condition ->
          if Map.get(condition, :property) == property do
            to_form(Condition.changeset(condition, %{}, 0))
          end
      end)

    condition_form || to_form(%{})
  end

  defp current_utc_datetime_condition_day_input(assigns) do
    ~H"""
    <.input
      type="text"
      label={day_of_week_name(@day)}
      field={@condition_form[:values]}
      name={"policy[conditions][current_utc_datetime][values][#{@day}]"}
      id={"policy_conditions_current_utc_datetime_values_#{@day}"}
      placeholder="E.g. 9:00-12:00, 13:00-17:00"
      value={get_datetime_range_for_day_of_week(@day, @condition_form[:values])}
      disabled={@disabled}
      value_index={day_of_week_index(@day)}
    />
    """
  end

  defp get_datetime_range_for_day_of_week(day, form_field) do
    Enum.find_value(form_field.value || [], fn dow_time_ranges ->
      case String.split(dow_time_ranges, "/", parts: 3) do
        [^day, ranges, _timezone] -> ranges
        _other -> false
      end
    end)
  end

  defp condition_operator_options(property) do
    Domain.Policies.Condition.valid_operators_for_property(property)
    |> Enum.map(&{condition_operator_option_name(&1), &1})
  end

  def options_form(assigns) do
    ~H"""
    """
  end

  defmodule DB do
    import Ecto.Query
    import Domain.Repo.Query
    alias Domain.{Safe, Userpass, EmailOTP, OIDC, Google, Entra, Okta}

    def all_active_providers_for_account(account, subject) do
      # Query all auth provider types that are not disabled
      userpass_query =
        from(p in Userpass.AuthProvider,
          where: p.account_id == ^account.id and not p.is_disabled
        )

      email_otp_query =
        from(p in EmailOTP.AuthProvider,
          where: p.account_id == ^account.id and not p.is_disabled
        )

      oidc_query =
        from(p in OIDC.AuthProvider,
          where: p.account_id == ^account.id and not p.is_disabled
        )

      google_query =
        from(p in Google.AuthProvider,
          where: p.account_id == ^account.id and not p.is_disabled
        )

      entra_query =
        from(p in Entra.AuthProvider,
          where: p.account_id == ^account.id and not p.is_disabled
        )

      okta_query =
        from(p in Okta.AuthProvider,
          where: p.account_id == ^account.id and not p.is_disabled
        )

      # Combine all providers from different tables using Safe
      (userpass_query |> Safe.scoped(subject) |> Safe.all()) ++
        (email_otp_query |> Safe.scoped(subject) |> Safe.all()) ++
        (oidc_query |> Safe.scoped(subject) |> Safe.all()) ++
        (google_query |> Safe.scoped(subject) |> Safe.all()) ++
        (entra_query |> Safe.scoped(subject) |> Safe.all()) ++
        (okta_query |> Safe.scoped(subject) |> Safe.all())
    end

    # Inlined from Web.Groups.Components
    def fetch_group_option(id, subject) do
      group =
        from(g in Domain.Group, as: :groups)
        |> where([groups: g], g.id == ^id)
        |> join(:left, [groups: g], d in assoc(g, :directory), as: :directory)
        |> join(:left, [directory: d], gd in Domain.Google.Directory,
          on: gd.id == d.id and d.type == :google,
          as: :google_directory
        )
        |> join(:left, [directory: d], ed in Domain.Entra.Directory,
          on: ed.id == d.id and d.type == :entra,
          as: :entra_directory
        )
        |> join(:left, [directory: d], od in Domain.Okta.Directory,
          on: od.id == d.id and d.type == :okta,
          as: :okta_directory
        )
        |> select_merge(
          [directory: d, google_directory: gd, entra_directory: ed, okta_directory: od],
          %{
            directory_name:
              fragment(
                "COALESCE(?, ?, ?, 'Firezone')",
                gd.name,
                ed.name,
                od.name
              ),
            directory_type: d.type
          }
        )
        |> Safe.scoped(subject)
        |> Safe.one!()

      {:ok, group_option(group)}
    end

    def list_group_options(search_query_or_nil, subject) do
      query =
        from(g in Domain.Group, as: :groups)
        |> join(:left, [groups: g], d in assoc(g, :directory), as: :directory)
        |> join(:left, [directory: d], gd in Domain.Google.Directory,
          on: gd.id == d.id and d.type == :google,
          as: :google_directory
        )
        |> join(:left, [directory: d], ed in Domain.Entra.Directory,
          on: ed.id == d.id and d.type == :entra,
          as: :entra_directory
        )
        |> join(:left, [directory: d], od in Domain.Okta.Directory,
          on: od.id == d.id and d.type == :okta,
          as: :okta_directory
        )
        |> select_merge(
          [directory: d, google_directory: gd, entra_directory: ed, okta_directory: od],
          %{
            directory_name:
              fragment(
                "COALESCE(?, ?, ?, 'Firezone')",
                gd.name,
                ed.name,
                od.name
              ),
            directory_type: d.type
          }
        )
        |> order_by([groups: g], asc: g.name)
        |> limit(25)

      query =
        if search_query_or_nil != "" and search_query_or_nil != nil do
          from(g in query, where: fulltext_search(g.name, ^search_query_or_nil))
        else
          query
        end

      groups = query |> Safe.scoped(subject) |> Safe.all()

      # For metadata, we'll return a simple count
      metadata = %{limit: 25, count: length(groups)}

      {:ok, grouped_select_options(groups), metadata}
    end

    defp grouped_select_options(groups) do
      groups
      |> Enum.group_by(&option_groups_index_and_label/1)
      |> Enum.sort_by(fn {{options_group_index, options_group_label}, _groups} ->
        {options_group_index, options_group_label}
      end)
      |> Enum.map(fn {{_options_group_index, options_group_label}, groups} ->
        {options_group_label, groups |> Enum.sort_by(& &1.name) |> Enum.map(&group_option/1)}
      end)
    end

    defp option_groups_index_and_label(group) do
      index =
        cond do
          group_synced?(group) -> 9
          group_managed?(group) -> 1
          true -> 2
        end

      label =
        cond do
          group_synced?(group) ->
            "Synced from #{group.directory_name}"

          group_managed?(group) ->
            "Managed by Firezone"

          true ->
            "Manually managed"
        end

      {index, label}
    end

    defp group_option(group) do
      {group.id, group.name, group}
    end

    # Inlined from Domain.Actors helpers
    defp group_synced?(group), do: not is_nil(group.directory_id)
    defp group_managed?(group), do: group.type == :managed

    # Inline functions from Domain.PolicyAuthorizations
    def list_policy_authorizations_for(assoc, subject, opts \\ [])

    def list_policy_authorizations_for(
          %Domain.Policy{} = policy,
          %Domain.Auth.Subject{} = subject,
          opts
        ) do
      DB.PolicyAuthorizationQuery.all()
      |> DB.PolicyAuthorizationQuery.by_policy_id(policy.id)
      |> list_policy_authorizations(subject, opts)
    end

    def list_policy_authorizations_for(
          %Domain.Resource{} = resource,
          %Domain.Auth.Subject{} = subject,
          opts
        ) do
      DB.PolicyAuthorizationQuery.all()
      |> DB.PolicyAuthorizationQuery.by_resource_id(resource.id)
      |> list_policy_authorizations(subject, opts)
    end

    def list_policy_authorizations_for(
          %Domain.Client{} = client,
          %Domain.Auth.Subject{} = subject,
          opts
        ) do
      DB.PolicyAuthorizationQuery.all()
      |> DB.PolicyAuthorizationQuery.by_client_id(client.id)
      |> list_policy_authorizations(subject, opts)
    end

    def list_policy_authorizations_for(
          %Domain.Actor{} = actor,
          %Domain.Auth.Subject{} = subject,
          opts
        ) do
      DB.PolicyAuthorizationQuery.all()
      |> DB.PolicyAuthorizationQuery.by_actor_id(actor.id)
      |> list_policy_authorizations(subject, opts)
    end

    def list_policy_authorizations_for(
          %Domain.Gateway{} = gateway,
          %Domain.Auth.Subject{} = subject,
          opts
        ) do
      DB.PolicyAuthorizationQuery.all()
      |> DB.PolicyAuthorizationQuery.by_gateway_id(gateway.id)
      |> list_policy_authorizations(subject, opts)
    end

    defp list_policy_authorizations(queryable, subject, opts) do
      queryable
      |> Domain.Safe.scoped(subject)
      |> Domain.Safe.list(DB.PolicyAuthorizationQuery, opts)
    end
  end

  defmodule DB.PolicyAuthorizationQuery do
    import Ecto.Query

    def all do
      from(policy_authorizations in Domain.PolicyAuthorization, as: :policy_authorizations)
    end

    def expired(queryable) do
      now = DateTime.utc_now()

      where(
        queryable,
        [policy_authorizations: policy_authorizations],
        policy_authorizations.expires_at <= ^now
      )
    end

    def not_expired(queryable) do
      now = DateTime.utc_now()

      where(
        queryable,
        [policy_authorizations: policy_authorizations],
        policy_authorizations.expires_at > ^now
      )
    end

    def by_id(queryable, id) do
      where(
        queryable,
        [policy_authorizations: policy_authorizations],
        policy_authorizations.id == ^id
      )
    end

    def by_account_id(queryable, account_id) do
      where(
        queryable,
        [policy_authorizations: policy_authorizations],
        policy_authorizations.account_id == ^account_id
      )
    end

    def by_token_id(queryable, token_id) do
      where(
        queryable,
        [policy_authorizations: policy_authorizations],
        policy_authorizations.token_id == ^token_id
      )
    end

    def by_policy_id(queryable, policy_id) do
      where(
        queryable,
        [policy_authorizations: policy_authorizations],
        policy_authorizations.policy_id == ^policy_id
      )
    end

    def for_cache(queryable) do
      queryable
      |> select(
        [policy_authorizations: policy_authorizations],
        {{policy_authorizations.client_id, policy_authorizations.resource_id},
         {policy_authorizations.id, policy_authorizations.expires_at}}
      )
    end

    def by_policy_group_id(queryable, group_id) do
      queryable
      |> with_joined_policy()
      |> where([policy: policy], policy.group_id == ^group_id)
    end

    def by_membership_id(queryable, membership_id) do
      where(
        queryable,
        [policy_authorizations: policy_authorizations],
        policy_authorizations.membership_id == ^membership_id
      )
    end

    def by_site_id(queryable, site_id) do
      queryable
      |> with_joined_site()
      |> where([site: site], site.id == ^site_id)
    end

    def by_resource_id(queryable, resource_id) do
      where(
        queryable,
        [policy_authorizations: policy_authorizations],
        policy_authorizations.resource_id == ^resource_id
      )
    end

    def by_not_in_resource_ids(queryable, resource_ids) do
      where(
        queryable,
        [policy_authorizations: policy_authorizations],
        policy_authorizations.resource_id not in ^resource_ids
      )
    end

    def by_client_id(queryable, client_id) do
      where(
        queryable,
        [policy_authorizations: policy_authorizations],
        policy_authorizations.client_id == ^client_id
      )
    end

    def by_actor_id(queryable, actor_id) do
      queryable
      |> with_joined_client()
      |> where([client: client], client.actor_id == ^actor_id)
    end

    def by_gateway_id(queryable, gateway_id) do
      where(
        queryable,
        [policy_authorizations: policy_authorizations],
        policy_authorizations.gateway_id == ^gateway_id
      )
    end

    def with_joined_policy(queryable) do
      with_policy_authorization_named_binding(queryable, :policy, fn queryable, binding ->
        join(
          queryable,
          :inner,
          [policy_authorizations: policy_authorizations],
          policy in assoc(policy_authorizations, ^binding),
          as: ^binding
        )
      end)
    end

    def with_joined_client(queryable) do
      with_policy_authorization_named_binding(queryable, :client, fn queryable, binding ->
        join(
          queryable,
          :inner,
          [policy_authorizations: policy_authorizations],
          client in assoc(policy_authorizations, ^binding),
          as: ^binding
        )
      end)
    end

    def with_joined_site(queryable) do
      queryable
      |> with_joined_gateway()
      |> with_policy_authorization_named_binding(:site, fn queryable, binding ->
        join(queryable, :inner, [gateway: gateway], site in assoc(gateway, :site), as: ^binding)
      end)
    end

    def with_joined_gateway(queryable) do
      with_policy_authorization_named_binding(queryable, :gateway, fn queryable, binding ->
        join(
          queryable,
          :inner,
          [policy_authorizations: policy_authorizations],
          gateway in assoc(policy_authorizations, ^binding),
          as: ^binding
        )
      end)
    end

    def with_policy_authorization_named_binding(queryable, binding, fun) do
      if has_named_binding?(queryable, binding) do
        queryable
      else
        fun.(queryable, binding)
      end
    end

    # Pagination
    def cursor_fields,
      do: [
        {:policy_authorizations, :desc, :inserted_at},
        {:policy_authorizations, :asc, :id}
      ]
  end
end
