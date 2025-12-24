defmodule Web.LogFormatter do
  @moduledoc """
  Custom log formatter for development that only shows the message and
  explicitly passed metadata, filtering out Phoenix's automatic metadata.
  """

  # List of metadata keys that we don't want to see
  @filtered_keys [
    :application,
    :domain,
    :file,
    :line,
    :mfa,
    :pid,
    :request_id,
    :remote_ip,
    :span_id,
    :trace_id,
    :gl,
    :time,
    :erl_level,
    :otel_span_id,
    :otel_trace_flags,
    :otel_trace_id
  ]

  def format(level, message, _timestamp, metadata) do
    custom_metadata =
      metadata
      |> Keyword.drop(@filtered_keys)
      |> format_metadata()

    colored_level = colorize_level(level)

    if custom_metadata != "" do
      [
        "[#{colored_level}] ",
        IO.ANSI.bright(),
        message,
        IO.ANSI.reset(),
        " ",
        IO.ANSI.faint(),
        custom_metadata,
        IO.ANSI.reset(),
        "\n"
      ]
    else
      ["[#{colored_level}] ", IO.ANSI.bright(), message, IO.ANSI.reset(), "\n"]
    end
  end

  defp colorize_level(level) do
    case level do
      :debug -> IO.ANSI.cyan() <> "debug" <> IO.ANSI.reset()
      :info -> IO.ANSI.green() <> "info" <> IO.ANSI.reset()
      :notice -> IO.ANSI.blue() <> "notice" <> IO.ANSI.reset()
      :warning -> IO.ANSI.yellow() <> "warning" <> IO.ANSI.reset()
      :error -> IO.ANSI.red() <> "error" <> IO.ANSI.reset()
      :critical -> IO.ANSI.light_red() <> "critical" <> IO.ANSI.reset()
      :alert -> IO.ANSI.light_red() <> "alert" <> IO.ANSI.reset()
      :emergency -> IO.ANSI.light_red() <> "emergency" <> IO.ANSI.reset()
      _ -> to_string(level)
    end
  end

  defp format_metadata([]), do: ""

  defp format_metadata(metadata) do
    metadata
    |> Enum.map_join(" ", fn {key, value} -> "#{key}=#{inspect(value)}" end)
  end
end
