#!/usr/bin/env ruby

require 'sinatra'
require 'erb'

set :bind, '0.0.0.0'
set :port, 4568

get '/handle_client_auth_callback' do
  dest = params['dest']
  ERB.new("<h1>Auth page</h1><a href=\"/redirect?dest=#{dest}\">Proceed</a>").result(binding)
end

get '/redirect' do
  dest = params['dest']
  client_auth_token = File.read('./data/client_auth_token').strip
  redirect "#{dest}?client_auth_token=#{client_auth_token}"
end
