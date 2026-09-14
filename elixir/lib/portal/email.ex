defmodule Portal.Email do
  import Portal.Changeset, only: [try_encode_domain: 1]

  @doc """
  Normalizes an email address while preserving the local part's case.

  Whitespace around each component is removed and the domain is lowercased
  and IDNA-encoded. This only normalizes the address; callers that accept user
  input must still validate it separately.
  """
  @spec normalize(String.t()) :: {:ok, String.t()} | :error
  def normalize(email) when is_binary(email) do
    case String.split(email, "@", parts: 2) do
      [local, domain] ->
        local = String.trim(local)
        domain = domain |> String.trim() |> String.downcase()

        case try_encode_domain(domain) do
          {:ok, punycode_domain} -> {:ok, local <> "@" <> to_string(punycode_domain)}
          _error -> :error
        end

      _ ->
        {:ok, String.trim(email)}
    end
  end

  @doc """
  Normalizes an email address for case-insensitive matching.
  """
  @spec normalize_for_match(String.t()) :: {:ok, String.t()} | :error
  def normalize_for_match(email) when is_binary(email) do
    case normalize(email) do
      {:ok, email} -> {:ok, String.downcase(email)}
      :error -> :error
    end
  end
end
