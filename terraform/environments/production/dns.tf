# Allow Google Cloud to issue certificates for our domain
resource "google_dns_record_set" "default-dns-caa" {
  project      = module.google-cloud-project.project.project_id
  managed_zone = module.google-cloud-dns.zone_name

  type = "CAA"
  name = module.google-cloud-dns.dns_name
  rrdatas = [
    "0 issue \"pki.goog;validationmethods=dns-01\"",
    "0 iodef \"mailto:security@firezone.dev\""
  ]
  ttl = 3600
}

resource "google_dns_record_set" "www-dns-caa" {
  project      = module.google-cloud-project.project.project_id
  managed_zone = module.google-cloud-dns.zone_name

  type = "CAA"
  name = "www.${module.google-cloud-dns.dns_name}"
  rrdatas = [
    "0 issue \"letsencrypt.org\"",
    "0 iodef \"mailto:security@firezone.dev\""
  ]
  ttl = 3600
}

resource "google_dns_record_set" "blog-dns-caa" {
  project      = module.google-cloud-project.project.project_id
  managed_zone = module.google-cloud-dns.zone_name

  type = "CAA"
  name = "blog.${module.google-cloud-dns.dns_name}"
  rrdatas = [
    "0 issue \"letsencrypt.org\"",
    "0 iodef \"mailto:security@firezone.dev\""
  ]
  ttl = 3600
}

resource "google_dns_record_set" "docs-dns-caa" {
  project      = module.google-cloud-project.project.project_id
  managed_zone = module.google-cloud-dns.zone_name

  type = "CAA"
  name = "docs.${module.google-cloud-dns.dns_name}"
  rrdatas = [
    "0 issue \"letsencrypt.org\"",
    "0 iodef \"mailto:security@firezone.dev\""
  ]
  ttl = 3600
}


# Website

resource "google_dns_record_set" "website-ipv4" {
  project      = module.google-cloud-project.project.project_id
  managed_zone = module.google-cloud-dns.zone_name

  type    = "A"
  name    = module.google-cloud-dns.dns_name
  rrdatas = ["76.76.21.21"]
  ttl     = 3600
}

resource "google_dns_record_set" "website-www-redirect" {
  project      = module.google-cloud-project.project.project_id
  managed_zone = module.google-cloud-dns.zone_name

  type    = "CNAME"
  name    = "www.${module.google-cloud-dns.dns_name}"
  rrdatas = ["cname.vercel-dns.com."]
  ttl     = 3600
}

resource "google_dns_record_set" "blog-ipv4" {
  project      = module.google-cloud-project.project.project_id
  managed_zone = module.google-cloud-dns.zone_name

  type    = "A"
  name    = "blog.${module.google-cloud-dns.dns_name}"
  rrdatas = ["45.63.84.183"]
  ttl     = 3600
}
resource "google_dns_record_set" "blog-ipv6" {
  project      = module.google-cloud-project.project.project_id
  managed_zone = module.google-cloud-dns.zone_name

  type    = "AAAA"
  name    = "blog.${module.google-cloud-dns.dns_name}"
  rrdatas = ["2001:19f0:ac02:bb:5400:4ff:fe47:6bdf"]
  ttl     = 3600
}

resource "google_dns_record_set" "docs-ipv4" {
  project      = module.google-cloud-project.project.project_id
  managed_zone = module.google-cloud-dns.zone_name

  type    = "A"
  name    = "docs.${module.google-cloud-dns.dns_name}"
  rrdatas = ["45.63.84.183"]
  ttl     = 3600
}

resource "google_dns_record_set" "docs-ipv6" {
  project      = module.google-cloud-project.project.project_id
  managed_zone = module.google-cloud-dns.zone_name

  type    = "AAAA"
  name    = "docs.${module.google-cloud-dns.dns_name}"
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
    "\"k=rsa;\" \"p=MIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8AMIIBCgKCAQEAwhTddUFz+LHTx63SpYvoAc4UzPgXy71Lq950bgVgrwHqLiktRnXFliKGbwL/QPyzOOWBYd1B3brC81B0IoBZkNxFj1mA1EKd8oFi8GMaKA5YuPbrkTT9AGXx0VpMMqDUcYoGWplXnMSY2ICdSRxOdQ5sXLdLqEyIVWm8WiF2+U7Zq15PSNr1VigByCknc7N0Pes0qbVTuWVNd\" \"BBYFO5igHpRaHZtYU/dT5ebXxcvZJgQinW23erS6fFgNuUOOwhGJCay5ahpAnufuQB52eEkM/AHb9cXxVG5g04+6xZSMT7/aI7m1IOzulOds71RAn7FN4LJhdI0DgOmIUVj4G32OwIDAQAB\""
  ]
}

# GitHub

