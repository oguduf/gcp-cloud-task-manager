resource "google_logging_metric" "app_errors" {
  depends_on  = [google_project_iam_member.tf_apply_observability]
  name        = "${var.name}-app-errors"
  description = "Structured application error records emitted by the Docker app."
  filter      = "resource.type=\"gce_instance\" AND severity=\"ERROR\""

  metric_descriptor {
    metric_kind = "DELTA"
    value_type  = "INT64"
    unit        = "1"
  }
}


resource "google_monitoring_uptime_check_config" "app" {
  depends_on   = [google_project_iam_member.tf_apply_observability]
  display_name = "${var.name} public health"
  timeout      = "10s"
  period       = "60s"

  monitored_resource {
    type = "uptime_url"
    labels = {
      project_id = var.project_id
      host       = var.domain_name == "" ? google_compute_global_address.lb.address : var.domain_name
    }
  }

  http_check {
    path         = "/healthz"
    port         = var.domain_name == "" ? 80 : 443
    use_ssl      = var.domain_name != ""
    validate_ssl = var.domain_name != ""
  }
}

locals {
  lb_resource_filter = "resource.type=\"https_lb_rule\" AND resource.label.url_map_name=\"${var.name}-routes\""
  cpu_filter         = "metric.type=\"compute.googleapis.com/instance/cpu/utilization\" AND resource.type=\"gce_instance\""
}

resource "google_monitoring_dashboard" "app" {
  depends_on = [google_project_iam_member.tf_apply_observability]
  dashboard_json = jsonencode({
    displayName = "${var.name} service dashboard"
    gridLayout = {
      columns = 2
      widgets = [
        {
          title = "Load balancer requests / second"
          xyChart = { dataSets = [{
            plotType = "LINE"
            timeSeriesQuery = { timeSeriesFilter = {
              filter      = "metric.type=\"loadbalancing.googleapis.com/https/request_count\" AND ${local.lb_resource_filter}"
              aggregation = { alignmentPeriod = "60s", perSeriesAligner = "ALIGN_RATE", crossSeriesReducer = "REDUCE_SUM" }
            } }
          }] }
        },
        {
          title = "HTTP 5xx responses / second"
          xyChart = { dataSets = [{
            plotType = "LINE"
            timeSeriesQuery = { timeSeriesFilter = {
              filter      = "metric.type=\"loadbalancing.googleapis.com/https/request_count\" AND ${local.lb_resource_filter} AND metric.label.response_code_class=\"500\""
              aggregation = { alignmentPeriod = "60s", perSeriesAligner = "ALIGN_RATE", crossSeriesReducer = "REDUCE_SUM" }
            } }
          }] }
        },
        {
          title = "Backend latency (p95)"
          xyChart = { dataSets = [{
            plotType = "LINE"
            timeSeriesQuery = { timeSeriesFilter = {
              filter      = "metric.type=\"loadbalancing.googleapis.com/https/backend_latencies\" AND ${local.lb_resource_filter}"
              aggregation = { alignmentPeriod = "60s", perSeriesAligner = "ALIGN_PERCENTILE_95", crossSeriesReducer = "REDUCE_MEAN" }
            } }
          }] }
        },
        {
          title = "Compute Engine CPU utilization"
          xyChart = { dataSets = [{
            plotType = "LINE"
            timeSeriesQuery = { timeSeriesFilter = {
              filter      = local.cpu_filter
              aggregation = { alignmentPeriod = "60s", perSeriesAligner = "ALIGN_MEAN", crossSeriesReducer = "REDUCE_MAX", groupByFields = ["resource.label.instance_name"] }
            } }
          }] }
        },
        {
          title = "Public endpoint uptime"
          xyChart = { dataSets = [{
            plotType = "LINE"
            timeSeriesQuery = { timeSeriesFilter = {
              filter      = "metric.type=\"monitoring.googleapis.com/uptime_check/check_passed\" AND resource.type=\"uptime_url\""
              aggregation = { alignmentPeriod = "60s", perSeriesAligner = "ALIGN_FRACTION_TRUE" }
            } }
          }] }
        },
        {
          title = "MIG autoscaler recommended instance count"
          xyChart = { dataSets = [{
            plotType = "LINE"
            timeSeriesQuery = { timeSeriesFilter = {
              filter      = "metric.type=\"autoscaler.googleapis.com/recommended_size\" AND resource.type=\"autoscaler\""
              aggregation = { alignmentPeriod = "60s", perSeriesAligner = "ALIGN_MAX" }
            } }
          }] }
        },
        {
          title = "Application error log count"
          xyChart = { dataSets = [{
            plotType = "LINE"
            timeSeriesQuery = { timeSeriesFilter = {
              filter      = "metric.type=\"logging.googleapis.com/user/${google_logging_metric.app_errors.name}\" AND resource.type=\"gce_instance\""
              aggregation = { alignmentPeriod = "60s", perSeriesAligner = "ALIGN_RATE", crossSeriesReducer = "REDUCE_SUM" }
            } }
          }] }
        }
      ]
    }
  })
}

