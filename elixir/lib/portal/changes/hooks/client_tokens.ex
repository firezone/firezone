defmodule Portal.Changes.Hooks.ClientTokens do
  @behaviour Portal.Changes.Hooks
  alias Portal.PG
  import Portal.SchemaHelpers

  @impl true
  def on_insert(_lsn, _data), do: :ok

  @impl true
  def on_update(_lsn, _old_data, _new_data), do: :ok

  @impl true
  def on_delete(_lsn, old_data) do
    token = struct_from_params(Portal.ClientToken, old_data)
    PG.deliver(token.id, :disconnect)
    :ok
  end
end
