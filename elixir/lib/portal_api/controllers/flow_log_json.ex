defmodule PortalAPI.FlowLogJSON do
  def render("ok.json", _assigns) do
    %{data: %{status: "ok"}}
  end
end
