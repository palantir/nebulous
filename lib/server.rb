#!/usr/bin/env ruby
require_relative './provisioner'
require_relative './config'
require 'sinatra'
require 'jenkins_api_client'
require 'nokogiri'
require 'opennebula'

post '/reboot/' do
    request.body.rewind  # in case someone already read it
    data = JSON.parse request.body.read
    "Hello #{data['type']}!"
    type = data['type']
    name = data['name']
    jenkins_username = data['jenkins_username']
    jenkins_password = data['jenkins_password']
    credentials_id = data['credentials_id']
    STDOUT.puts "#{name} #{type} #{jenkins_username} #{jenkins_password} #{credentials_id}"
    config = getConfigFromRequest(data)
    provisioner = config.provisioner
    vm_hashes = provisioner.opennebula_state
    vm_hashes.each do |vm_hash|
      vm = Utils.vm_by_id(vm_hash['ID'])
      STDOUT.puts "Restarting VM: #{vm_hash['ID']}."
      vm.restart
    end
    provisioner.enableJobs(vm_hashes)
end

def getConfigFromRequest(data, key_path = nil)
    case (config_type = data['type'])
    when 'jenkins'
      Jenkins.new(data, key_path)
    when 'bamboo'
      Bamboo.new(data, key_path)
    when 'operationcenter'
      OperationCenter.new(data, key_path)
    else
      raise UnknownConfigurationTypeError, "Unknown configuration type: #{config_type}."
    end
end
