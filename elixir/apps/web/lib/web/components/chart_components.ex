defmodule Web.ChartComponents do
  use Phoenix.Component
  use Web, :verified_routes

  attr :id, :string, required: true, doc: "The id of the chart"
  attr :options, :map, required: true, doc: "The options for the chart"

  def chart(assigns) do
    ~H"""
    <div id={@id} class="apexchart mt-2" data-options={Jason.encode!(@options)}></div>
    """
  end
end
