defmodule Portal.Repo.Migrations.CreateLogSinkFieldTypes do
  use Ecto.Migration

  @objects ~w[before after subject]

  @integers ~w[content_length inner_src_port inner_dst_port outer_src_port outer_dst_port
               rx_packets tx_packets rx_bytes tx_bytes]

  @strings ~w[type log_id timestamp object operation context actor_id api_token_id method
              path request_id user_agent ip ip_region ip_city phase flow_start flow_end
              last_packet device_id role policy_authorization_id policy_id resource_id
              resource_name resource_address actor_email actor_name client_version
              device_os_name device_os_version protocol inner_src_ip inner_dst_ip
              outer_src_ip outer_dst_ip domain]

  # Nested payload paths are qualified by producer (change payloads collide
  # across tables). Subject shapes are fixed contracts (Subject.to_map plus
  # the client/gateway session extras), so seed them; change.{table}.{column}
  # paths are unbounded and register themselves at runtime instead.
  @subject_strings ~w[actor_id actor_name actor_email actor_type auth_provider_id
                      ip ip_region ip_city user_agent]

  @subject_numbers ~w[ip_lat ip_lon]

  @session_subject_strings ~w[device_id gateway_id token_id]

  def up do
    create table(:log_sink_field_types, primary_key: false) do
      add(:name, :string, null: false, primary_key: true)
      add(:type, :string, null: false)
      add(:inserted_at, :timestamptz, null: false)
    end

    # Seed the current envelope so steady-state delivery never has to write;
    # runtime registration only fires for fields added in future releases.
    subject_paths =
      for stream <- ~w[change session], {names, type} <- [{@subject_strings, "string"}, {@subject_numbers, "number"}],
          name <- names do
        {"#{stream}.subject.#{name}", type}
      end

    session_subject_paths =
      Enum.map(@session_subject_strings, &{"session.subject.#{&1}", "string"})

    values =
      Enum.map_join(
        Enum.map(@objects, &{&1, "object"}) ++
          Enum.map(@integers, &{&1, "integer"}) ++
          Enum.map(@strings, &{&1, "string"}) ++
          subject_paths ++ session_subject_paths,
        ", ",
        fn {name, type} -> "('#{name}', '#{type}', now())" end
      )

    execute("INSERT INTO log_sink_field_types (name, type, inserted_at) VALUES #{values}")
  end

  def down do
    drop(table(:log_sink_field_types))
  end
end
