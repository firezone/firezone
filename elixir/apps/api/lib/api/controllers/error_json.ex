defmodule API.ErrorJSON do
  def render(template, _assigns) do
    %{error: %{reason: Phoenix.Controller.status_message_from_template(template)}}
  end
end
