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
        :last_rollover_at,
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

  def valid_sentinel_log_sink_attrs(attrs \\ %{}) do
    unique_num = System.unique_integer([:positive, :monotonic])

    Enum.into(attrs, %{
      name: "Microsoft Sentinel #{unique_num}",
      tenant_id: Ecto.UUID.generate(),
      ingestion_endpoint: "https://dce#{unique_num}.eastus-1.ingest.monitor.azure.com",
      dcr_immutable_id: "dcr-#{String.replace(Ecto.UUID.generate(), "-", "")}",
      stream_name: "Custom-FirezoneLogs_CL",
      enabled_streams: ~w[change session api_request flow]a,
      retroactive: false
    })
  end

  def sentinel_log_sink_fixture(attrs \\ %{}) do
    attrs = Enum.into(attrs, %{})

    account = Map.get(attrs, :account) || account_fixture()

    {:ok, log_sink} =
      %Portal.LogSink{
        id: Ecto.UUID.generate(),
        account_id: account.id
      }
      |> Ecto.Changeset.cast(%{type: :sentinel}, [:type])
      |> Portal.LogSink.changeset()
      |> Portal.Repo.insert()

    sentinel_attrs =
      attrs
      |> Map.delete(:account)
      |> Enum.into(%{
        id: log_sink.id,
        account_id: account.id
      })
      |> valid_sentinel_log_sink_attrs()

    {:ok, sentinel_log_sink} =
      %Portal.Sentinel.LogSink{}
      |> Ecto.Changeset.cast(sentinel_attrs, [
        :id,
        :account_id,
        :name,
        :tenant_id,
        :ingestion_endpoint,
        :dcr_immutable_id,
        :stream_name,
        :enabled_streams,
        :retroactive,
        :errored_at,
        :error_message,
        :error_email_count,
        :last_error_email_at,
        :is_disabled,
        :disabled_reason
      ])
      |> Portal.Sentinel.LogSink.changeset()
      |> Portal.Repo.insert()

    sentinel_log_sink
  end

  def valid_qradar_log_sink_attrs(attrs \\ %{}) do
    unique_num = System.unique_integer([:positive, :monotonic])

    Enum.into(attrs, %{
      name: "IBM QRadar #{unique_num}",
      endpoint_url: "https://qradar#{unique_num}.example:12469",
      enabled_streams: ~w[change session api_request flow]a,
      retroactive: false
    })
  end

  def qradar_log_sink_fixture(attrs \\ %{}) do
    attrs = Enum.into(attrs, %{})

    account = Map.get(attrs, :account) || account_fixture()

    {:ok, log_sink} =
      %Portal.LogSink{
        id: Ecto.UUID.generate(),
        account_id: account.id
      }
      |> Ecto.Changeset.cast(%{type: :qradar}, [:type])
      |> Portal.LogSink.changeset()
      |> Portal.Repo.insert()

    qradar_attrs =
      attrs
      |> Map.delete(:account)
      |> Enum.into(%{
        id: log_sink.id,
        account_id: account.id
      })
      |> valid_qradar_log_sink_attrs()

    {:ok, qradar_log_sink} =
      %Portal.QRadar.LogSink{}
      |> Ecto.Changeset.cast(qradar_attrs, [
        :id,
        :account_id,
        :name,
        :endpoint_url,
        :auth_header,
        :enabled_streams,
        :retroactive,
        :errored_at,
        :error_message,
        :error_email_count,
        :last_error_email_at,
        :is_disabled,
        :disabled_reason
      ])
      |> Portal.QRadar.LogSink.changeset()
      |> Portal.Repo.insert()

    qradar_log_sink
  end

  def valid_s3_log_sink_attrs(attrs \\ %{}) do
    unique_num = System.unique_integer([:positive, :monotonic])

    Enum.into(attrs, %{
      name: "Amazon S3 #{unique_num}",
      bucket: "firezone-logs-#{unique_num}",
      region: "us-east-1",
      role_arn: "arn:aws:iam::123456789012:role/firezone-logs-#{unique_num}",
      external_id: Ecto.UUID.generate(),
      enabled_streams: ~w[change session api_request flow]a,
      retroactive: false
    })
  end

  def s3_log_sink_fixture(attrs \\ %{}) do
    attrs = Enum.into(attrs, %{})

    account = Map.get(attrs, :account) || account_fixture()

    {:ok, log_sink} =
      %Portal.LogSink{
        id: Ecto.UUID.generate(),
        account_id: account.id
      }
      |> Ecto.Changeset.cast(%{type: :s3}, [:type])
      |> Portal.LogSink.changeset()
      |> Portal.Repo.insert()

    s3_attrs =
      attrs
      |> Map.delete(:account)
      |> Enum.into(%{
        id: log_sink.id,
        account_id: account.id
      })
      |> valid_s3_log_sink_attrs()

    {:ok, s3_log_sink} =
      %Portal.S3.LogSink{}
      |> Ecto.Changeset.cast(s3_attrs, [
        :id,
        :account_id,
        :name,
        :bucket,
        :region,
        :role_arn,
        :key_prefix,
        :external_id,
        :enabled_streams,
        :retroactive,
        :errored_at,
        :error_message,
        :error_email_count,
        :last_error_email_at,
        :is_disabled,
        :disabled_reason
      ])
      |> Portal.S3.LogSink.changeset()
      |> Portal.Repo.insert()

    s3_log_sink
  end

  def valid_http_log_sink_attrs(attrs \\ %{}) do
    unique_num = System.unique_integer([:positive, :monotonic])

    Enum.into(attrs, %{
      name: "HTTP #{unique_num}",
      endpoint_url: "https://logs#{unique_num}.webhook.example/ingest",
      bearer_token: "http-bearer-token-#{unique_num}",
      batch_max_events: 100,
      enabled_streams: ~w[change session api_request flow]a,
      retroactive: false
    })
  end

  def http_log_sink_fixture(attrs \\ %{}) do
    attrs = Enum.into(attrs, %{})

    account = Map.get(attrs, :account) || account_fixture()

    {:ok, log_sink} =
      %Portal.LogSink{
        id: Ecto.UUID.generate(),
        account_id: account.id
      }
      |> Ecto.Changeset.cast(%{type: :http}, [:type])
      |> Portal.LogSink.changeset()
      |> Portal.Repo.insert()

    http_attrs =
      attrs
      |> Map.delete(:account)
      |> Enum.into(%{
        id: log_sink.id,
        account_id: account.id
      })
      |> valid_http_log_sink_attrs()

    {:ok, http_log_sink} =
      %Portal.HTTP.LogSink{}
      |> Ecto.Changeset.cast(http_attrs, [
        :id,
        :account_id,
        :name,
        :endpoint_url,
        :bearer_token,
        :batch_max_events,
        :enabled_streams,
        :retroactive,
        :errored_at,
        :error_message,
        :error_email_count,
        :last_error_email_at,
        :is_disabled,
        :disabled_reason
      ])
      |> Portal.HTTP.LogSink.changeset()
      |> Portal.Repo.insert()

    http_log_sink
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
