# Dev-only scripts build fixture structs by hand and call into code paths
# Dialyzer cannot follow, so a handful of warnings there are expected. Listed
# one at a time rather than by directory: ignoring the directory wholesale hid
# a credential built with a type that does not exist.
[
  {"lib/portal/dev/account_population.ex", :no_return},
  {"lib/portal/dev/account_population.ex", :call}
]
