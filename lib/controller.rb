require_relative './stages'
require_relative './errors'

##
# Supertype for provisioners.

class BnclController
  ##
  # Just delegate to the configuration object because it has all the pieces to access
  # OpenNebula and perform the necessary comparisons and filtering.

  def opennebula_state
    STDOUT.puts "open nebula state #{@configuration.opennebula_state}"
    @configuration.opennebula_state
  end

  ##
  # By default the delta is the difference between the configured pool size and what currently exists in OpenNebula
  # but wrappers can override this method which can be used during forking to do the right thing.

  def delta
    required_pool_size = @configuration.count
    actual_pool_size = opennebula_state.length # TODO: Figure out whether we need to filter to just running VMs
    delta = required_pool_size - actual_pool_size
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

  def ssh_ready?(vm_hashes)
    ssh_test = lambda do |vm_hash|
      ip_address = vm_hash['TEMPLATE']['NIC']['IP']
      raise VMIPError, "IP not found: #{vm_hash}." if ip_address.nil?
      STDOUT.puts "Running #{ssh_prefix} root@#{ip_address} -t 'uptime'"
      system("#{ssh_prefix} root@#{ip_address} -t 'uptime'")
    end
    counter = 0
    while !vm_hashes.all? {|vm_hash| ssh_test.call(vm_hash)}
      counter += 1
      tries_left = 60 - counter
      STDOUT.puts "Couldn't connect to all agents. Will try #{tries_left} more times"
      break if counter > 60
      sleep 5
    end
    accumulator = []
    vm_hashes.each do |vm_hash|
      if ssh_test.call(vm_hash)
        STDOUT.puts "VM ready: #{vm_hash['NAME']}."
        accumulator << vm_hash
      else
        STDERR.puts "Unable to establish SSH connection to VM: #{vm_hash}."
      end
    end
    accumulator
  end

  ##
  # Look at the configuration and see what kinds of provisioning stages there are and
  # generate commands accordingly. Each stage can have multiple commands.

  def stages(controll_stages)
    controll_stages.each_with_index.map {|stage, index| Stages.from_config(stage, index)}
  end

  ##
  # For each VM generate the commands we are going to run and copy them over.

  def generate_ssh_commands(vm_hashes)
    stage_collection = Stages::StageCollection.new(*stages(@configuration.check))
    stage_collection.generate_files
    vm_hashes.map do |vm|
      ip_address = vm['TEMPLATE']['NIC']['IP']
      STDOUT.puts "Generating commands for #{vm['NAME']} and IP #{ip_address}."
      stage_collection.scp_files(ip_address)
      STDOUT.puts "Running commands"
      stage_collection.final_command(ip_address)
    end
  end

  def run(vm_hashes)
    ready_vms = ssh_ready?(vm_hashes)
    final_commands = generate_ssh_commands(ready_vms)
    final_commands.each do |command| # All the commands for a VM
      STDOUT.puts "Running command: #{command}."
      system(command)
    end
  end

end
