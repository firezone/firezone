defmodule FzHttpWeb.LogoComponent do
  @moduledoc """
  Logo component displays default, url and data logo
  """
  use Phoenix.Component

  alias FzHttpWeb.Router.Helpers, as: Routes

  def render(%{url: url} = assigns) when is_binary(url) do
    ~H"""
    <img src={@url} alt="Firezone App Logo" />
    """
  end

  def render(%{data: data, type: type} = assigns) when is_binary(data) and is_binary(type) do
    ~H"""
    <img src={"data:#{@type};base64," <> @data} alt="Firezone App Logo" />
    """
  end

  def render(assigns) do
    ~H"""
    <img src={Routes.static_path(FzHttpWeb.Endpoint, "/images/logo-text.svg")} alt="firezone.dev">
    """
  end
end
