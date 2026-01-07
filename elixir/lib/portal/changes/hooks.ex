defmodule Portal.Changes.Hooks do
  @moduledoc """
    A simple behavior to define hooks needed for processing WAL events.
  """

  @callback on_insert(lsn :: integer(), data :: map()) :: :ok | {:error, term()}
  @callback on_update(lsn :: integer(), old_data :: map(), data :: map()) ::
              :ok | {:error, term()}
  @callback on_delete(lsn :: integer(), old_data :: map()) :: :ok | {:error, term()}
end
