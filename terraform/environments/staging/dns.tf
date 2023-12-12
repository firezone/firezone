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

# Website

resource "google_dns_record_set" "website-ipv6" {
  project      = module.google-cloud-project.project.project_id
  managed_zone = module.google-cloud-dns.zone_name

  type    = "AAAA"
  name    = module.google-cloud-dns.dns_name
  rrdatas = ["2001:19f0:ac02:bb:5400:4ff:fe47:6bdf"]
  ttl     = 3600
}

resource "google_dns_record_set" "website-ipv4" {
  project      = module.google-cloud-project.project.project_id
  managed_zone = module.google-cloud-dns.zone_name

  type    = "A"
  name    = module.google-cloud-dns.dns_name
  rrdatas = ["45.63.84.183"]
  ttl     = 3600
}

resource "google_dns_record_set" "website-www-redirect" {
  project      = module.google-cloud-project.project.project_id
  managed_zone = module.google-cloud-dns.zone_name

  type    = "CNAME"
  name    = "www.${module.google-cloud-dns.dns_name}"
  rrdatas = ["firez.one."]
  ttl     = 3600
}

# Our team's Firezone instance(s)

resource "google_dns_record_set" "dogfood" {
  project      = module.google-cloud-project.project.project_id
  managed_zone = module.google-cloud-dns.zone_name

  type    = "A"
  name    = "dogfood.${module.google-cloud-dns.dns_name}"
  rrdatas = ["45.63.56.50"]
  ttl     = 3600
}

resource "google_dns_record_set" "awsfz1" {
  project      = module.google-cloud-project.project.project_id
  managed_zone = module.google-cloud-dns.zone_name

  type    = "CNAME"
  name    = "awsfz1.${module.google-cloud-dns.dns_name}"
  rrdatas = ["ec2-52-200-241-107.compute-1.amazonaws.com."]
  ttl     = 3600
}

# Our MAIN discourse instance, do not change this!

resource "google_dns_record_set" "discourse" {
  project      = module.google-cloud-project.project.project_id
  managed_zone = module.google-cloud-dns.zone_name

  type    = "A"
  name    = "discourse.${module.google-cloud-dns.dns_name}"
  rrdatas = ["45.77.86.150"]
  ttl     = 300
}

# VPN-protected DNS records

resource "google_dns_record_set" "metabase" {
  project      = module.google-cloud-project.project.project_id
  managed_zone = module.google-cloud-dns.zone_name

  type    = "A"
  name    = "metabase.${module.google-cloud-dns.dns_name}"
  rrdatas = ["10.5.96.5"]
  ttl     = 3600
}

# Wireguard test servers

resource "google_dns_record_set" "wg0" {
  project      = module.google-cloud-project.project.project_id
  managed_zone = module.google-cloud-dns.zone_name

  type    = "A"
  name    = "wg0.${module.google-cloud-dns.dns_name}"
  rrdatas = ["54.151.104.17"]
  ttl     = 3600
}

resource "google_dns_record_set" "wg1" {
  project      = module.google-cloud-project.project.project_id
  managed_zone = module.google-cloud-dns.zone_name

  type    = "A"
  name    = "wg1.${module.google-cloud-dns.dns_name}"
  rrdatas = ["54.183.57.227"]
  ttl     = 3600
}

resource "google_dns_record_set" "wg2" {
  project      = module.google-cloud-project.project.project_id
  managed_zone = module.google-cloud-dns.zone_name

  type    = "A"
  name    = "wg2.${module.google-cloud-dns.dns_name}"
  rrdatas = ["54.177.212.45"]
  ttl     = 3600
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

resource "google_dns_record_set" "old-ipv4" {
  project      = module.google-cloud-project.project.project_id
  managed_zone = module.google-cloud-dns.zone_name

  type    = "A"
  name    = "old-telemetry.${module.google-cloud-dns.dns_name}"
  rrdatas = ["143.244.211.244"]
  ttl     = 3600
}

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

## Sendgrid
resource "google_dns_record_set" "sendgrid-project" {
  project      = module.google-cloud-project.project.project_id
  managed_zone = module.google-cloud-dns.zone_name

  type    = "CNAME"
  name    = "23539796.${module.google-cloud-dns.dns_name}"
  rrdatas = ["sendgrid.net."]
  ttl     = 3600
}

resource "google_dns_record_set" "sendgrid-return-1" {
  project      = module.google-cloud-project.project.project_id
  managed_zone = module.google-cloud-dns.zone_name

  type    = "CNAME"
  name    = "em3706.${module.google-cloud-dns.dns_name}"
  rrdatas = ["u23539796.wl047.sendgrid.net."]
  ttl     = 3600
}

resource "google_dns_record_set" "sendgrid-return-2" {
  project      = module.google-cloud-project.project.project_id
  managed_zone = module.google-cloud-dns.zone_name

  type    = "CNAME"
  name    = "url6320.${module.google-cloud-dns.dns_name}"
  rrdatas = ["sendgrid.net."]
  ttl     = 3600
}

resource "google_dns_record_set" "sendgrid-domainkey1" {
  project      = module.google-cloud-project.project.project_id
  managed_zone = module.google-cloud-dns.zone_name

  type    = "CNAME"
  name    = "s1._domainkey.${module.google-cloud-dns.dns_name}"
  rrdatas = ["s1.domainkey.u23539796.wl047.sendgrid.net."]
  ttl     = 3600
}

resource "google_dns_record_set" "sendgrid-domainkey2" {
  project      = module.google-cloud-project.project.project_id
  managed_zone = module.google-cloud-dns.zone_name

  type    = "CNAME"
  name    = "s2._domainkey.${module.google-cloud-dns.dns_name}"
  rrdatas = ["s2.domainkey.u23539796.wl047.sendgrid.net."]
  ttl     = 3600
}

# Postmark

resource "google_dns_record_set" "postmark-dkim" {
  project      = module.google-cloud-project.project.project_id
  managed_zone = module.google-cloud-dns.zone_name

  name = "20230606183724pm._domainkey.${module.google-cloud-dns.dns_name}"
  type = "TXT"
  ttl  = 3600

  rrdatas = [
    "k=rsa;p=MIGfMA0GCSqGSIb3DQEBAQUAA4GNADCBiQKBgQCGB97X54FpoXNFuuPpI2u18ymEHBvNGfaRVXn9KEKAnSIfayJ6V3m5C5WGmfv579gyvfdDm04NAVBMcxe6mkjZHsZwds7mPjOYmRlsCClcy6ITqHwPdGSqP0f4zes1AT3Sr1GCQkl/2CdjWzc7HLoyViPxcH17yJN8HlfCYg5waQIDAQAB"
  ]
}

resource "google_dns_record_set" "postmark-return" {
  project      = module.google-cloud-project.project.project_id
  managed_zone = module.google-cloud-dns.zone_name

  type    = "CNAME"
  name    = "pm-bounces.${module.google-cloud-dns.dns_name}"
  rrdatas = ["pm.mtasv.net."]
  ttl     = 3600
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
