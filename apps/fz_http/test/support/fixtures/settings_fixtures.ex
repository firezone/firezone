defmodule FzHttp.SettingsFixtures do
  @moduledoc """
  This module defines test helpers for creating
  entities via the `FzHttp.Settings` context.
  """

  alias FzHttp.Settings

  @doc """
  Generate a setting.
  """
  def setting_fixture(key \\ "default.device.dns") do
    Settings.get_setting!(key: key)
  end
end
