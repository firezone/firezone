defmodule Web.ResourcesLive.New do
  use Web, :live_view

  def render(assigns) do
    ~H"""
    <.section_header>
      <:breadcrumbs>
        <.breadcrumbs entries={[
          %{label: "Home", path: ~p"/"},
          %{label: "Resources", path: ~p"/resources"},
          %{label: "Add resource", path: ~p"/resources/new"}
        ]} />
      </:breadcrumbs>
      <:title>
        Add a new Resource
      </:title>
    </.section_header>
    """
  end
end
