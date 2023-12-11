# This module deploys an empty VM ready to run Docker commands to deploy our Relay or Gateway,
# it's used weekly for internal demos and testing, and reset after each use by rebooting the VM.

data "google_compute_image" "demo" {
  family  = "ubuntu-2204-lts"
  project = "ubuntu-os-cloud"
}

resource "google_service_account" "demo" {
  project = module.google-cloud-project.project.project_id

  account_id   = "demo-instance"
  display_name = "Custom Service Account for a Demo VM Instance"
}

resource "google_compute_instance" "demo" {
  project = module.google-cloud-project.project.project_id

  name         = "demo"
  machine_type = "n1-standard-1"
  zone         = "${local.region}-d"

  tags = ["demo"]

  boot_disk {
    auto_delete = true

    initialize_params {
      image = data.google_compute_image.demo.self_link

      labels = {
        managed_by = "terraform"
      }
    }
  }

  network_interface {
    subnetwork = google_compute_subnetwork.apps.self_link

    access_config {
      // Ephemeral public IP
    }
  }

  metadata = {
    google-logging-enabled       = "true"
    google-logging-use-fluentbit = "true"

    # Report health-related metrics to Cloud Monitoring
    google-monitoring-enabled = "true"
  }

  # We can install any tools we need for the demo in the startup script
  # TODO: enable IPv6 for the demo VM
  metadata_startup_script = <<EOT
  set -xe \
    && sudo apt update -y \
    && sudo apt install postgresql-client jq iperf3 -y \
    && sudo apt install apt-transport-https ca-certificates curl software-properties-common -y \
    && curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
       | sudo gpg --dearmor -o /usr/share/keyrings/docker-archive-keyring.gpg \
    && echo "deb [arch=amd64 signed-by=/usr/share/keyrings/docker-archive-keyring.gpg] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" \
       | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null \
    && sudo apt update -y \
    && sudo apt install docker-ce docker-ce-cli containerd.io -y \
    && sudo usermod -aG docker $(whoami) \
    && sudo systemctl enable docker \
    && sudo systemctl start docker \
    && sudo docker run -d --restart always --name=httpbin -p 80:80 kennethreitz/httpbin \
    && echo ${module.metabase.internal_ip} metabase.fz >> /etc/hosts \
    && echo 127.0.0.1 host.firezone.local >> /etc/hosts
EOT

  allow_stopping_for_update = true

  service_account {
    # Google recommends custom service accounts that have cloud-platform scope and permissions granted via IAM Roles.
    email  = google_service_account.demo.email
    scopes = ["cloud-platform"]
  }
}

# Grant demo users access to demo instance
resource "google_compute_instance_iam_binding" "demo-os-login" {
  project       = module.google-cloud-project.project.project_id
  zone          = google_compute_instance.demo.zone
  instance_name = google_compute_instance.demo.name

  role    = "roles/compute.osAdminLogin"
  members = formatlist("user:%s", local.demo_access)
}

resource "google_compute_instance_iam_binding" "demo-instance-admin" {
  project       = module.google-cloud-project.project.project_id
  zone          = google_compute_instance.demo.zone
  instance_name = google_compute_instance.demo.name

  role    = "roles/compute.instanceAdmin.v1"
  members = formatlist("user:%s", local.demo_access)
}

resource "google_project_iam_binding" "demo-proejct-sa" {
  project = module.google-cloud-project.project.project_id

  role    = "roles/iam.serviceAccountUser"
  members = formatlist("user:%s", local.demo_access)
}

# Create a demo DB and PostgreSQL user so that we can demo accessing the database
resource "random_password" "demo_db_password" {
  length = 16

  min_lower   = 1
  min_upper   = 1
  min_numeric = 1
  min_special = 1
}

resource "google_sql_user" "demo" {
  project = module.google-cloud-project.project.project_id

  instance = module.google-cloud-sql.master_instance_name

  name     = "demo"
  password = random_password.demo_db_password.result
}

resource "google_sql_database" "demo" {
  project = module.google-cloud-project.project.project_id

  name     = "demo"
  instance = module.google-cloud-sql.master_instance_name
}

resource "google_compute_firewall" "demo-access-to-bi" {
  project = module.google-cloud-project.project.project_id

  name    = "demo-access-to-bi"
  network = module.google-cloud-vpc.self_link

  allow {
    protocol = "tcp"
  }

  allow {
    protocol = "udp"
  }

  allow {
    protocol = "icmp"
  }

  source_ranges = [google_compute_subnetwork.apps.ip_cidr_range]
  target_tags   = module.metabase.target_tags
}


resource "google_compute_firewall" "demo-ssh-ipv4" {
  project = module.google-cloud-project.project.project_id

  name    = "staging-demo-ssh-ipv4"
  network = module.google-cloud-vpc.id

  allow {
    protocol = "tcp"
    ports    = [22]
  }

  allow {
    protocol = "udp"
    ports    = [22]
  }

  allow {
    protocol = "sctp"
    ports    = [22]
  }

  source_ranges = ["0.0.0.0/0"]
  target_tags   = google_compute_instance.demo.tags
}
