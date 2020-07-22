![Test](https://github.com/CloudFire-LLC/fireguard/workflows/Test/badge.svg)
[![Coverage Status](https://coveralls.io/repos/github/CloudFire-LLC/fireguard/badge.svg?branch=master)](https://coveralls.io/github/CloudFire-LLC/fireguard?branch=master)

# FireGuard

**Warning**: This project is under active development and is absolutely not secure at the moment.
Do not attempt to use this software until this notice is removed.

You have been warned.

Check back later :-).


# Setup

* have postgres installed with a super user role `fireguard`

```
psql -h localhost -d postgres

CREATE ROLE fireguard;
```

* have elixir installed

```
brew install elixir
```

setup project

```
cd apps/fg_http && mix deps.get && mix ecto.setup 
npm install --prefix assets
mix phx.server
```


