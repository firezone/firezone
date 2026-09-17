defmodule PortalWeb.Policies.Postures do
  @moduledoc """
  Editor state for a policy's device postures: the named checks it turns on.

  A check is written into the policy as the plain rules the grammar already has,
  and recognised again by finding that same tree, so the policy stores nothing
  the REST API does not. A tree the checks cannot express, written through the
  API, is shown as custom and saved back untouched.
  """

  alias __MODULE__.{Checks, Database}
  alias Portal.Policies.Postures

  @type t :: %{
          availability: :enabled | :locked | :hidden,
          connected: [atom()],
          trust_anchors?: boolean(),
          wire: map() | nil
        }

  @spec availability(Portal.Account.t()) :: :enabled | :locked | :hidden
  def availability(account) do
    cond do
      Portal.Account.device_posture_enabled?(account) -> :enabled
      Portal.Features.enabled?(:device_posture) -> :locked
      true -> :hidden
    end
  end

  @spec for_account(Portal.Account.t(), Postures.t() | nil) :: t()
  def for_account(account, postures \\ nil) do
    new(availability(account), postures,
      connected: Database.list_connected_provider_types(account.id),
      trust_anchors?: Database.trust_anchors?(account.id)
    )
  end

  @spec new(:enabled | :locked | :hidden, Postures.t() | nil, keyword()) :: t()
  def new(availability, postures \\ nil, opts \\ []) do
    %{
      availability: availability,
      connected: Keyword.get(opts, :connected, []),
      trust_anchors?: Keyword.get(opts, :trust_anchors?, true),
      wire: if(postures, do: Postures.to_map(postures))
    }
  end

  @doc "Drops the postures attribute when the account cannot use them."
  @spec maybe_drop_unsupported(map(), t()) :: map()
  def maybe_drop_unsupported(attrs, %{availability: :enabled}), do: attrs
  def maybe_drop_unsupported(attrs, _state), do: Map.delete(attrs, "postures")

  @doc "The value the hidden `policy[postures]` input carries: the tree as JSON, or nothing."
  @spec hidden_value(t()) :: String.t()
  def hidden_value(%{wire: nil}), do: ""
  def hidden_value(%{wire: wire}), do: JSON.encode!(wire)

  @spec handle_event(String.t(), map(), t()) :: t()
  def handle_event("postures_toggle_check", %{"name" => name}, state) do
    with {:ok, check} <- Checks.fetch(name),
         {:ok, names} <- checks(state) do
      names =
        if check.name in names do
          List.delete(names, check.name)
        else
          names ++ [check.name]
        end

      %{state | wire: wire_for(names)}
    else
      _custom_or_unknown -> state
    end
  end

  def handle_event(_event, _params, state), do: state

  @doc """
  The checks the policy turns on: none, one check's tree, or an `and` of
  several. Anything else is `:custom` and came from the API.
  """
  @spec checks(t()) :: {:ok, [atom()]} | :custom
  def checks(%{wire: nil}), do: {:ok, []}

  def checks(%{wire: %{"and" => children}}) when is_list(children) do
    names = Enum.map(children, &check_name/1)

    if Enum.all?(names) do
      {:ok, names}
    else
      :custom
    end
  end

  def checks(%{wire: wire}) do
    case check_name(wire) do
      nil -> :custom
      name -> {:ok, [name]}
    end
  end

  @doc "Whether a provider that can answer the check is connected to the account."
  @spec check_available?(t(), Checks.t()) :: boolean()
  def check_available?(state, check) do
    :firezone in check.providers or Enum.any?(check.providers, &(&1 in state.connected))
  end

  defp check_name(wire) do
    Enum.find_value(Checks.all(), fn check -> check.expansion == wire and check.name end)
  end

  defp wire_for([]), do: nil
  defp wire_for([name]), do: expansion(name)
  defp wire_for(names), do: %{"and" => Enum.map(names, &expansion/1)}

  defp expansion(name) do
    {:ok, check} = Checks.fetch(name)
    check.expansion
  end

  defmodule Database do
    import Ecto.Query
    alias Portal.{Defender, Intune, Iru, Safe, Santa, SentinelOne}

    @providers %{
      "intune" => {Intune.PostureProvider, :intune},
      "iru" => {Iru.PostureProvider, :iru},
      "defender" => {Defender.PostureProvider, :defender},
      "santa" => {Santa.PostureProvider, :santa},
      "sentinelone" => {SentinelOne.PostureProvider, :sentinelone}
    }

    # A `limit` on any branch would apply to the whole union, so the branches
    # return every enabled provider and `union` folds the repeats.
    def list_connected_provider_types(account_id) do
      @providers
      |> Enum.map(fn {name, {schema, _type}} ->
        from(p in schema,
          where: p.account_id == ^account_id and not p.is_disabled,
          select: type(^name, :string)
        )
      end)
      |> Enum.reduce(fn query, acc -> union(acc, ^query) end)
      |> Safe.unscoped()
      |> Safe.all()
      |> Enum.map(fn name -> @providers |> Map.fetch!(name) |> elem(1) end)
    end

    def trust_anchors?(account_id) do
      from(t in Portal.TrustAnchorCertificate, where: t.account_id == ^account_id)
      |> Safe.unscoped()
      |> Safe.exists?()
    end
  end
end
