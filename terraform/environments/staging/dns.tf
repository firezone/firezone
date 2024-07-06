# Allow Google Cloud and Let's Encrypt to issue certificates for our domain
resource "google_dns_record_set" "dns-caa" {
  project      = module.google-cloud-project.project.project_id
  managed_zone = module.google-cloud-dns.zone_name

  type = "CAA"
  name = module.google-cloud-dns.dns_name
  rrdatas = [
    "0 issue \"letsencrypt.org\"",
    "0 issue \"pki.goog\"",
    "0 iodef \"mailto:security@firezone.dev\""
  ]
  ttl = 3600
}

# Website -- these redirect to firezone.dev

resource "google_dns_record_set" "website-ipv4" {
  project      = module.google-cloud-project.project.project_id
  managed_zone = module.google-cloud-dns.zone_name

  type    = "A"
  name    = module.google-cloud-dns.dns_name
  rrdatas = [google_compute_global_address.tld-ipv4.address]
  ttl     = 3600
}

resource "google_dns_record_set" "website-www-redirect" {
  project      = module.google-cloud-project.project.project_id
  managed_zone = module.google-cloud-dns.zone_name

  type    = "A"
  name    = "www.${module.google-cloud-dns.dns_name}"
  rrdatas = [google_compute_global_address.tld-ipv4.address]
  ttl     = 3600
}

# Our community forum, discourse

resource "google_dns_record_set" "discourse" {
  project      = module.google-cloud-project.project.project_id
  managed_zone = module.google-cloud-dns.zone_name

  type    = "A"
  name    = "discourse.${module.google-cloud-dns.dns_name}"
  rrdatas = ["45.77.86.150"]
  ttl     = 300
}

# Connectivity check servers

resource "google_dns_record_set" "ping-backend" {
  project      = module.google-cloud-project.project.project_id
  managed_zone = module.google-cloud-dns.zone_name

  type    = "A"
  name    = "ping-backend.${module.google-cloud-dns.dns_name}"
  rrdatas = ["149.28.197.67"]
  ttl     = 3600
}

resource "google_dns_record_set" "ping-ipv4" {
  project      = module.google-cloud-project.project.project_id
  managed_zone = module.google-cloud-dns.zone_name

  type    = "A"
  name    = "ping.${module.google-cloud-dns.dns_name}"
  rrdatas = ["45.63.84.183"]
  ttl     = 3600
}


resource "google_dns_record_set" "ping-ipv6" {
  project      = module.google-cloud-project.project.project_id
  managed_zone = module.google-cloud-dns.zone_name

  type    = "AAAA"
  name    = "ping.${module.google-cloud-dns.dns_name}"
  rrdatas = ["2001:19f0:ac02:bb:5400:4ff:fe47:6bdf"]
  ttl     = 3600
}

# Telemetry servers

resource "google_dns_record_set" "t-ipv4" {
  project      = module.google-cloud-project.project.project_id
  managed_zone = module.google-cloud-dns.zone_name

  type    = "A"
  name    = "t.${module.google-cloud-dns.dns_name}"
  rrdatas = ["45.63.84.183"]
  ttl     = 3600
}

resource "google_dns_record_set" "t-ipv6" {
  project      = module.google-cloud-project.project.project_id
  managed_zone = module.google-cloud-dns.zone_name

  type    = "AAAA"
  name    = "t.${module.google-cloud-dns.dns_name}"
  rrdatas = ["2001:19f0:ac02:bb:5400:4ff:fe47:6bdf"]
  ttl     = 3600
}

resource "google_dns_record_set" "telemetry-ipv4" {
  project      = module.google-cloud-project.project.project_id
  managed_zone = module.google-cloud-dns.zone_name

  type    = "A"
  name    = "telemetry.${module.google-cloud-dns.dns_name}"
  rrdatas = ["45.63.84.183"]
  ttl     = 3600
}

resource "google_dns_record_set" "telemetry-ipv6" {
  project      = module.google-cloud-project.project.project_id
  managed_zone = module.google-cloud-dns.zone_name

  type    = "AAAA"
  name    = "telemetry.${module.google-cloud-dns.dns_name}"
  rrdatas = ["2001:19f0:ac02:bb:5400:4ff:fe47:6bdf"]
  ttl     = 3600
}

# Third-party services

# Mailgun

