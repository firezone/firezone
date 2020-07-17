defmodule FgHttpWeb.DeviceView do
  use FgHttpWeb, :view

  alias FgHttp.Devices.Device

  def rules_title(%Device{} = device) do
    num_rules = length(device.rules)

    "rule"
    |> Inflex.inflect(num_rules)
    |> (&("#{num_rules} " <> &1)).()
  end
end
