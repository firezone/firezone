defmodule Portal.Repo.Migrations.CreateKnownMxDomains do
  use Ecto.Migration

  @domains ~w[
    aliyun.com
    antispameurope.com
    app.hey.com
    barracudanetworks.com
    emailsrvr.com
    emx.mail.ru
    fireeyecloud.com
    gmx.net
    googlemail.com
    gpphosted.com
    hanmail.net
    hornetsecurity.com
    hydra.sophos.com
    iphmx.com
    l.google.com
    mail.com
    mail.icloud.com
    mail.naver.com
    mail.protection.office365.us
    mail.tutanota.de
    mailbox.org
    messagelabs.com
    messagingengine.com
    mimecast.co.za
    mimecast.com
    mx.microsoft
    mx.yandex.net
    mx.yandex.ru
    mxhichina.com
    mxmail.netease.com
    mxs.mail.ru
    posteo.de
    ppe-hosted.com
    pphosted.com
    protection.outlook.com
    protonmail.ch
    qq.com
    secureserver.net
    seznam.cz
    smtp.goog
    smtp.google.com
    tmes.trendmicro.com
    tmes.trendmicro.eu
    web.de
    yahoodns.net
    zoho.com
    zoho.com.au
    zoho.com.cn
    zoho.eu
    zoho.in
    zoho.jp
    zoho.sa
    zoho.uk
    zohocloud.ca
  ]

  def up do
    create table(:known_mx_domains, primary_key: false) do
      add :domain, :text, primary_key: true
    end

    create constraint(:known_mx_domains, :domain_format,
             check:
               "char_length(domain) <= 253 AND domain ~ '^([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\\.)+[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$'"
           )

    values = Enum.map_join(@domains, ", ", &"('#{&1}')")
    execute("INSERT INTO known_mx_domains (domain) VALUES #{values} ON CONFLICT DO NOTHING")
  end

  def down do
    drop table(:known_mx_domains)
  end
end
