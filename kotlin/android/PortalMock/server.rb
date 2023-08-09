#!/usr/bin/env ruby

# This server attempts to provide a crude mock of the Firezone auth process.

require 'sinatra'

set :bind, '0.0.0.0'
set :port, 4568

get '/:slug/sign_in' do
  csrfToken = params['client_csrf_token']
  ERB.new("<h1>Auth page</h1><a href=\"/redirect?client_csrf_token=#{csrfToken}\">Proceed</a>")
     .result(binding)
end

get '/redirect' do
  dest = 'https://app.firez.one/handle_client_auth_callback'
  csrfToken = params['client_csrf_token']
  authToken = File.read(File.join(__dir__, 'data', 'jwt'))
  redirect "#{dest}?client_csrf_token=#{csrfToken}&client_auth_token=#{authToken}"
end
