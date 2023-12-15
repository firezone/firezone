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

# Vercel doesn't support IPv6
# resource "google_dns_record_set" "website-ipv6" {
#   project      = module.google-cloud-project.project.project_id
#   managed_zone = module.google-cloud-dns.zone_name

#   type    = "AAAA"
#   name    = module.google-cloud-dns.dns_name
#   rrdatas = ["2001:19f0:ac02:bb:5400:4ff:fe47:6bdf"]
#   ttl     = 3600
# }

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

resource "google_dns_record_set" "status-page" {
  project      = module.google-cloud-project.project.project_id
  managed_zone = module.google-cloud-dns.zone_name

  type    = "CNAME"
  name    = "status.${module.google-cloud-dns.dns_name}"
  rrdatas = ["bs4nszn1hdh6.stspg-customer.com."]
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

## TODO: get rid off this one
resource "google_dns_record_set" "awsdemo-ipv4" {
  project      = module.google-cloud-project.project.project_id
  managed_zone = module.google-cloud-dns.zone_name

  type    = "A"
  name    = "awsdemo.${module.google-cloud-dns.dns_name}"
  rrdatas = ["52.200.241.107"]
  ttl     = 3600
}

resource "google_dns_record_set" "awsdemo-acme-verification" {
  project      = module.google-cloud-project.project.project_id
  managed_zone = module.google-cloud-dns.zone_name

  type    = "TXT"
  name    = "_acme-challenge.awsdemo.${module.google-cloud-dns.dns_name}"
  rrdatas = ["sX54Me2woKpf_iLC4R9Il_8U8OuMTtGqRXOo5fveCNU"]
  ttl     = 3600
}

## TODO: get rid off this one
resource "google_dns_record_set" "docker-dev-ipv4" {
  project      = module.google-cloud-project.project.project_id
  managed_zone = module.google-cloud-dns.zone_name

  type    = "A"
  name    = "docker-dev.${module.google-cloud-dns.dns_name}"
  rrdatas = ["3.101.147.119"]
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
  name    = "em8227.${module.google-cloud-dns.dns_name}"
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

resource "google_dns_record_set" "sendgrid-reverse-dns" {
  project      = module.google-cloud-project.project.project_id
  managed_zone = module.google-cloud-dns.zone_name

  type    = "A"
  name    = "o1.ptr3213.${module.google-cloud-dns.dns_name}"
  rrdatas = ["159.183.164.144"]
  ttl     = 3600
}

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

# Postmark

resource "google_dns_record_set" "postmark-dkim" {
  project      = module.google-cloud-project.project.project_id
  managed_zone = module.google-cloud-dns.zone_name

  name = "20231019190050pm._domainkey.${module.google-cloud-dns.dns_name}"
  type = "TXT"
  ttl  = 3600

  rrdatas = [
    "k=rsa;p=k=rsa;p=MIGfMA0GCSqGSIb3DQEBAQUAA4GNADCBiQKBgQClXI0pMLt49Ib2jTQ3bCIw1QtEySHuaaOzk3Li0c9R3xAuOtt2PcxNx1TEgIdOA7fw6ONN1YyPf68NXOw7J3dV1Ldfln6VxRYcXaPSqhNtftaK87Rr6VqiJRiP4iEYQi4IQa9JJ4Za6s/aSLmji5mob7u3iI/Bj412Krkao6wLwwIDAQAB"
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

# Twilio

resource "google_dns_record_set" "twilio-verification" {
  project      = module.google-cloud-project.project.project_id
  managed_zone = module.google-cloud-dns.zone_name

  name = "_twilio.${module.google-cloud-dns.dns_name}"
  type = "TXT"
  ttl  = 3600

  rrdatas = [
    "twilio-domain-verification=12fc8b0170bb9b63e4b6de67a5c923f0"
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

resource "google_dns_record_set" "google-spf" {
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
    "protonmail-verification=775efd155d2dec59fc6341d6bbfec288038f1917",
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

## ext. domain email server
## TODO: get rid off this
resource "google_dns_record_set" "google-ext-mail" {
  project      = module.google-cloud-project.project.project_id
  managed_zone = module.google-cloud-dns.zone_name

  name = "ext.${module.google-cloud-dns.dns_name}"

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

resource "google_dns_record_set" "google-ext-dmarc" {
  project      = module.google-cloud-project.project.project_id
  managed_zone = module.google-cloud-dns.zone_name


  name = "_dmarc.ext.${module.google-cloud-dns.dns_name}"
  type = "TXT"
  ttl  = 3600

  rrdatas = [
    "\"v=DMARC1;\" \"p=reject;\" \"rua=mailto:dmarc-reports@firezone.dev;\" \"pct=100;\" \"adkim=s;\" \"aspf=s\"",
    "google-site-verification=xlFwz_eC6ksZ1dAJKwNzFISlZRpFRQ2mggo851altmI"
  ]
}

resource "google_dns_record_set" "google-ext-spf" {
  project      = module.google-cloud-project.project.project_id
  managed_zone = module.google-cloud-dns.zone_name

  name = "ext.${module.google-cloud-dns.dns_name}"
  type = "TXT"
  ttl  = 3600

  rrdatas = [
    "\"v=spf1 include:_spf.google.com ~all\""
  ]
}

resource "google_dns_record_set" "google-ext-dkim" {
  project      = module.google-cloud-project.project.project_id
  managed_zone = module.google-cloud-dns.zone_name

  name = "google._domainkey.ext.${module.google-cloud-dns.dns_name}"
  type = "TXT"
  ttl  = 3600

  rrdatas = [
    "\"v=DKIM1;\" \"k=rsa;\" \"p=MIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8AMIIBCgKCAQEAubhkd+M9O2fILLpfRzCN5vhd81uSfaCbfeQ5Uf/BsBnuJ8AYOsyW\" \"bzy3UYU1y2JnJi1D8U+o1idcTPC1wB1okBHUnohI1O9hRDHb5NzV4NTxK0D36ESbgGzv94xu1n1GfxoO/wWga69eu/unz79/SRdVEida09bF0eXg9q\" \"5dtyIPI9NvYGtKAvLIABYHkutlUA2dNggraVTXldTlccMWmtd9uzemBg0bpN6zxygSLM9PSsEf0WEJJYvUXrEIQI4o9Ujh1/PqIgRpdqRAbmyhO3BobGNm5qmn3i1ZxWF0L\" \"T8zC3QShMPO+BagJlDav1ZNxBtih+vqqeyJvm8gwPXHiQIDAQAB\""
  ]
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

# Proton
## TODO: get rid off this
resource "google_dns_record_set" "proton-domainkey1" {
  project      = module.google-cloud-project.project.project_id
  managed_zone = module.google-cloud-dns.zone_name

  type    = "CNAME"
  name    = "protonmail._domainkey.${module.google-cloud-dns.dns_name}"
  rrdatas = ["protonmail.domainkey.dbmieophzl5yorultqalvxh5cjl65qstyplotj4asfsqiqan6337a.domains.proton.ch."]
  ttl     = 3600
}

resource "google_dns_record_set" "proton-domainkey2" {
  project      = module.google-cloud-project.project.project_id
  managed_zone = module.google-cloud-dns.zone_name

  type    = "CNAME"
  name    = "protonmail2._domainkey.${module.google-cloud-dns.dns_name}"
  rrdatas = ["protonmail2.domainkey.dbmieophzl5yorultqalvxh5cjl65qstyplotj4asfsqiqan6337a.domains.proton.ch."]
  ttl     = 3600
}

resource "google_dns_record_set" "proton-domainkey3" {
  project      = module.google-cloud-project.project.project_id
  managed_zone = module.google-cloud-dns.zone_name

  type    = "CNAME"
  name    = "protonmail3._domainkey.${module.google-cloud-dns.dns_name}"
  rrdatas = ["protonmail3.domainkey.dbmieophzl5yorultqalvxh5cjl65qstyplotj4asfsqiqan6337a.domains.proton.ch."]
  ttl     = 3600
}
