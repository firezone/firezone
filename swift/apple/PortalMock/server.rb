#!/usr/bin/env ruby

require 'sinatra'
require 'erb'

set :bind, '0.0.0.0'
set :port, 4568

get '/:slug/sign_in' do
  ERB.new("<h1>Auth page</h1><a href=\"/redirect\">Proceed</a>")
     .result(binding)
end

get '/redirect' do
  client_auth_token = File.read('./data/client_auth_token').strip
  redirect "firezone://handle_client_auth_callback?client_auth_token=#{client_auth_token}"
end
