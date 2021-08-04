source 'https://supermarket.chef.io'

cookbook 'omnibus'

# Uncomment to use the latest version of the Omnibus cookbook from GitHub
# cookbook 'omnibus', github: 'chef-cookbooks/omnibus'

group :integration do
  cookbook 'apt',      '~> 2.8'
  cookbook 'freebsd',  '~> 0.3'
  cookbook 'yum-epel', '~> 0.6'
end