resource "google_dns_record_set" "github-verification" {
  project      = module.google-cloud-project.project.project_id
  managed_zone = module.google-cloud-dns.zone_name

  name = "_github-challenge-firezone-organization.${module.google-cloud-dns.dns_name}"
  type = "TXT"
  ttl  = 3600

  rrdatas = [
    "ca4903847a"
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
    "\"v=DMARC1;\" \"p=reject;\" \"rua=mailto:dmarc-reports@firezone.dev;\" \"pct=100;\" \"adkim=r;\" \"aspf=r\""
  ]
}

resource "google_dns_record_set" "root-verifications" {
  project      = module.google-cloud-project.project.project_id
  managed_zone = module.google-cloud-dns.zone_name

  name = module.google-cloud-dns.dns_name
  type = "TXT"
  ttl  = 3600

  rrdatas = [
    "\"v=spf1 mx include:23723443.spf07.hubspotemail.net include:sendgrid.net include:_spf.google.com include:mailgun.org ~all\"",
    # TODO: only keep the last one needed
    "google-site-verification=hbBLPfTlejIaxyFTPZN0RaIk6Y6qhQTG2yma7I06Emo",
    "google-site-verification=oAugt2Arr7OyWaqJ0bkytkmIE-VQ8D_IFa-rdNiqa8s",
    "google-site-verification=VDl82gbqVHJW6un8Mcki6qDhL_OGK6G8ByOB6qhaVbg",
    "oneleet-domain-verification-72120df0-57da-4da7-b7bf-e26eaee9dd85"
  ]
}

resource "google_dns_record_set" "google-dkim" {
  project      = module.google-cloud-project.project.project_id
  managed_zone = module.google-cloud-dns.zone_name

  name = "google._domainkey.${module.google-cloud-dns.dns_name}"
  type = "TXT"
  ttl  = 3600

  rrdatas = [
    "\"v=DKIM1;\" \"k=rsa;\" \"p=MIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8AMIIBCgKCAQEAi1bjDNWHAhpLro2nw6WJ4Ye+JyA0gsMLHx1g+oS\" \"uGC6V0zo0Ftdt/tgvieaWbArClrz7Ce8986mih1P6iEESehTSarDrLlHPstIEI6UnjP7sAuIZtRsIrUI4NJM0Jg96uS4ezxIza3bzNxk3atMp0laCt+\" \"tbCeGLCPt4r9aygWIT/CRuNHZUm3CVwemN0celflXZF+FEg+mEJrkekasNtVJJ//XAdimvwe9CWOF/VoC+ZP0ocac3CFzng7NzSqYnCiaAZqJ3Pss0ueq0K/kqUxy8vh25Kd\" \"gyvdHSWdgnMFD251I/TBueScPZoUmo3ueYqwKxmW1J1uCkVx4NQ1xK2QIDAQAB\""
  ]
}

# Oneleet Trust page

resource "google_dns_record_set" "oneleet-trust" {
  project      = module.google-cloud-project.project.project_id
  managed_zone = module.google-cloud-dns.zone_name

  name = "trust.${module.google-cloud-dns.dns_name}"
  type = "CNAME"
  ttl  = 3600

  rrdatas = [
    "trust.oneleet.com."
  ]
}

# Stripe checkout pages

resource "google_dns_record_set" "stripe-checkout" {
  project      = module.google-cloud-project.project.project_id
  managed_zone = module.google-cloud-dns.zone_name

  type    = "CNAME"
  name    = "billing.${module.google-cloud-dns.dns_name}"
  rrdatas = ["hosted-checkout.stripecdn.com."]
  ttl     = 300
}

resource "google_dns_record_set" "stripe-checkout-acme" {
  project      = module.google-cloud-project.project.project_id
  managed_zone = module.google-cloud-dns.zone_name

  type    = "TXT"
  name    = "_acme-challenge.billing.${module.google-cloud-dns.dns_name}"
  rrdatas = ["YXH57351vMR9L5prjMoetmpktg1K65i6HkK0ZlLlF1g"]
  ttl     = 300
}

# HubSpot

resource "google_dns_record_set" "hubspot-domainkey1" {
  project      = module.google-cloud-project.project.project_id
  managed_zone = module.google-cloud-dns.zone_name

  type    = "CNAME"
  name    = "hs1-23723443._domainkey.${module.google-cloud-dns.dns_name}"
  rrdatas = ["firezone-dev.hs07a.dkim.hubspotemail.net."]
  ttl     = 3600
}

resource "google_dns_record_set" "hubspot-domainkey2" {
  project      = module.google-cloud-project.project.project_id
  managed_zone = module.google-cloud-dns.zone_name

  type    = "CNAME"
  name    = "hs2-23723443._domainkey.${module.google-cloud-dns.dns_name}"
  rrdatas = ["firezone-dev.hs07b.dkim.hubspotemail.net."]
  ttl     = 3600
}
