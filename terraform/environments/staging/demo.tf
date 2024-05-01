# This module deploys an empty VM ready to run Docker commands to deploy our Relay or Gateway,
# it's used weekly for internal demos and testing, and reset after each use by rebooting the VM.

module "demo" {
  source = "../../modules/google-cloud/apps/vm"

  project_id = module.google-cloud-project.project.project_id

  compute_network    = module.google-cloud-vpc.id
  compute_subnetwork = google_compute_subnetwork.apps.self_link

  compute_region                     = local.region
  compute_instance_availability_zone = "${local.region}-d"

  compute_instance_type = "f1-micro"

  vm_name        = "demo"
  vm_network_tag = "app-demo"

  cloud_init = <<EOT
  #cloud-config
  runcmd:
  - sudo apt install postgresql-client jq iperf3 -y
  - curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
       | sudo gpg --dearmor -o /usr/share/keyrings/docker-archive-keyring.gpg
  - echo "deb [arch=amd64 signed-by=/usr/share/keyrings/docker-archive-keyring.gpg] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" \
       | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
  - sudo apt update -y
  - sudo apt install docker-ce docker-ce-cli containerd.io -y
  - sudo usermod -aG docker $(whoami)
  - sudo systemctl enable docker
  - sudo systemctl start docker
  - sudo docker run -d --restart always --name=httpbin -p 80:80 kennethreitz/httpbin
  - echo ${module.metabase.internal_ip} metabase.fz >> /etc/hosts
  - echo 127.0.0.1 host.firezone.local >> /etc/hosts
EOT
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
  target_tags   = module.demo.target_tags
}
