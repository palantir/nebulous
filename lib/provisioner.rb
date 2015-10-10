require_relative './stages'
require_relative './errors'
require_relative './controller'
require 'jenkins_api_client'
require 'nokogiri'

##
# Supertype for provisioners.

class Provisioner

  class ProvisionerType < BnclController

    def initialize(configuration)
      @configuration = configuration
      configuration.provision.each_with_index {|stage, index| Stages.from_config(stage, index)}
    end

    ##
    # For each VM generate the commands we are going to run and copy them over.

    def generate_ssh_commands(vm_hash)
      stage_collection = Stages::StageCollection.new(*stages(@configuration.provision))
      stage_collection.generate_files
      ip_address = vm_hash['TEMPLATE']['NIC']['IP']
      STDOUT.puts "Generating provisioning commands for #{vm_hash['NAME']} and IP #{ip_address}."
      stage_collection.scp_files(ip_address)
      STDOUT.puts "Running commands"
      stage_collection.final_command(ip_address)
    end
  end

end
