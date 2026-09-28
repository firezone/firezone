defmodule Portal.Features do
  # credo:disable-for-this-file Credo.Check.Warning.MissingChangesetFunction
  use Ecto.Schema

  @features [:x509_auth, :aes_gcm]
  @type feature :: :x509_auth | :aes_gcm

  @cache_ttl :timer.seconds(10)

  @primary_key false

  schema "features" do
    field :feature, Ecto.Enum, values: @features
    field :enabled, :boolean, default: false
  end

  @spec enabled?(feature()) :: boolean()
  def enabled?(feature) when feature in @features, do: __MODULE__.Database.enabled?(feature)

  @doc """
  Like `enabled?/1`, but reads through a per-node cache so hot paths do not
  query the database on every call. A flip in the database is seen within
  `:cache_ttl` milliseconds.
  """
  @spec cached_enabled?(feature()) :: boolean()
  def cached_enabled?(feature) when feature in @features do
    ttl = Keyword.get(Portal.Config.get_env(:portal, __MODULE__, []), :cache_ttl, @cache_ttl)
    now = System.monotonic_time(:millisecond)

    case :ets.lookup(__MODULE__.Cache, feature) do
      [{^feature, enabled, fetched_at}] when now - fetched_at < ttl ->
        enabled

      _ ->
        enabled = enabled?(feature)
        :ets.insert(__MODULE__.Cache, {feature, enabled, now})
        enabled
    end
  end

  defmodule Cache do
    use GenServer

    def start_link(_opts), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

    @impl true
    def init(nil) do
      :ets.new(__MODULE__, [:named_table, :public, :set, read_concurrency: true])
      {:ok, nil}
    end
  end

  defmodule Database do
    import Ecto.Query

    alias Portal.Safe

    def enabled?(feature) do
      from(f in Portal.Features, where: f.feature == ^feature and f.enabled == true)
      |> Safe.unscoped()
      |> Safe.exists?()
    end
  end
end