resource "google_dns_record_set" "mailgun-dkim" {
  project      = module.google-cloud-project.project.project_id
  managed_zone = module.google-cloud-dns.zone_name

  name = "kone._domainkey.${module.google-cloud-dns.dns_name}"
  type = "TXT"
  ttl  = 3600

  # Reference: https://groups.google.com/g/cloud-dns-discuss/c/k_l6JP-H29Y
  # Individual strings cannot exceed 255 characters in length, or "Invalid record data" results
  # DKIM clients concatenate all of the strings in the client before parsing tags, so to workaround the limit
  # all you need to do is add whitespace within the p= tag such that each string fits within the 255 character limit.
  rrdatas = [
    "\"k=rsa;\" \"p=MIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8AMIIBCgKCAQEAwYyTkBcuzLi1l+bHezuxJlmmpSdabjHY67YxWG8chz7pd12IfbE7JDM4Qi+AYq6Wp6ZDqEukFHIMJjz2PceHuf/5sgJazWLwBWp6DN6J2/WXgs2vWBWYJ0Kpj6l+p2t8jNrPNNVZrkO7BT2AmJAV5c9bemXkY801XkATAvAzvHs7pMsvjVmALWhh9eQoflVjYZUBwSDWjItd\" \"flK4IlrU5+yM5xHRIshazUmWiM8b6lBzV7WKLrDir+Td8NdBAwkFnlxIuqePlfXqIA3190Mk03PqOjlqhuqjZVg441e4A2TwlSShOv9EWtwseKwO1uWiky5uKGo4mlNPU4aZAi/UFwIDAQAB\""
  ]
}

# Google Workspace

resource "google_dns_record_set" "google-mail" {
  project      = module.google-cloud-project.project.project_id
  managed_zone = module.google-cloud-dns.zone_name

  name = module.google-cloud-dns.dns_name
  type = "MX"
  ttl  = 3600

  rrdatas = [
    "1 aspmx.l.google.com.",
    "5 alt1.aspmx.l.google.com.",
    "5 alt2.aspmx.l.google.com.",
    "10 alt3.aspmx.l.google.com.",
    "10 alt4.aspmx.l.google.com."
  ]
}

resource "google_dns_record_set" "google-dmarc" {
  project      = module.google-cloud-project.project.project_id
  managed_zone = module.google-cloud-dns.zone_name


  name = "_dmarc.${module.google-cloud-dns.dns_name}"
  type = "TXT"
  ttl  = 3600

  rrdatas = [
    "\"v=DMARC1;\" \"p=reject;\" \"rua=mailto:dmarc-reports@firezone.dev;\" \"pct=100;\" \"adkim=s;\" \"aspf=s\""
  ]
}

resource "google_dns_record_set" "google-spf" {
  project      = module.google-cloud-project.project.project_id
  managed_zone = module.google-cloud-dns.zone_name

  name = "try.${module.google-cloud-dns.dns_name}"
  type = "TXT"
  ttl  = 3600

  rrdatas = [
    "\"v=spf1 include:_spf.google.com ~all\""
  ]
}

resource "google_dns_record_set" "google-dkim" {
  project      = module.google-cloud-project.project.project_id
  managed_zone = module.google-cloud-dns.zone_name

  name = "20190728104345pm._domainkey.${module.google-cloud-dns.dns_name}"
  type = "TXT"
  ttl  = 3600

  rrdatas = [
    "\"v=DKIM1;\" \"k=rsa;\" \"p=MIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8AMIIBCgKCAQEAlrJHV7oQ63ebQcZ7fsvo+kjb1R9UrkpcdAOkOeN74qMjypQA+hKVV9F2aDM8hFeZoQH9zwIgQi+\" \"0TcDKRr1O7BklmbSkoMaqM5gH2OQTqQWwU0v49POHiL6yWKO4L68peJMMEVX+xFcjxHI5j6dkLMmv+Y6IxrzsqgeXx7V6cFt5V1G8lr0DWC+yzhPioda+S21dWl1GwPdLBbQb80GV1mpV2rGImzeiZVv4/4Et7w0M55Rfy\" \"m4JICJ89FmjC1Ua05CvrD4dvugWqfVoGuP3nyQXEqP8wgyoPuOZPrcEQXu+IlBrWMRBKv7slI571YnUznwoKlkourgB+7qC/zU8KQIDAQAB\""
  ]
}

resource "google_dns_record_set" "root-verifications" {
  project      = module.google-cloud-project.project.project_id
  managed_zone = module.google-cloud-dns.zone_name

  name = module.google-cloud-dns.dns_name
  type = "TXT"
  ttl  = 3600

  rrdatas = [
    "google-site-verification=NbGHbeX7TprsiSQfxz2JVtP7xrPJE5Orej2_Ip8JHyo",
    "\"v=spf1 include:mailgun.org ~all\"",
    "oneleet-domain-verification-b98be3d1-70c2-4cdb-b444-8dac1ee7b8d4"
  ]
}
