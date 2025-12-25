defmodule Portal.Sandbox do
  if Mix.env() in [:test, :dev] do
    def allow(sandbox, metadata) do
      # We notify the test process that there is someone trying to access the sandbox,
      # so that it can optionally await after test has passed for the sandbox to be
      # closed gracefully
      case sandbox.decode_metadata(metadata) do
        %{owner: owner_pid} -> send(owner_pid, {:sandbox_allowed, self()})
        _ -> :ok
      end

      sandbox.allow(metadata, Ecto.Adapters.SQL.Sandbox)
    end
  else
    def allow(_sandbox, _metadata) do
      :ok
    end
  end
end
