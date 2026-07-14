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
      retroactive: false
    })
  end

  def valid_datadog_log_sink_attrs(attrs \\ %{}) do
    unique_num = System.unique_integer([:positive, :monotonic])

    Enum.into(attrs, %{
      name: "Datadog #{unique_num}",
      site: "datadoghq.com",
      api_key: "dd-api-key-#{unique_num}",
      enabled_streams: ~w[change session api_request flow]a,
      retroactive: false
    })
  end

  def datadog_log_sink_fixture(attrs \\ %{}) do
    attrs = Enum.into(attrs, %{})

    account = Map.get(attrs, :account) || account_fixture()

    {:ok, log_sink} =
      %Portal.LogSink{
        id: Ecto.UUID.generate(),
        account_id: account.id
      }
      |> Ecto.Changeset.cast(%{type: :datadog}, [:type])
      |> Portal.LogSink.changeset()
      |> Portal.Repo.insert()

    datadog_attrs =
      attrs
      |> Map.delete(:account)
      |> Enum.into(%{
        id: log_sink.id,
        account_id: account.id
      })
      |> valid_datadog_log_sink_attrs()

    {:ok, datadog_log_sink} =
      %Portal.Datadog.LogSink{}
      |> Ecto.Changeset.cast(datadog_attrs, [
        :id,
        :account_id,
        :name,
        :site,
        :api_key,
        :tags,
        :enabled_streams,
        :retroactive,
        :errored_at,
        :error_message,
        :error_email_count,
        :last_error_email_at,
        :is_disabled,
        :disabled_reason
      ])
      |> Portal.Datadog.LogSink.changeset()
      |> Portal.Repo.insert()

    datadog_log_sink
  end

  def valid_newrelic_log_sink_attrs(attrs \\ %{}) do
    unique_num = System.unique_integer([:positive, :monotonic])

    Enum.into(attrs, %{
      name: "New Relic #{unique_num}",
      region: "US",
      license_key: "nr-license-key-#{unique_num}",
      enabled_streams: ~w[change session api_request flow]a,
      retroactive: false
    })
  end

  def newrelic_log_sink_fixture(attrs \\ %{}) do
    attrs = Enum.into(attrs, %{})

    account = Map.get(attrs, :account) || account_fixture()

    {:ok, log_sink} =
      %Portal.LogSink{
        id: Ecto.UUID.generate(),
        account_id: account.id
      }
      |> Ecto.Changeset.cast(%{type: :newrelic}, [:type])
      |> Portal.LogSink.changeset()
      |> Portal.Repo.insert()

    newrelic_attrs =
      attrs
      |> Map.delete(:account)
      |> Enum.into(%{
        id: log_sink.id,
        account_id: account.id
      })
      |> valid_newrelic_log_sink_attrs()

    {:ok, newrelic_log_sink} =
      %Portal.NewRelic.LogSink{}
      |> Ecto.Changeset.cast(newrelic_attrs, [
        :id,
        :account_id,
        :name,
        :region,
        :license_key,
        :enabled_streams,
        :retroactive,
        :errored_at,
        :error_message,
        :error_email_count,
        :last_error_email_at,
        :is_disabled,
        :disabled_reason
      ])
      |> Portal.NewRelic.LogSink.changeset()
      |> Portal.Repo.insert()

    newrelic_log_sink
  end

  def valid_elastic_log_sink_attrs(attrs \\ %{}) do
    unique_num = System.unique_integer([:positive, :monotonic])

    Enum.into(attrs, %{
      name: "Elastic #{unique_num}",
      endpoint_url: "https://deployment#{unique_num}.es.us-east-1.aws.elastic-cloud.example",
      api_key: "es-api-key-#{unique_num}",
      data_stream: "logs-firezone-default",
      enabled_streams: ~w[change session api_request flow]a,
      retroactive: false
    })
  end

  def elastic_log_sink_fixture(attrs \\ %{}) do
    attrs = Enum.into(attrs, %{})

    account = Map.get(attrs, :account) || account_fixture()

    {:ok, log_sink} =
      %Portal.LogSink{
        id: Ecto.UUID.generate(),
        account_id: account.id
      }
      |> Ecto.Changeset.cast(%{type: :elastic}, [:type])
      |> Portal.LogSink.changeset()
      |> Portal.Repo.insert()

    elastic_attrs =
      attrs
      |> Map.delete(:account)
      |> Enum.into(%{
        id: log_sink.id,
        account_id: account.id
      })
      |> valid_elastic_log_sink_attrs()

    {:ok, elastic_log_sink} =
      %Portal.Elastic.LogSink{}
      |> Ecto.Changeset.cast(elastic_attrs, [
        :id,
        :account_id,
        :name,
        :endpoint_url,
        :api_key,
        :data_stream,
        :enabled_streams,
        :retroactive,
        :errored_at,
        :error_message,
        :error_email_count,
        :last_error_email_at,
        :is_disabled,
        :disabled_reason
      ])
      |> Portal.Elastic.LogSink.changeset()
      |> Portal.Repo.insert()

    elastic_log_sink
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
        :errored_at,
        :error_message,
        :error_email_count,
        :last_error_email_at,
        :is_disabled,
        :disabled_reason
      ])
      |> Portal.Splunk.LogSink.changeset()
      |> Portal.Repo.insert()

    splunk_log_sink
  end
end
