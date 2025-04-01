defmodule Domain.Auth.Adapters.Mock.Jobs.SyncDirectory do
  use Domain.Jobs.Job,
    otp_app: :domain,
    # Database lock prevents updating more frequently than 10 minutes
    every: :timer.minutes(1),
    executor: Domain.Jobs.Executors.Concurrent

  alias Domain.Auth.Adapter.OpenIDConnect.DirectorySync
  require Logger
  require OpenTelemetry.Tracer

  @task_supervisor __MODULE__.TaskSupervisor

  @impl true
  def state(_config) do
    {:ok, pid} = Task.Supervisor.start_link(name: @task_supervisor)
    {:ok, %{task_supervisor: pid}}
  end

  @impl true
  def execute(%{task_supervisor: pid}) do
    DirectorySync.sync_providers(__MODULE__, :mock, pid)
  end

  def gather_provider_data(provider, _task_supervisor_pid) do
    num_groups = provider.adapter_config["num_groups"]
    num_actors = provider.adapter_config["num_actors"]
    max_actors_per_group = provider.adapter_config["max_actors_per_group"]

    identities_attrs =
      1..num_actors
      |> Enum.map(fn i ->
        first_name = Domain.NameGenerator.generate_first_name()
        last_name = Domain.NameGenerator.generate_last_name()

        %{
          "provider_identifier" => "U:#{i}",
          "provider_state" => %{
            "userinfo" => %{
              "email" => "#{String.downcase(first_name)}@example.com"
            }
          },
          "actor" => %{
            "type" => :account_user,
            "name" => "#{first_name} #{last_name}"
          }
        }
      end)

    actor_groups_attrs =
      1..num_groups
      |> Enum.map(fn i ->
        group_name = Domain.NameGenerator.generate()

        %{
          "name" => "Group:#{group_name}",
          "provider_identifier" => "G:#{i}"
        }
      end)

    membership_tuples =
      Enum.flat_map(1..num_groups, fn i ->
        group = Enum.at(actor_groups_attrs, i - 1)
        num_members = :rand.uniform(max_actors_per_group)
        identities = Enum.take_random(identities_attrs, num_members)

        Enum.map(identities, fn identity ->
          {group["provider_identifier"], identity["provider_identifier"]}
        end)
      end)

    {:ok, {identities_attrs, actor_groups_attrs, membership_tuples}}
  end
end
