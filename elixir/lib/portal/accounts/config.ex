defmodule Portal.Accounts.Config do
  use Ecto.Schema
  import Ecto.Changeset

  @type t :: %__MODULE__{
          search_domain: String.t() | nil,
          clients_upstream_dns: Portal.UpstreamDNS.t() | nil
        }

  @primary_key false
  embedded_schema do
    field :search_domain, :string

    embeds_one :clients_upstream_dns, Portal.UpstreamDNS, on_replace: :update
  end

  @doc """
  Returns a default config with defaults set
  """
  def default_config do
    %__MODULE__{
      clients_upstream_dns: %Portal.UpstreamDNS{
        type: :system
      }
    }
  end

  @doc """
  Ensures a config has proper defaults
  """
  def ensure_defaults(%__MODULE__{} = config), do: config

  def ensure_defaults(nil), do: default_config()

  @doc """
  Changeset function for embedded Config
  """
  def changeset(config \\ %__MODULE__{}, attrs) do
    config
    |> cast(attrs, [:search_domain])
    |> cast_embed(:clients_upstream_dns, with: &Portal.UpstreamDNS.changeset/2)
    |> validate_search_domain()
  end

  defp validate_search_domain(changeset) do
    changeset
    |> validate_change(:search_domain, fn :search_domain, domain ->
      cond do
        domain == nil || domain == "" ->
          [search_domain: "cannot be empty"]

        String.length(domain) > 255 ->
          [search_domain: "must not exceed 255 characters"]

        String.starts_with?(domain, ".") ->
          [search_domain: "must not start with a dot"]

        String.contains?(domain, "..") ->
          [search_domain: "must not contain consecutive dots"]

        !String.match?(domain, ~r/^[a-z0-9][a-z0-9.-]*\.[a-z]{2,}$/i) ->
          [search_domain: "must be a valid fully-qualified domain name"]

        Enum.any?(String.split(domain, "."), &(String.length(&1) > 63)) ->
          [search_domain: "each label must not exceed 63 characters"]

        true ->
          []
      end
    end)
  end
end
