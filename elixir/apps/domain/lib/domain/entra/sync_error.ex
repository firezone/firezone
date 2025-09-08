defmodule Domain.Entra.SyncError do
  defexception [:response, :directory_id]

  def message(%{response: response, directory_id: directory_id}) do
    "Entra sync error for directory #{directory_id}: #{inspect(response)}"
  end
end
