require 'logger'
require_relative './stages'
require_relative './errors'

##
# Supertype for provisioners.

class BnclController
  ##
  # Just delegate to the configuration object because it has all the pieces to access
  # OpenNebula and perform the necessary comparisons and filtering.
  def action_log
    action_log = Logger.new( '/opt/nebulous/bncl_actions_log', 'daily' )
    action_log.level = Logger::INFO
    @action_log = action_log
  end

  def opennebula_state
    @configuration.opennebula_state
  end

  ##
  # By default the delta is the difference between the configured pool size and what currently exists in OpenNebula
  # but wrappers can override this method which can be used during forking to do the right thing.

  def delta
    required_pool_size = @configuration.count
    actual_pool_size = opennebula_state.length # TODO: Figure out whether we need to filter to just running VMs
    delta = required_pool_size - actual_pool_size
    if delta == 0
      abort("Already provisioned #{required_pool_size} vms.")
    end
    delta
  end

  ##
  # Look at the current delta and generate the required number of forking provisioners.

  def partition(partition_size)
    (1..delta).each_slice(partition_size).map {|slice| forked_provisioner(slice.length)}
  end

  ##
  # Get the state and see if the delta is positive. If the delta is positive then instantiate that
  # many new servers so we can continue with the provisioning process by running the required scripts
  # through SSH. This should return just the VM data because we are going to use SSH to figure out if
  # they are up and running and ready for the rest of the process.

  def instantiate(vm_name_prefix = nil)
    if delta > 0
      STDOUT.puts "Pool delta: pool = #{@configuration.name}, delta = #{delta}."
      @configuration.instantiate!(delta, vm_name_prefix)
    else
      []
    end
  end

  ##
  # Required for most SSH commands.

  def ssh_prefix
    ['ssh', '-o UserKnownHostsFile=/dev/null',
      '-o StrictHostKeyChecking=no', '-o BatchMode=yes', '-o ConnectTimeout=20'].join(' ')
  end

  ##
  # We need to wait until we can reliably make SSH connections to each host and log any errors
  # for the hosts that are unreachable.

  def ssh_ready?(vm_hash)
    ip_address = vm_hash['TEMPLATE']['NIC']['IP']
    raise VMIPError, "IP not found: #{vm_hash}." if ip_address.nil?
    system("#{ssh_prefix} root@#{ip_address} -t 'uptime'")
  end

  ##
  # Look at the configuration and see what kinds of provisioning stages there are and
  # generate commands accordingly. Each stage can have multiple commands.

  def stages(controll_stages)
    controll_stages.each_with_index.map {|stage, index| Stages.from_config(stage, index)}
  end

  def run(vm_hashes)
    if vm_hashes.empty?
      abort("No VMs to provision.")
    end
    vms_left = vm_hashes.length
    run_results = Hash['SUCCESS', [], 'FAILED', []] 
    ssh_action = lambda do |vm_hash|
        final_commands = generate_ssh_commands(vm_hash)
        result = system(final_commands)
        return result
    end
    vm_hashes.each do |vm_hash|

      ssh_counter = 0
      # Wait a bit for vm to be ssh ready
      while ssh_counter < 15 && !ssh_ready?(vm_hash)
        ssh_counter += 1
        sleep 5
      end
      provision_counter = 0

      while provision_counter < 3 && !ssh_action.call(vm_hash)
        provision_counter += 1
        sleep 5
      end
      # If we exit the previous loop and count is less then 15, then we must have been successful
      if provision_counter < 3
        vms_left = vms_left - 1
        run_results['SUCCESS'].push(vm_hash)
        STDOUT.puts "VM just provisioned: #{vm_hash['NAME']}."
        STDOUT.puts "Number of vms left to provision: #{vms_left}."
      else
        run_results['FAILED'].push(vm_hash)
      end
    end
    
    if vms_left != 0
      STDOUT.puts "ERROR: Failed to provision #{vms_left} vms."
    else
      STDOUT.puts "Successfully provisioned #{vm_hashes.length} vms."
    end
    run_results
  end

end
