defmodule Domain.Jobs.Job do
  defmacro __using__(opts) do
    quote bind_quoted: [opts: opts, location: :keep] do
      @otp_app Keyword.fetch!(opts, :otp_app)
      @interval Keyword.fetch!(opts, :every)
      @executor Keyword.fetch!(opts, :executor)

      @behaviour @executor

      def child_spec(_opts) do
        config = __config__()
        Supervisor.child_spec({@executor, {__MODULE__, @interval, config}}, id: __MODULE__)
      end

      @doc """
      Returns the configuration for the job that is defined in the application environment.
      """
      @spec __config__() :: Keyword.t()
      def __config__, do: Domain.Config.get_env(@otp_app, __MODULE__, [])
    end
  end
end
