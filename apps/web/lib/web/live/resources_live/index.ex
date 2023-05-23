defmodule Web.ResourcesLive.Index do
  use Web, :live_view

  def render(assigns) do
    ~H"""
    <.section_header>
      <:breadcrumbs>
        <.breadcrumbs entries={[
          %{label: "Home", path: ~p"/"},
          %{label: "Resources", path: ~p"/resources"}
        ]} />
      </:breadcrumbs>
      <:title>
        All Resources
      </:title>
      <:actions>
        <.add_button navigate={~p"/resources/new"}>
          Add a new Resource
        </.add_button>
      </:actions>
    </.section_header>
    """
  end
end
