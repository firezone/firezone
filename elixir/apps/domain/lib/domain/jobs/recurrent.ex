defmodule Domain.Jobs.Recurrent do
  @doc """
  This module provides a DSL to define recurrent jobs that run on an time interval basis.
  """
  defmacro __using__(opts) do
    quote bind_quoted: [opts: opts] do
      import Domain.Jobs.Recurrent

      # Accumulate handlers and define a `__handlers__/0` function to list them
      @before_compile Domain.Jobs.Recurrent
      Module.register_attribute(__MODULE__, :handlers, accumulate: true)

      # Will read the config from the application environment
      @otp_app Keyword.fetch!(opts, :otp_app)
      @spec __config__() :: Keyword.t()
      def __config__, do: Domain.Config.get_env(@otp_app, __MODULE__, [])
    end
  end

  defmacro __before_compile__(_env) do
    quote do
      @spec __handlers__() :: [{atom(), pos_integer()}]
      def __handlers__, do: @handlers
    end
  end

  @doc """
  Defines a code to execute every `interval` milliseconds.

  Is it recommended to use `seconds/1`, `minutes/1` macros to define the interval.

  Behind the hood it defines a function `execute(name, interval, do: ..)` and adds it's name to the
  module attribute.
  """
  defmacro every(interval, name, do: block) do
    quote do
      @handlers {unquote(name), unquote(interval)}
      def unquote(name)(unquote(Macro.var(:_config, nil))), do: unquote(block)
    end
  end

  defmacro every(interval, name, config, do: block) do
    quote do
      @handlers {unquote(name), unquote(interval)}
      def unquote(name)(unquote(config)), do: unquote(block)
    end
  end

  def seconds(num) do
    :timer.seconds(num)
  end

  def minutes(num) do
    :timer.minutes(num)
  end
end
