
resource "google_monitoring_uptime_check_config" "website-https" {
  project = module.google-cloud-project.project.project_id

  display_name = "website-https"
  timeout      = "60s"

  http_check {
    port         = "443"
    use_ssl      = true
    validate_ssl = true

    request_method = "GET"
    path           = "/"

    accepted_response_status_codes {
      status_class = "STATUS_CLASS_2XX"
    }
  }

  monitored_resource {
    type = "uptime_url"

    labels = {
      project_id = module.google-cloud-project.project.project_id
      host       = local.tld
    }
  }

  content_matchers {
    matcher = "CONTAINS_STRING"
    content = "firezone"
  }

  checker_type = "STATIC_IP_CHECKERS"
}

resource "google_monitoring_alert_policy" "website-downtime" {
  project = module.google-cloud-project.project.project_id

  display_name = "Website is DOWN!"
  combiner     = "OR"

  notification_channels = module.ops.notification_channels

  conditions {
    display_name = "Uptime Health Check on website-https"

    condition_threshold {
      filter = "resource.type = \"uptime_url\" AND metric.type = \"monitoring.googleapis.com/uptime_check/check_passed\" AND metric.labels.check_id = \"${reverse(split("/", google_monitoring_uptime_check_config.website-https.id))[0]}\""

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
