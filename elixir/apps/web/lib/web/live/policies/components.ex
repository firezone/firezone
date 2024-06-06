defmodule Web.Policies.Components do
  use Web, :component_library
  alias Domain.Policies

  @days_of_week [
    {"M", "Monday"},
    {"T", "Tuesday"},
    {"W", "Wednesday"},
    {"R", "Thursday"},
    {"F", "Friday"},
    {"S", "Saturday"},
    {"U", "Sunday"}
  ]

  attr :policy, :map, required: true

  def policy_name(assigns) do
    ~H"<%= @policy.actor_group.name %> → <%= @policy.resource.name %>"
  end

  def map_condition_params(attrs) do
    Map.update(attrs, "conditions", %{}, fn conditions ->
      for {property, condition_attrs} <- conditions,
          condition_attrs = map_condition_values(condition_attrs),
          into: %{} do
        {property, condition_attrs}
      end
    end)
  end

  defp map_condition_values(
         %{
           "operator" => "is_in_day_of_week_time_ranges",
           "timezone" => timezone
         } = condition_attrs
       ) do
    Map.update(condition_attrs, "values", [], fn values ->
      values
      |> Enum.sort_by(fn {dow, _} -> day_of_week_index(dow) end)
      |> Enum.map(fn {dow, time_ranges} ->
        "#{dow}/#{time_ranges}/#{timezone}"
      end)
    end)
  end

  defp map_condition_values(%{"values" => values} = condition_attrs) do
    values
    |> Enum.reject(fn value -> is_nil(value) or value == "" end)
    |> case do
      [] -> nil
      _other -> condition_attrs
    end
  end

  defp map_condition_values(_condition_attrs) do
    nil
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
    <span class="mr-1">
      <span :if={@operator == :is_in}>from</span>
      <span :if={@operator == :is_not_in}>from any counties except</span>
      <span class="font-medium">
        <%= @values |> Enum.map(&Domain.Geo.country_common_name!/1) |> Enum.join(", ") %>
      </span>
    </span>
    """
  end

  defp condition(%{property: :remote_ip} = assigns) do
    ~H"""
    <span class="mr-1">
      <span>from IP addresses that are</span> <span :if={@operator == :is_in_cidr}>within</span>
      <span :if={@operator == :is_not_in_cidr}>not within</span>
      <span class="font-medium"><%= Enum.join(@values, ", ") %></span>
    </span>
    """
  end

  defp condition(%{property: :provider_id} = assigns) do
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
    <span class="flex flex-wrap space-x-1 mr-1">
      <span>when signed in</span>
      <span :if={@operator == :is_in}>with</span>
      <span :if={@operator == :is_not_in}>not with</span>
      <.intersperse_blocks>
        <:separator>,</:separator>

        <:item :for={provider <- @providers}>
          <.link navigate={"/providers/#{provider.id}"} class={[link_style(), "font-medium"]}>
            <%= provider.name %>
          </.link>
        </:item>
      </.intersperse_blocks>
      <span>provider(s)</span>
    </span>
    """
  end

  defp condition(%{property: :current_utc_datetime, values: values} = assigns) do
    assigns =
      assign_new(assigns, :tz_time_ranges_by_dow, fn ->
        {:ok, ranges} = Policies.Condition.Evaluator.parse_days_of_week_time_ranges(values)

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
            <%= day_of_week_name(day_of_week) <> "s" %>
            <span :for={{timezone, time_ranges} <- tz_time_ranges}>
              <%= "(" <>
                Enum.map_join(time_ranges, ", ", fn {from, to} ->
                  "#{from} - #{to}"
                end) <> " #{timezone})" %>
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
  defp condition_operator_option_name(:is_not_in), do: "is not in"
  defp condition_operator_option_name(:is_in_day_of_week_time_ranges), do: ""
  defp condition_operator_option_name(:is_in_cidr), do: "is in"
  defp condition_operator_option_name(:is_not_in_cidr), do: "is not in"

  def condition_form(assigns) do
    assigns =
      assign_new(assigns, :policy_conditions_enabled?, fn ->
        Domain.Accounts.policy_conditions_enabled?(assigns.account)
      end)

    ~H"""
    <fieldset class="flex flex-col gap-2">
      <div class="flex items-center justify-between">
        <legend class="text-lg mb-4">Conditions</legend>
        <%= if @policy_conditions_enabled? == false do %>
          <.link navigate={~p"/#{@account}/settings/billing"} class="text-sm text-primary-500">
            <.badge type="primary" title="Feature available on a higher pricing plan">
              <.icon name="hero-lock-closed" class="w-3.5 h-3.5 mr-1" /> UPGRADE TO UNLOCK
            </.badge>
          </.link>
        <% end %>
      </div>

      <.remote_ip_location_region_condition_form
        form={@form}
        disabled={@policy_conditions_enabled? == false}
      />
      <.remote_ip_condition_form form={@form} disabled={@policy_conditions_enabled? == false} />
      <.provider_id_condition_form
        form={@form}
        providers={@providers}
        disabled={@policy_conditions_enabled? == false}
      />
      <.current_utc_datetime_condition_form
        form={@form}
        timezone={@timezone}
        disabled={@policy_conditions_enabled? == false}
      />
    </fieldset>
    """
  end

  defp remote_ip_location_region_condition_form(assigns) do
    ~H"""
    <fieldset class="mb-2">
      <% condition_form = find_condition_form(@form[:conditions], :remote_ip_location_region) %>

      <.input
        type="hidden"
        field={condition_form[:property]}
        name="policy[conditions][remote_ip_location_region][property]"
        id="policy_conditions_remote_ip_location_region_property"
        value="remote_ip_location_region"
      />

      <div
        class="cursor-pointer"
        phx-click={
          JS.toggle_class("hidden",
            to: "#policy_conditions_remote_ip_location_region_condition"
          )
          |> JS.toggle_class("hero-chevron-down",
            to: "#policy_conditions_remote_ip_location_region_chevron"
          )
          |> JS.toggle_class("hero-chevron-up",
            to: "#policy_conditions_remote_ip_location_region_chevron"
          )
        }
      >
        <legend>
          <.icon id="policy_conditions_remote_ip_location_region_chevron" name="hero-chevron-down" />
          Client location
        </legend>

        <p class="text-sm text-neutral-500 mb-2">
          Restrict access based on the location of the Client.
        </p>
      </div>

      <div
        id="policy_conditions_remote_ip_location_region_condition"
        class={[
          "grid gap-2 sm:grid-cols-5 sm:gap-4",
          condition_form.source == %{} && "hidden"
        ]}
      >
        <.input
          type="select"
          name="policy[conditions][remote_ip_location_region][operator]"
          id="policy_conditions_remote_ip_location_region_operator"
          field={condition_form[:operator]}
          placeholder="Operator"
          disabled={@disabled}
          options={condition_operator_options(:remote_ip_location_region)}
          value={condition_form && condition_form[:operator].value}
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
    </fieldset>
    """
  end

  defp remote_ip_condition_form(assigns) do
    ~H"""
    <fieldset class="mb-2">
      <% condition_form = find_condition_form(@form[:conditions], :remote_ip) %>

      <.input
        type="hidden"
        field={condition_form[:property]}
        name="policy[conditions][remote_ip][property]"
        id="policy_conditions_remote_ip_property"
        value="remote_ip"
      />

      <div
        class="cursor-pointer"
        phx-click={
          JS.toggle_class("hidden",
            to: "#policy_conditions_remote_ip_condition"
          )
          |> JS.toggle_class("hero-chevron-down",
            to: "#policy_conditions_remote_ip_chevron"
          )
          |> JS.toggle_class("hero-chevron-up",
            to: "#policy_conditions_remote_ip_chevron"
          )
        }
      >
        <legend>
          <.icon id="policy_conditions_remote_ip_chevron" name="hero-chevron-down" class="w-5 h-5" />
          IP address
        </legend>

        <p class="text-sm text-neutral-500 mb-2">
          Restrict access based on the Client's IP address.
        </p>
      </div>

      <div
        id="policy_conditions_remote_ip_condition"
        class={[
          "grid gap-2 sm:grid-cols-5 sm:gap-4",
          condition_form.source == %{} && "hidden"
        ]}
      >
        <.input
          type="select"
          name="policy[conditions][remote_ip][operator]"
          id="policy_conditions_remote_ip_operator"
          field={condition_form[:operator]}
          placeholder="Operator"
          options={condition_operator_options(:remote_ip)}
          disabled={@disabled}
          value={condition_form && condition_form[:operator].value}
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
              placeholder="189.172.0.0/24"
              disabled={@disabled}
              value_index={index}
              value={value}
            />
          </div>
        <% end %>
      </div>
    </fieldset>
    """
  end

  defp provider_id_condition_form(assigns) do
    ~H"""
    <fieldset class="mb-2">
      <% condition_form = find_condition_form(@form[:conditions], :provider_id) %>

      <.input
        type="hidden"
        field={condition_form[:property]}
        name="policy[conditions][provider_id][property]"
        id="policy_conditions_provider_id_property"
        value="provider_id"
      />

      <div
        class="cursor-pointer"
        phx-click={
          JS.toggle_class("hidden",
            to: "#policy_conditions_provider_id_condition"
          )
          |> JS.toggle_class("hero-chevron-down",
            to: "#policy_conditions_provider_id_chevron"
          )
          |> JS.toggle_class("hero-chevron-up",
            to: "#policy_conditions_provider_id_chevron"
          )
        }
      >
        <legend>
          <.icon id="policy_conditions_provider_id_chevron" name="hero-chevron-down" class="w-5 h-5" />
          Authentication Provider
        </legend>

        <p class="text-sm text-neutral-500 mb-2">
          Restrict access based on the identity provider that was used to sign in.
        </p>
      </div>

      <div
        id="policy_conditions_provider_id_condition"
        class={[
          "grid gap-2 sm:grid-cols-5 sm:gap-4",
          condition_form.source == %{} && "hidden"
        ]}
      >
        <.input
          type="select"
          name="policy[conditions][provider_id][operator]"
          id="policy_conditions_provider_id_operator"
          field={condition_form[:operator]}
          placeholder="Operator"
          options={condition_operator_options(:provider_id)}
          disabled={@disabled}
          value={condition_form && condition_form[:operator].value}
        />

        <%= for {value, index} <- Enum.with_index((condition_form[:values] && condition_form[:values].value || []) ++ [nil]) do %>
          <div :if={index > 0} class="text-right mt-3 text-sm text-neutral-900">
            or
          </div>

          <div class="col-span-4">
            <.input
              type="select"
              field={condition_form[:values]}
              name="policy[conditions][provider_id][values][]"
              id={"policy_conditions_provider_id_values_#{index}"}
              options={[{"Select Provider", nil}] ++ Enum.map(@providers, &{&1.name, &1.id})}
              disabled={@disabled}
              value_index={index}
              value={value}
            />
          </div>
        <% end %>
      </div>
    </fieldset>
    """
  end

  defp current_utc_datetime_condition_form(assigns) do
    assigns = assign_new(assigns, :days_of_week, fn -> @days_of_week end)

    ~H"""
    <fieldset>
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
        placeholder="Operator"
        value={:is_in_day_of_week_time_ranges}
      />

      <div
        class="cursor-pointer"
        phx-click={
          JS.toggle_class("hidden",
            to: "#policy_conditions_current_utc_datetime_condition"
          )
          |> JS.toggle_class("hero-chevron-down",
            to: "#policy_conditions_current_utc_datetime_chevron"
          )
          |> JS.toggle_class("hero-chevron-up",
            to: "#policy_conditions_current_utc_datetime_chevron"
          )
        }
      >
        <legend>
          <.icon
            id="policy_conditions_current_utc_datetime_chevron"
            name="hero-chevron-down"
            class="w-5 h-5"
          /> Current time
        </legend>

        <p class="text-sm text-neutral-500 mb-2">
          Restrict access based on the current time of the day.
        </p>
      </div>

      <div
        id="policy_conditions_current_utc_datetime_condition"
        class={[
          "space-y-2",
          condition_form.source == %{} && "hidden"
        ]}
      >
        <.input
          type="select"
          label="Timezone"
          name="policy[conditions][current_utc_datetime][timezone]"
          id="policy_conditions_current_utc_datetime_timezone"
          field={condition_form[:timezone]}
          placeholder="Timezone"
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
    </fieldset>
    """
  end

  defp find_condition_form(form_field, property) do
    condition_form =
      form_field.value
      |> Enum.find_value(fn condition ->
        if Ecto.Changeset.get_field(condition, :property) == property do
          to_form(condition)
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
      placeholder="9:00-12:00, 13:00-17:00"
      disabled={@disabled}
      value={get_datetime_range_for_day_of_week(@day, @condition_form[:values])}
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
    Domain.Policies.Condition.Changeset.valid_operators_for_property(property)
    |> Enum.map(&{condition_operator_option_name(&1), &1})
  end
end
