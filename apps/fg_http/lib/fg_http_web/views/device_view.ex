defmodule FgHttpWeb.DeviceView do
  use FgHttpWeb, :view

  alias FgHttp.Devices.Device

  def rules_title(%Device{} = device) do
    num_rules = length(device.rules)

    "rule"
    |> Inflex.inflect(num_rules)
    |> reverse_concat(num_rules)
  end

  defp reverse_concat(word, number) do
    "#{number} " <> "#{word}"
  end
end
