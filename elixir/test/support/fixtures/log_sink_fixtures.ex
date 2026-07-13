defmodule Portal.LogSinkFixtures do
  @moduledoc """
  Test helpers for creating log sinks.

  Fixtures return the provider-specific struct (e.g. Portal.Splunk.LogSink)
  and create the base Portal.LogSink row alongside it.
  """

  import Portal.AccountFixtures

  def valid_splunk_log_sink_attrs(attrs \\ %{}) do
    unique_num = System.unique_integer([:positive, :monotonic])

    Enum.into(attrs, %{
      name: "Splunk #{unique_num}",
      collector_url: "https://http-inputs-test#{unique_num}.splunkcloud.example",
      hec_token: "hec-token-#{unique_num}",
      enabled_streams: ~w[change session api_request flow]a,
      retroactive: false,
      created_by: "system"
    })
  end

  def splunk_log_sink_fixture(attrs \\ %{}) do
    attrs = Enum.into(attrs, %{})

    account = Map.get(attrs, :account) || account_fixture()

    {:ok, log_sink} =
      %Portal.LogSink{
        id: Ecto.UUID.generate(),
        account_id: account.id
      }
      |> Ecto.Changeset.cast(%{type: :splunk}, [:type])
      |> Portal.LogSink.changeset()
      |> Portal.Repo.insert()

    splunk_attrs =
      attrs
      |> Map.delete(:account)
      |> Enum.into(%{
        id: log_sink.id,
        account_id: account.id
      })
      |> valid_splunk_log_sink_attrs()

    {:ok, splunk_log_sink} =
      %Portal.Splunk.LogSink{}
      |> Ecto.Changeset.cast(splunk_attrs, [
        :id,
        :account_id,
        :name,
        :collector_url,
        :hec_token,
        :index,
        :enabled_streams,
        :retroactive,
        :is_verified,
        :errored_at,
        :error_message,
        :is_disabled,
        :disabled_reason,
        :created_by
      ])
      |> Portal.Splunk.LogSink.changeset()
      |> Portal.Repo.insert()

    splunk_log_sink
  end
end
