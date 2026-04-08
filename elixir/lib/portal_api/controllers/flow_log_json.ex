defmodule PortalAPI.FlowLogJSON do
  def render("accepted.json", _assigns) do
    %{data: %{status: "accepted"}}
  end
end
