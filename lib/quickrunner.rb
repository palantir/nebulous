require_relative './stages'
require_relative './errors'
require_relative './controller'

##
# Simple Runner.

class QuickProvisioner < BnclController

    
  def initialize(script_path, arguments = nil)
    configuration = [{"type" => "directory", "path" => script_path, "arguments" => arguments}]
    @configuration = configuration
    configuration.each_with_index {|stage, index| Stages.from_config(stage, index)}
  end

  ##
  # For each VM generate the commands we are going to run and copy them over.

  def generate_ssh_commands(vm_hash)
    stage_collection = Stages::StageCollection.new(*stages(@configuration))
    stage_collection.generate_files
    ip_address = vm_hash['TEMPLATE']['NIC']['IP']
    STDOUT.puts "Generating provisioning commands for #{vm_hash['NAME']} and IP #{ip_address}."
    stage_collection.scp_files(ip_address)
    STDOUT.puts "Running commands"
    stage_collection.final_command(ip_address)
  end

end
