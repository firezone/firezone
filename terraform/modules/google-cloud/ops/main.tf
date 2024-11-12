resource "google_monitoring_notification_channel" "slack" {
  project = var.project_id

  display_name = "Slack: ${var.slack_alerts_channel}"
  type         = "slack"

  labels = {
    "channel_name" = var.slack_alerts_channel
  }

  sensitive_labels {
    auth_token = var.slack_alerts_auth_token
  }
}

resource "google_monitoring_notification_channel" "pagerduty" {
  count = var.pagerduty_auth_token != null ? 1 : 0

  project = var.project_id

  display_name = "PagerDuty"
  type         = "pagerduty"

  sensitive_labels {
    service_key = var.pagerduty_auth_token
  }
}

locals {
  notification_channels = concat(
    [google_monitoring_notification_channel.slack.name],
    var.additional_notification_channels,
    google_monitoring_notification_channel.pagerduty[*].name
  )
}

resource "google_monitoring_uptime_check_config" "api-https" {
  project = var.project_id

  display_name = "api-https"
  timeout      = "60s"

  http_check {
    port         = "443"
    use_ssl      = true
    validate_ssl = true

    request_method = "GET"
    path           = "/healthz"

    accepted_response_status_codes {
      status_class = "STATUS_CLASS_2XX"
    }
  }

  monitored_resource {
    type = "uptime_url"

    labels = {
      project_id = var.project_id
      host       = var.api_host
    }
  }

  content_matchers {
    content = "\"ok\""
    matcher = "MATCHES_JSON_PATH"

    json_path_matcher {
      json_path    = "$.status"
      json_matcher = "EXACT_MATCH"
    }
  }

  checker_type = "STATIC_IP_CHECKERS"
}

resource "google_monitoring_uptime_check_config" "web-https" {
  project = var.project_id

  display_name = "web-https"
  timeout      = "60s"

  http_check {
    port         = "443"
    use_ssl      = true
    validate_ssl = true

    request_method = "GET"

    path = "/healthz"

    accepted_response_status_codes {
      status_class = "STATUS_CLASS_2XX"
    }
  }

  monitored_resource {
    type = "uptime_url"

    labels = {
      project_id = var.project_id
      host       = var.web_host
    }
  }

  content_matchers {
    content = "\"ok\""
    matcher = "MATCHES_JSON_PATH"

    json_path_matcher {
      json_path    = "$.status"
      json_matcher = "EXACT_MATCH"
    }
  }

  checker_type = "STATIC_IP_CHECKERS"
}

resource "google_monitoring_alert_policy" "api-downtime" {
  project = var.project_id

  display_name = "API service is DOWN!"
  combiner     = "OR"

  notification_channels = local.notification_channels

  conditions {
    display_name = "Uptime Health Check on api-https"

    condition_threshold {
      filter     = "resource.type = \"uptime_url\" AND metric.type = \"monitoring.googleapis.com/uptime_check/check_passed\" AND metric.labels.check_id = \"${reverse(split("/", google_monitoring_uptime_check_config.api-https.id))[0]}\""
      comparison = "COMPARISON_GT"

      threshold_value = 1
      duration        = "0s"

      trigger {
        count = 1
      }

      aggregations {
        alignment_period     = "60s"
        cross_series_reducer = "REDUCE_COUNT_FALSE"
        per_series_aligner   = "ALIGN_NEXT_OLDER"

        group_by_fields = [
          "resource.label.project_id",
          "resource.label.host"
        ]
      }
    }
  }

  alert_strategy {
    auto_close = "28800s"
  }
}

resource "google_monitoring_alert_policy" "web-downtime" {
  project = var.project_id

  display_name = "Portal service is DOWN!"
  combiner     = "OR"

  notification_channels = local.notification_channels

  conditions {
    display_name = "Uptime Health Check on web-https"

    condition_threshold {
      filter     = "resource.type = \"uptime_url\" AND metric.type = \"monitoring.googleapis.com/uptime_check/check_passed\" AND metric.labels.check_id = \"${reverse(split("/", google_monitoring_uptime_check_config.web-https.id))[0]}\""
      comparison = "COMPARISON_GT"

      threshold_value = 1
      duration        = "0s"

      trigger {
        count = 1
      }

      aggregations {
        alignment_period     = "60s"
        cross_series_reducer = "REDUCE_COUNT_FALSE"
        per_series_aligner   = "ALIGN_NEXT_OLDER"

        group_by_fields = [
          "resource.label.project_id",
          "resource.label.host"
        ]
      }
    }
  }

  alert_strategy {
    auto_close = "28800s"
  }
}

resource "google_monitoring_alert_policy" "instances_high_cpu_policy" {
  project = var.project_id

  display_name = "High Instance CPU utilization"
  combiner     = "OR"

  notification_channels = local.notification_channels

  conditions {
    display_name = "VM Instance - CPU utilization"

    condition_threshold {
      filter     = "resource.type = \"gce_instance\" AND metric.type = \"compute.googleapis.com/instance/cpu/utilization\" AND metadata.user_labels.managed_by = \"terraform\""
      comparison = "COMPARISON_GT"

      threshold_value = 0.8
      duration        = "60s"

      trigger {
        count = 1
      }

      aggregations {
        alignment_period     = "600s"
        cross_series_reducer = "REDUCE_NONE"
        per_series_aligner   = "ALIGN_MEAN"
      }
    }
  }

  alert_strategy {
    auto_close = "28800s"
  }
}

