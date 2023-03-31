defmodule FzHttpWeb.LogoComponent do
  @moduledoc """
  Logo component displays default, url and data logo
  """
  use FzHttpWeb, :live_component
  import FzHttpWeb.Endpoint, only: [static_path: 1]

  def render(%{url: url} = assigns) when is_binary(url) do
    ~H"""
    <img src={@url} alt="Firezone App Logo" />
    """
  end

  def render(%{file: file} = assigns) when is_binary(file) do
    ~H"""
    <img src={static_path("/uploads/logo/" <> @file)} alt="Firezone App Logo" />
    """
  end

  def render(%{data: data, type: type} = assigns) when is_binary(data) and is_binary(type) do
    ~H"""
    <img src={"data:#{@type};base64," <> @data} alt="Firezone App Logo" />
    """
  end

  def render(assigns) do
    ~H"""
    <img src={~p"/images/logo-text.svg"} alt="firezone.dev" />
    """
  end
end
