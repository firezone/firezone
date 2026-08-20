defmodule Portal.OAuth.Scope do
  @moduledoc """
  The scopes this authorization server issues.

  `mcp:write` implies `mcp:read`: a broader scope has to satisfy a check for a
  narrower one, so write is always stored alongside read rather than on its own.
  """

  import Ecto.Changeset

  @read "mcp:read"
  @write "mcp:write"
  @all [@read, @write]

  def read, do: @read
  def write, do: @write

  @doc "Every scope a client may ask for."
  def all, do: @all

  @doc """
  Scopes advertised as the minimum needed for basic use, per the least
  privilege guidance in the MCP authorization spec.
  """
  def supported, do: [@read]

  @doc """
  Parses a space delimited `scope` parameter.

  An absent or empty parameter means read only, which keeps a client that
  ignores the challenge from silently receiving write access.
  """
  def parse(nil), do: {:ok, [@read]}

  def parse(scope) when is_binary(scope) do
    case scope |> String.split(" ", trim: true) |> Enum.uniq() do
      [] ->
        {:ok, [@read]}

      requested ->
        case Enum.reject(requested, &(&1 in @all)) do
          [] -> {:ok, normalize(requested)}
          unknown -> {:error, unknown}
        end
    end
  end

  @doc "Renders scopes back into a space delimited parameter."
  def encode(scopes), do: Enum.join(scopes, " ")

  @doc "Adds the scopes implied by the ones granted."
  def normalize(scopes) do
    if @write in scopes do
      [@read, @write]
    else
      Enum.filter(@all, &(&1 in scopes))
    end
  end

  @doc "Whether `granted` satisfies `required`, honouring implication."
  def satisfies?(granted, required) do
    normalized = normalize(granted)
    Enum.all?(List.wrap(required), &(&1 in normalized))
  end

  @doc "Whether every scope in `requested` is one this server issues."
  def known?(requested), do: Enum.all?(requested, &(&1 in @all))

  def validate(changeset, field) do
    validate_change(changeset, field, fn ^field, scopes ->
      case Enum.reject(scopes, &(&1 in @all)) do
        [] -> []
        unknown -> [{field, "contains unknown scopes: #{Enum.join(unknown, ", ")}"}]
      end
    end)
  end
end
