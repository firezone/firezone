defmodule PortalWeb.Policies.Postures.Checks do
  @moduledoc """
  Named posture checks, each a tree over the provider fields that answer one
  plain question such as "is the disk encrypted".

  The Simple tab writes the expansion into the policy as ordinary rules, and
  recognises a check again by finding that same tree. Any provider that can
  answer the question satisfies the check.
  """

  @type t :: %{
          name: atom(),
          label: String.t(),
          description: String.t(),
          providers: [atom()],
          platforms: [atom()],
          expansion: map()
        }

  @within_a_week "P7D"

  @checks [
    %{
      name: :compliant,
      label: "Compliant",
      description: "The MDM reports the device as compliant with its policies.",
      providers: [:intune],
      platforms: [:windows, :macos, :ios, :android],
      expansion: %{"field" => "intune.compliance_state", "op" => "is", "value" => "compliant"}
    },
    %{
      name: :disk_encryption,
      label: "Disk encryption",
      description: "FileVault, BitLocker or the mobile OS encryption is on.",
      providers: [:intune, :iru],
      platforms: [:windows, :macos, :ios, :android],
      expansion: %{
        "or" => [
          %{"field" => "intune.is_encrypted", "op" => "is", "value" => true},
          %{"field" => "intune.attestation_bit_locker_enabled", "op" => "is", "value" => true},
          %{"field" => "iru.filevault_enabled", "op" => "is", "value" => true}
        ]
      }
    },
    %{
      name: :endpoint_protection,
      label: "Endpoint protection active",
      description: "An EDR agent is onboarded and reporting.",
      providers: [:defender, :sentinelone, :intune],
      platforms: [:windows, :macos, :linux, :ios, :android],
      expansion: %{
        "or" => [
          %{
            "and" => [
              %{"field" => "defender.health_status", "op" => "is", "value" => "Active"},
              %{"field" => "defender.onboarding_status", "op" => "is", "value" => "Onboarded"}
            ]
          },
          %{
            "and" => [
              %{"field" => "sentinelone.is_active", "op" => "is", "value" => true},
              %{"field" => "sentinelone.is_decommissioned", "op" => "is", "value" => false}
            ]
          },
          %{"field" => "intune.partner_reported_threat_state", "op" => "is_in", "value" => ["secured", "lowSeverity"]}
        ]
      }
    },
    %{
      name: :no_active_threats,
      label: "No active threats",
      description: "The EDR reports no infection and no high risk.",
      providers: [:sentinelone, :defender],
      platforms: [:windows, :macos, :linux],
      expansion: %{
        "or" => [
          %{"field" => "sentinelone.infected", "op" => "is", "value" => false},
          %{
            "and" => [
              %{"field" => "defender.risk_score", "op" => "is_not", "value" => "High"},
              %{"field" => "defender.exposure_level", "op" => "is_not", "value" => "High"}
            ]
          }
        ]
      }
    },
    %{
      name: :firewall,
      label: "Firewall enabled",
      description: "The host firewall is turned on.",
      providers: [:iru, :sentinelone],
      platforms: [:windows, :macos, :linux],
      expansion: %{
        "or" => [
          %{"field" => "iru.firewall_enabled", "op" => "is", "value" => true},
          %{"field" => "sentinelone.firewall_enabled", "op" => "is", "value" => true}
        ]
      }
    },
    %{
      name: :not_jailbroken,
      label: "Not jailbroken or rooted",
      description: "The MDM has not flagged the device as jailbroken or rooted.",
      providers: [:intune],
      platforms: [:ios, :android],
      expansion: %{"field" => "intune.jail_broken", "op" => "is", "value" => false}
    },
    %{
      name: :recently_seen,
      label: "Recently seen",
      description: "A provider has heard from the device within the last week.",
      providers: [:intune, :iru, :defender, :santa, :sentinelone],
      platforms: [:windows, :macos, :linux, :ios, :android],
      expansion: %{
        "or" => [
          %{"field" => "intune.last_sync_at", "op" => "within_last", "value" => @within_a_week},
          %{"field" => "iru.last_check_in_at", "op" => "within_last", "value" => @within_a_week},
          %{"field" => "defender.last_seen_at", "op" => "within_last", "value" => @within_a_week},
          %{"field" => "santa.last_sync_at", "op" => "within_last", "value" => @within_a_week},
          %{"field" => "sentinelone.last_active_at", "op" => "within_last", "value" => @within_a_week}
        ]
      }
    },
    %{
      name: :secure_boot,
      label: "Secure boot and system integrity",
      description: "Secure Boot, code integrity, SIP and Gatekeeper are on.",
      providers: [:intune, :iru, :santa],
      platforms: [:windows, :macos],
      expansion: %{
        "or" => [
          %{
            "and" => [
              %{"field" => "intune.attestation_secure_boot", "op" => "is", "value" => true},
              %{"field" => "intune.attestation_code_integrity", "op" => "is", "value" => true}
            ]
          },
          %{
            "and" => [
              %{"field" => "iru.secure_boot_level", "op" => "is", "value" => "full"},
              %{"field" => "iru.sip_enabled", "op" => "is", "value" => true},
              %{"field" => "iru.ssv_enabled", "op" => "is", "value" => true},
              %{"field" => "iru.gatekeeper_enabled", "op" => "is", "value" => true}
            ]
          },
          %{"field" => "santa.sip_status", "op" => "eq", "value" => 1}
        ]
      }
    },
    %{
      name: :no_debugging,
      label: "No debugging or test signing",
      description: "Boot debugging, test signing and safe mode are all off.",
      providers: [:intune],
      platforms: [:windows],
      expansion: %{
        "and" => [
          %{"field" => "intune.attestation_boot_debugging", "op" => "is", "value" => false},
          %{"field" => "intune.attestation_test_signing", "op" => "is", "value" => false},
          %{"field" => "intune.attestation_safe_mode", "op" => "is", "value" => false}
        ]
      }
    },
    %{
      name: :corporate_owned,
      label: "Corporate owned",
      description: "The MDM records the device as company owned, not personal.",
      providers: [:intune],
      platforms: [:windows, :macos, :ios, :android],
      expansion: %{"field" => "intune.managed_device_owner_type", "op" => "is", "value" => "company"}
    },
    %{
      name: :supervised,
      label: "Supervised",
      description: "The Apple device is supervised by the MDM.",
      providers: [:intune],
      platforms: [:macos, :ios],
      expansion: %{"field" => "intune.is_supervised", "op" => "is", "value" => true}
    },
    %{
      name: :app_allowlisting,
      label: "Application allowlisting enforced",
      description: "Santa runs in lockdown mode, so only allowed binaries execute.",
      providers: [:santa],
      platforms: [:macos],
      expansion: %{"field" => "santa.configured_client_mode", "op" => "is", "value" => "LOCKDOWN"}
    },
    %{
      name: :agent_up_to_date,
      label: "Endpoint agent up to date",
      description: "The EDR agent runs its current release.",
      providers: [:sentinelone],
      platforms: [:windows, :macos, :linux],
      expansion: %{"field" => "sentinelone.is_up_to_date", "op" => "is", "value" => true}
    },
    %{
      name: :os_up_to_date,
      label: "OS up to date",
      description: "The OS runs the newest release of its line, or Android carries the latest security patch level.",
      providers: [:intune, :iru, :defender, :santa, :sentinelone],
      platforms: [:windows, :macos, :ios, :android],
      expansion: %{
        "or" => [
          %{"field" => "intune.os_up_to_date", "op" => "is", "value" => true},
          %{"field" => "iru.os_up_to_date", "op" => "is", "value" => true},
          %{"field" => "defender.os_up_to_date", "op" => "is", "value" => true},
          %{"field" => "santa.os_up_to_date", "op" => "is", "value" => true},
          %{"field" => "sentinelone.os_up_to_date", "op" => "is", "value" => true}
        ]
      }
    },
    %{
      name: :client_up_to_date,
      label: "Firezone Client up to date",
      description: "The Firezone Client runs the latest release for its platform.",
      providers: [:firezone],
      platforms: [:windows, :macos, :linux, :ios, :android],
      expansion: %{"field" => "firezone.last_seen_version", "op" => "gte", "value" => "@latest"}
    },
    %{
      name: :managed,
      label: "Managed by an MDM",
      description: "An MDM holds a record for the device at all.",
      providers: [:intune, :iru],
      platforms: [:windows, :macos, :ios, :android],
      expansion: %{
        "or" => [
          %{"field" => "intune.enrolled", "op" => "is", "value" => true},
          %{"field" => "iru.enrolled", "op" => "is", "value" => true}
        ]
      }
    }
  ]

  @by_name Map.new(@checks, &{&1.name, &1})
  @names Enum.map(@checks, & &1.name)
  @by_string Map.new(@checks, &{Atom.to_string(&1.name), &1})

  @spec all() :: [t()]
  def all, do: @checks

  @spec names() :: [atom()]
  def names, do: @names

  @spec fetch(atom() | String.t()) :: {:ok, t()} | :error
  def fetch(name) when is_atom(name), do: Map.fetch(@by_name, name)
  def fetch(name) when is_binary(name), do: Map.fetch(@by_string, name)
end
