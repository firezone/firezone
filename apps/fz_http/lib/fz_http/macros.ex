defmodule FzHttp.Macros do
  @moduledoc """
  Metaprogramming macros
  """

  @doc """
  Defines getters for all Setting keys as functions on the Settings module.
  """
  defmacro def_settings(keys) do
    quote bind_quoted: [keys: keys] do
      Enum.each(keys, fn key ->
        fun_name = key |> String.replace(".", "_") |> String.to_atom() |> Macro.var(__MODULE__)

        def unquote(fun_name) do
          get_setting!(key: unquote(key)).value
        end
      end)
    end
  end
end
