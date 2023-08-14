#!/usr/bin/env ruby

require 'sinatra'
require 'erb'

set :bind, '0.0.0.0'
set :port, 4568

get '/:slug/sign_in' do
  client_csrf_token = params['client_csrf_token']
  ERB.new("<h1>Auth page</h1><p><a href=\"/redirect\">Proceed</a></p><p><a href=\"/#{client_csrf_token}/magiclink\">Magic Link (Copy link and open in External Browser)</a></p>")
     .result(binding)
end

get '/redirect' do
  client_auth_token = File.read('./data/client_auth_token').strip
  redirect "firezone://handle_client_auth_callback?client_auth_token=#{client_auth_token}&actor_name=Foo+Bar"
end

get '/:client_csrf_token/magiclink' do
  client_csrf_token = params[:client_csrf_token]
  client_auth_token = File.read('./data/client_auth_token').strip
  ERB.new("<h1>Magic Link Page</h1><p><a href=\"firezone-fd0020211111://handle_client_auth_callback?client_auth_token=#{client_auth_token}&actor_name=Foo+Bar&client_csrf_token=#{client_csrf_token}\">Open Firezone App</a></p></p>")
     .result(binding)
end
