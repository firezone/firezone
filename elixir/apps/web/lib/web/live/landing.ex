defmodule Web.Landing do
  use Web, {:live_view, layout: {Web.Layouts, :public}}

  def render(assigns) do
    ~H"""
    Home page for unauthenticated users and regular account users with app download links.
    """
  end
end