resource "google_monitoring_alert_policy" "sql_high_cpu_policy" {
  project = var.project_id

  display_name = "High Cloud SQL CPU utilization"
  combiner     = "OR"

  notification_channels = local.notification_channels

  conditions {
    display_name = "Cloud SQL Database - CPU utilization"

    condition_threshold {
      filter     = "resource.type = \"cloudsql_database\" AND metric.type = \"cloudsql.googleapis.com/database/cpu/utilization\""
      comparison = "COMPARISON_GT"

      threshold_value = 0.8
      duration        = "60s"

      trigger {
        count = 1
      }

      aggregations {
        alignment_period     = "60s"
        cross_series_reducer = "REDUCE_NONE"
        per_series_aligner   = "ALIGN_MEAN"
      }
    }
  }

  alert_strategy {
    auto_close = "28800s"
  }
}

resource "google_monitoring_alert_policy" "sql_disk_utiliziation_policy" {
  project = var.project_id

  display_name = "High Cloud SQL Disk utilization"
  combiner     = "OR"

  notification_channels = local.notification_channels

  conditions {
    display_name = "Cloud SQL Database - Disk utilization"

    condition_threshold {
      filter     = "resource.type = \"cloudsql_database\" AND metric.type = \"cloudsql.googleapis.com/database/disk/utilization\""
      comparison = "COMPARISON_GT"

      threshold_value = 0.8
      duration        = "300s"

      trigger {
        count = 1
      }

      aggregations {
        alignment_period     = "300s"
        cross_series_reducer = "REDUCE_NONE"
        per_series_aligner   = "ALIGN_MEAN"
      }
    }
  }

  alert_strategy {
    auto_close = "28800s"
  }
}

resource "google_monitoring_alert_policy" "errors" {
  project = var.project_id

  display_name = "Errors in logs"
  combiner     = "OR"

  notification_channels = local.notification_channels

  conditions {
    display_name = "Log match condition"

    condition_matched_log {
      filter = <<-EOT
      resource.type="gce_instance"
      (severity>=ERROR OR "Kernel pid terminated" OR "Crash dump is being written")
      -protoPayload.@type="type.googleapis.com/google.cloud.audit.AuditLog"
      -logName:"/logs/GCEGuestAgent"
      -logName:"/logs/OSConfigAgent"
      -logName:"/logs/ops-agent-fluent-bit"
      -"OpentelemetryFinch"
      EOT
    }
  }

  alert_strategy {
    auto_close = "28800s"

    notification_rate_limit {
      period = "3600s"
    }
  }
}

resource "google_monitoring_alert_policy" "production_db_access_policy" {
  project = var.project_id

  display_name = "DB Access"
  combiner     = "OR"

  notification_channels = [
    google_monitoring_notification_channel.slack.name
  ]

  documentation {
    content   = "Somebody just accessed the production database, this notification incident will be automatically discarded in 1 hour."
    mime_type = "text/markdown"
  }

  conditions {
    display_name = "Log match condition"

    condition_matched_log {
      filter = <<-EOT
      protoPayload.methodName="cloudsql.instances.connect"
      protoPayload.authenticationInfo.principalEmail!="terraform-cloud@terraform-iam-387817.iam.gserviceaccount.com"
      EOT

      label_extractors = {
        "Email" = "EXTRACT(protoPayload.authenticationInfo.principalEmail)"
      }
    }
  }

  alert_strategy {
    auto_close = "3600s"

    notification_rate_limit {
      period = "28800s"
    }
  }
}

resource "google_monitoring_alert_policy" "ssl_certs_expiring_policy" {
  project = var.project_id

  display_name = "SSL certificate expiring soon"
  combiner     = "OR"

  notification_channels = local.notification_channels

  user_labels = {
    version = "1"
    uptime  = "ssl_cert_expiration"
  }

  conditions {
    display_name = "SSL certificate expiring soon"

    condition_threshold {
      comparison = "COMPARISON_LT"
      filter     = "metric.type=\"monitoring.googleapis.com/uptime_check/time_until_ssl_cert_expires\" AND resource.type=\"uptime_url\""

      aggregations {
        alignment_period     = "1200s"
        cross_series_reducer = "REDUCE_MEAN"
        group_by_fields      = ["resource.label.*"]
        per_series_aligner   = "ALIGN_NEXT_OLDER"
      }

      duration        = "600s"
      threshold_value = 15

      trigger {
        count = 1
      }
    }
  }

  alert_strategy {
    auto_close = "28800s"
  }
}

resource "google_monitoring_alert_policy" "load_balancer_latency_policy" {
  project = var.project_id

  display_name          = "Load balancer latency"
  combiner              = "OR"
  notification_channels = local.notification_channels

  documentation {
    content   = "This alert is triggered when the load balancer latency is higher than 3000ms."
    mime_type = "text/markdown"
  }

  conditions {
    display_name = "Load balancer latency"

    condition_threshold {
      # Filter out HTTP 101 responses (switching protocols) to prevent WebSocket connections from triggering the alert
      filter          = "metric.labels.response_code != \"101\" AND resource.type = \"https_lb_rule\" AND metric.type = \"loadbalancing.googleapis.com/https/total_latencies\""
      comparison      = "COMPARISON_GT"
      threshold_value = 3000
      duration        = "0s"

      trigger {
        count = 1
      }

      aggregations {
        alignment_period   = "300s"
        per_series_aligner = "ALIGN_PERCENTILE_99"
      }
    }
  }
}
