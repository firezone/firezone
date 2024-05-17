defmodule Web.Policies.Components do
  use Web, :component_library
  alias Domain.Policies

  attr :policy, :map, required: true

  def policy_name(assigns) do
    ~H"<%= @policy.actor_group.name %> → <%= @policy.resource.name %>"
  end

  def constraints(assigns) do
    ~H"""
    <.constraint
      :for={constraint <- @constraints}
      property={constraint.property}
      operator={constraint.operator}
      values={constraint.values}
    />
    """
  end

  def constraint(%{property: :remote_ip_location_region} = assigns) do
    ~H"""
    <div>
      Client <%= constraint_operator_option_name(@operator) %>
      <%= for value <- @values do %>
        <%= Domain.Geo.country_common_name!(value) %>
      <% end %>
    </div>
    """
  end

  def constraint(%{property: :remote_ip} = assigns) do
    ~H"""
    <div>
      Client IP Address <%= constraint_operator_option_name(@operator) %>
      <%= Enum.join(@values, ", ") %>
    </div>
    """
  end

  def constraint(%{property: :provider_id} = assigns) do
    ~H"""
    <div>
      Provider <%= constraint_operator_option_name(@operator) %>
      <%= Enum.join(@values, ", ") %>
    </div>
    """
  end

  def constraint(%{property: :current_utc_datetime, values: values} = assigns) do
    assigns =
      assign_new(assigns, :ranges, fn ->
        {:ok, ranges} = Policies.Constraint.Evaluator.parse_days_of_week_time_ranges(values)
        ranges
      end)

    ~H"""
    <div>
      Current time
      <div :for={{day_of_week, ranges} <- @ranges}>
        <%= unless Enum.empty?(ranges) do %>
          <%= day_of_week_name(day_of_week) <> "s: " %>
          <%= Enum.map_join(
            ranges,
            ", ",
            fn {from, to} ->
              "#{from} - #{to}"
            end
          ) %>
        <% end %>
      </div>
    </div>
    """
  end

  def day_of_week_name("M"), do: "Monday"
  def day_of_week_name("T"), do: "Tuesday"
  def day_of_week_name("W"), do: "Wednesday"
  def day_of_week_name("R"), do: "Thursday"
  def day_of_week_name("F"), do: "Friday"
  def day_of_week_name("S"), do: "Saturday"
  def day_of_week_name("U"), do: "Sunday"

  def constraint_property_option_name(:remote_ip_location_region), do: "Client Location Country"
  def constraint_property_option_name(:remote_ip), do: "Client IP Address"
  def constraint_property_option_name(:provider_id), do: "Provider"
  def constraint_property_option_name(:current_utc_datetime), do: "Current UTC Datetime"
  def constraint_property_option_name(other), do: to_string(other)

  def constraint_operator_option_name(:contains), do: "contains"
  def constraint_operator_option_name(:does_not_contain), do: "does not contain"
  def constraint_operator_option_name(:is_in), do: "is in"
  def constraint_operator_option_name(:is_not_in), do: "is not in"
  def constraint_operator_option_name(:is_in_day_of_week_time_ranges), do: ""
  def constraint_operator_option_name(:is_in_cidr), do: "is in"
  def constraint_operator_option_name(:is_not_in_cidr), do: "is not in"

  attr :constraint, :any, required: true, doc: "the constraint form element"
  attr :providers, :list, required: true, doc: "providers for the provider_id constraint"

  def constraint_form(assigns) do
    ~H"""
    <div class="grid gap-2 sm:grid-cols-5 sm:gap-4">
      <div class="col-span-2">
        <.input
          type="select"
          field={@constraint[:property]}
          placeholder="Property"
          options={constraint_property_options()}
          value={@constraint[:property].value}
        />
      </div>

      <.constraint_condition_form
        providers={@providers}
        property={@constraint[:property].value}
        constraint={@constraint}
      />
    </div>
    """
  end

  defp constraint_condition_form(%{property: :remote_ip_location_region} = assigns) do
    ~H"""
    <.input
      type="select"
      field={@constraint[:operator]}
      placeholder="Operator"
      options={constraint_operator_options(@property)}
    />

    <%= for {value, index} <- Enum.with_index((@constraint[:values].value || []) ++ [nil]) do %>
      <div :if={index > 0} class="text-right mt-3 text-sm text-neutral-900 col-span-3">or</div>

      <div class="col-span-2">
        <.input
          type="select"
          field={@constraint[:values]}
          id={@constraint[:values].name <> "[#{index}]"}
          name={@constraint[:values].name <> "[#{index}]"}
          options={[{"Select Country", nil}] ++ Domain.Geo.all_country_options!()}
          value={value}
        />
      </div>
    <% end %>
    """
  end

  defp constraint_condition_form(%{property: :remote_ip} = assigns) do
    ~H"""
    <.input
      type="select"
      field={@constraint[:operator]}
      placeholder="Operator"
      options={constraint_operator_options(@property)}
    />

    <%= for {value, index} <- Enum.with_index((@constraint[:values].value || []) ++ [nil]) do %>
      <div :if={index > 0} class="text-right mt-3 text-sm text-neutral-900 col-span-3">or</div>

      <div class="col-span-2">
        <.input
          type="text"
          field={@constraint[:values]}
          id={@constraint[:values].name <> "[#{index}]"}
          name={@constraint[:values].name <> "[#{index}]"}
          placeholder="172.16.0.0/24"
          value={value}
        />
      </div>
    <% end %>
    """
  end

  defp constraint_condition_form(%{property: :provider_id} = assigns) do
    ~H"""
    <.input
      type="select"
      field={@constraint[:operator]}
      placeholder="Operator"
      options={constraint_operator_options(@property)}
    />

    <%= for {value, index} <- Enum.with_index((@constraint[:values].value || []) ++ [nil]) do %>
      <div :if={index > 0} class="text-right mt-3 text-sm text-neutral-900 col-span-3">or</div>

      <div class="col-span-2">
        <.input
          type="select"
          field={@constraint[:values]}
          id={@constraint[:values].name <> "[#{index}]"}
          name={@constraint[:values].name <> "[#{index}]"}
          options={[{"Select Provider", nil}] ++ Enum.map(@providers, &{&1.name, &1.id})}
          value={value}
        />
      </div>
    <% end %>
    """
  end

  defp constraint_condition_form(%{property: :current_utc_datetime} = assigns) do
    ~H"""
    <.input type="hidden" field={@constraint[:operator]} value="is_in_day_of_week_time_ranges" />

    <div class="text-right mt-3 text-sm text-neutral-900">Monday</div>
    <div class="col-span-2">
      <.input
        type="text"
        field={@constraint[:values]}
        id={@constraint[:values].name <> "[M]"}
        name={@constraint[:values].name <> "[M]"}
        placeholder="9:00-17:00"
        value={get_datetime_range_for_day_of_week("M", @constraint[:values])}
      />
    </div>

    <div class="text-right mt-3 text-sm text-neutral-900 col-span-3">Tuesday</div>
    <div class="col-span-2">
      <.input
        type="text"
        field={@constraint[:values]}
        id={@constraint[:values].name <> "[T]"}
        name={@constraint[:values].name <> "[T]"}
        placeholder="9:00-17:00, 23:00-23:59"
        value={get_datetime_range_for_day_of_week("T", @constraint[:values])}
      />
    </div>

    <div class="text-right mt-3 text-sm text-neutral-900 col-span-3">Wednesday</div>
    <div class="col-span-2">
      <.input
        type="text"
        field={@constraint[:values]}
        id={@constraint[:values].name <> "[W]"}
        name={@constraint[:values].name <> "[W]"}
        placeholder="9:00-17:00"
        value={get_datetime_range_for_day_of_week("W", @constraint[:values])}
      />
    </div>

    <div class="text-right mt-3 text-sm text-neutral-900 col-span-3">Thursday</div>
    <div class="col-span-2">
      <.input
        type="text"
        field={@constraint[:values]}
        id={@constraint[:values].name <> "[R]"}
        name={@constraint[:values].name <> "[R]"}
        placeholder="9:00-17:00"
        value={get_datetime_range_for_day_of_week("R", @constraint[:values])}
      />
    </div>

    <div class="text-right mt-3 text-sm text-neutral-900 col-span-3">Friday</div>
    <div class="col-span-2">
      <.input
        type="text"
        field={@constraint[:values]}
        id={@constraint[:values].name <> "[F]"}
        name={@constraint[:values].name <> "[F]"}
        placeholder="9:00-17:00"
        value={get_datetime_range_for_day_of_week("F", @constraint[:values])}
      />
    </div>

    <div class="text-right mt-3 text-sm text-neutral-900 col-span-3">Saturday</div>
    <div class="col-span-2">
      <.input
        type="text"
        field={@constraint[:values]}
        id={@constraint[:values].name <> "[S]"}
        name={@constraint[:values].name <> "[S]"}
        placeholder="9:00-17:00"
        value={get_datetime_range_for_day_of_week("S", @constraint[:values])}
      />
    </div>

    <div class="text-right mt-3 text-sm text-neutral-900 col-span-3">Sunday</div>
    <div class="col-span-2">
      <.input
        type="text"
        field={@constraint[:values]}
        id={@constraint[:values].name <> "[U]"}
        name={@constraint[:values].name <> "[U]"}
        placeholder="9:00-17:00"
        value={get_datetime_range_for_day_of_week("U", @constraint[:values])}
      />
    </div>
    """
  end

  defp get_datetime_range_for_day_of_week(day, form_field) do
    Enum.find_value(form_field.value, fn
      ^day <> "/" <> ranges -> ranges
      _ -> nil
    end)
  end

  defp constraint_property_options do
    Ecto.Enum.values(Domain.Policies.Constraint, :property)
    |> Enum.map(&{constraint_property_option_name(&1), &1})
  end

  defp constraint_operator_options(property) do
    Domain.Policies.Constraint.Changeset.valid_operators_for_property(property)
    |> Enum.map(&{constraint_operator_option_name(&1), &1})
  end
end