resource "google_monitoring_alert_policy" "http_5xx" {
  depends_on            = [google_project_iam_member.tf_apply_observability]
  display_name          = "${var.name} high HTTP 5xx count"
  combiner              = "OR"
  notification_channels = var.alert_notification_channels
  conditions {
    display_name = "5xx responses exceed configured threshold"
    condition_threshold {
      filter          = "metric.type=\"loadbalancing.googleapis.com/https/request_count\" AND ${local.lb_resource_filter} AND metric.label.response_code_class=\"500\""
      comparison      = "COMPARISON_GT"
      threshold_value = var.alert_5xx_threshold
      duration        = "300s"
      aggregations {
        alignment_period     = "60s"
        per_series_aligner   = "ALIGN_SUM"
        cross_series_reducer = "REDUCE_SUM"
      }
      trigger { count = 1 }
    }
  }
}

resource "google_monitoring_alert_policy" "cpu" {
  depends_on            = [google_project_iam_member.tf_apply_observability]
  display_name          = "${var.name} high VM CPU"
  combiner              = "OR"
  notification_channels = var.alert_notification_channels
  conditions {
    display_name = "Average CPU utilization exceeds configured threshold"
    condition_threshold {
      filter          = local.cpu_filter
      comparison      = "COMPARISON_GT"
      threshold_value = var.alert_cpu_threshold
      duration        = "300s"
      aggregations {
        alignment_period     = "60s"
        per_series_aligner   = "ALIGN_MEAN"
        cross_series_reducer = "REDUCE_MAX"
      }
      trigger { count = 1 }
    }
  }
}

resource "google_monitoring_alert_policy" "backend_errors" {
  depends_on            = [google_project_iam_member.tf_apply_observability]
  display_name          = "${var.name} unhealthy load balancer backends"
  combiner              = "OR"
  notification_channels = var.alert_notification_channels
  conditions {
    display_name = "Backend error rate is nonzero"
    condition_threshold {
      filter          = "metric.type=\"network.googleapis.com/loadbalancer/backend/error_rate\" AND resource.type=\"load_balancer_backend\""
      comparison      = "COMPARISON_GT"
      threshold_value = var.alert_backend_error_rate
      duration        = "300s"
      aggregations {
        alignment_period   = "60s"
        per_series_aligner = "ALIGN_MEAN"
      }
      trigger { count = 1 }
    }
  }
}

resource "google_monitoring_alert_policy" "uptime" {
  depends_on            = [google_project_iam_member.tf_apply_observability]
  display_name          = "${var.name} public endpoint unavailable"
  combiner              = "OR"
  notification_channels = var.alert_notification_channels
  conditions {
    display_name = "Uptime check fails"
    condition_threshold {
      filter          = "metric.type=\"monitoring.googleapis.com/uptime_check/check_passed\" AND resource.type=\"uptime_url\" AND metric.label.check_id=\"${google_monitoring_uptime_check_config.app.uptime_check_id}\""
      comparison      = "COMPARISON_LT"
      threshold_value = 1
      duration        = "120s"
      aggregations {
        alignment_period   = "60s"
        per_series_aligner = "ALIGN_NEXT_OLDER"
      }
      trigger { count = 1 }
    }
  }
}

resource "google_monitoring_alert_policy" "app_errors" {
  depends_on            = [google_project_iam_member.tf_apply_observability]
  display_name          = "${var.name} application errors"
  combiner              = "OR"
  notification_channels = var.alert_notification_channels
  conditions {
    display_name = "Application emits error logs"
    condition_threshold {
      filter          = "metric.type=\"logging.googleapis.com/user/${google_logging_metric.app_errors.name}\" AND resource.type=\"gce_instance\""
      comparison      = "COMPARISON_GT"
      threshold_value = 0
      duration        = "300s"
      aggregations {
        alignment_period   = "60s"
        per_series_aligner = "ALIGN_RATE"
      }
      trigger { count = 1 }
    }
  }
}

