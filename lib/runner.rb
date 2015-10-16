#!/usr/bin/env ruby
require_relative '../vendor/bundle/bundler/setup'
['./errors', './config', './provisioner', './stages', './utils', './controller', './jenkins', './bamboo', './operationcenter', './checker', './quickrunner'].each do |relative|
  require_relative relative
end
['trollop'].each do |g|
  require g
end

##
# Factors out the commonality among the provisioning and replenishing.

def forking_provisioner_actions(provisioner, partition, actions = [])
  raise EmptyActionArray, "Must provide at least one action to perform with provisioner." if actions.empty?
  delta = provisioner.delta
  forking_provisioners = (1..delta).each_slice(partition).map {|slice| provisioner.forked_provisioner(slice.length)}
  pids = forking_provisioners.each_with_index.map do |p, i|
    fork do
      sleep i * 5
      vm_hashes = p.instantiate
      actions.each do |action|
        p.send(action, vm_hashes)
      end
    end
  end
  pids.each do |pid|
    STDOUT.puts "Waiting on child process: #{pid}."
    Process.wait(pid)
  end
end

##
# Regular actions with no forking involved.

def provisioner_actions(provisioner, actions = [])
  raise EmptyActionArray, "Must provide at least one action to perform with provisioner." if actions.empty?
  vm_hashes = provisioner.instantiate
  actions.each do |action|
    provisioner.send(action, vm_hashes)
  end
end

##
# Take the options hash and see if there is a partition option and act accordingly

def partition_switch(config, opts, actions)
  provisioner = config.provisioner
  if (partition = opts[:partition])
    forking_provisioner_actions(provisioner, partition, actions)
  else
    provisioner_actions(provisioner, actions)
  end
end

##
# All the allowed actions.

valid_actions = {
  # Check vm state
  'check' => lambda do |config, opts|
    #return checker object
    checker = config.checker
    vm_hashes = checker.opennebula_state
    id_filter = opts[:synthetic]
    if id_filter
      vm_hashes.select! {|vm| id_filter.include?(vm['ID'])}
    end
    if checker.run(vm_hashes) == 1
      exit 1
    end
  end,
  # Clean up stuff on the open nebula side because we no longer see them on the CI side
  'garbage-collect' => lambda do |config, opts|
    provisioner = config.provisioner
    provisioner.garbage_collect
  end,
  # Spin up VMs and provision but don't register
  'provision' => lambda do |config, opts|
    actions = [:run]
    partition_switch(config, opts, actions)
  end,
  # Spin up VMs, provision, and register them
  'replenish' => lambda do |config, opts|
    actions = [:run, :registration]
    partition_switch(config, opts, actions)
  end,
  # Get what exists and try to re-register it
  're-register' => lambda do |config, opts|
    provisioner = config.provisioner
    vm_hashes = provisioner.opennebula_state
    id_filter = opts[:synthetic]
    if id_filter
      vm_hashes.select! {|vm| id_filter.include?(vm['ID'])}
    end
    provisioner.registration(vm_hashes)
  end,
  're-provision' => lambda do |config, opts|
    provisioner = config.provisioner
    vm_hashes = provisioner.opennebula_state
    id_filter = opts[:synthetic]
    if id_filter
      vm_hashes.select! {|vm| id_filter.include?(vm['ID'])}
    end
    provisioner.run(vm_hashes)
  end,
  'dump-state' => lambda do |config, opts|
    provisioner = config.provisioner
    vm_hashes = provisioner.opennebula_state
    vm_hashes.each do |vm_hash|
      id = vm_hash['ID']
      name = vm_hash['NAME']
      ip = vm_hash['TEMPLATE']['NIC']['IP']
      hostname = vm_hash['TEMPLATE']['CONTEXT']['SET_HOSTNAME']
      pool = vm_hash['USER_TEMPLATE']['POOL']
      STDOUT.puts "#{id} - #{ip} - #{name} - #{hostname} - #{pool}"
    end
  end,
  # This is a dangerous operation so adding a warning message and forcing the user
  # to acknowledge they want to proceed
  'kill-all' => lambda do |config, opts|
    provisioner = config.provisioner
    vm_hashes = provisioner.opennebula_state
    id_filter = opts[:synthetic]
    if id_filter
      vm_hashes.select! {|vm| id_filter.include?(vm['ID'])}
    end
    unless opts[:force]
      STDOUT.puts "You are about to kill a bunch of VMs:"
      ids = vm_hashes.map {|vm_hash| vm_hash['ID']}.join(', ')
      STDOUT.puts ids
      STDOUT.write "Are you sure you want to proceed? (y/n): "
      confirmation = STDIN.gets.strip.downcase
      if confirmation.include?('n')
        STDOUT.puts "Aborting!"
        exit!
      else
        STDOUT.puts "Proceeding!"
      end
    end
    vm_hashes.each do |vm_hash|
      vm = Utils.vm_by_id(vm_hash['ID'])
      STDOUT.puts "Killing VM: #{vm_hash['ID']}."
      vm.delete
    end
    provisioner.deleteJobs(vm_hashes)
  end,
  'kill-not-running' => lambda do |config, opts|
    provisioner = config.provisioner
    vm_hashes = provisioner.opennebula_state
    id_filter = opts[:synthetic]
    if id_filter
      vm_hashes.select! {|vm| id_filter.include?(vm['ID'])}
    end
    vms = vm_hashes.map {|h| vm = Utils.vm_by_id(h['ID']); vm.info; vm}
    vms.reject! {|vm| vm.status.include?('run')}
    vm_hashes = vms.map {|vm| vm.to_hash['VM']}
    unless opts[:force]
      STDOUT.puts "You are about to kill a bunch of VMs:"
      ids = vm_hashes.map {|vm_hash| vm_hash['ID']}.join(', ')
      STDOUT.puts ids
      STDOUT.write "Are you sure you want to proceed? (y/n): "
      confirmation = STDIN.gets.strip.downcase
      if confirmation.include?('n')
        STDOUT.puts "Aborting!"
        exit!
      else
        STDOUT.puts "Proceeding!"
      end
    end
    vm_hashes.each do |vm_hash|
      vm = Utils.vm_by_id(vm_hash['ID'])
      STDOUT.puts "Killing VM: #{vm_hash['ID']}."
      vm.delete
    end
  end
}

opts = Trollop::options do
  opt :configuration, "Location of pool configuration yaml file",
   :required => false, :type => :string, :multi => false
  opt :type, "Type of provisioner (script or directory)",
   :required => false, :type => :string, :multi => false
  opt :file, "Script of directory to execute",
   :required => false, :type => :string, :multi => false
  opt :pool, "OpenNebula pool to provision.",
   :required => false, :type => :string, :multi => false
  opt :action, "Type of action, e.g. #{valid_actions.keys.join(', ')}. Can be repeated several times",
   :required => false, :type => :string, :multi => true, :default => "quickrunner"
  opt :decryption_key, "File path for the decryption key for secure configurations",
   :required => false, :type => :string, :multi => false
  opt :synthetic, "Provide a list of IDs to act on",
    :required => false, :type => :strings, :multi => false
  opt :partition, "Set the partition size for parallel provisioning",
   :required => false, :type => :integer, :multi => false
  opt :force, "Force a kill-all command without asking for confirmation",
    :required => false, :type => :flag, :multi => false
end
# Instantiate the objects we might need, and pass in the decryption key if there is one
if !opts[:action].include?("quickrunner")
  #return cnfig type with Provisioner and checker
  config = PoolConfig.load(opts[:configuration], opts[:decryption_key])
  opts[:action].uniq!
  opts[:action].each do |action|
  case action
  when *valid_actions.keys
  else
    raise UnknownActionError, "Unknown action: #{action}."
  end
  #action calls method (lambda) with config file params and opts
  opts[:action].each {|action| valid_actions[action].call(config, opts)}
end
# Now go through the actions and actually perform it
else
  
  quick_runner = PoolConfig.quickRunner({"type" => opts[:type], "path" => opts[:file], "name" => opts[:pool]})
  vm_hashes = quick_runner.opennebula_state
  id_filter = opts[:synthetic]
  if id_filter
    vm_hashes.select! {|vm| id_filter.include?(vm['ID'])}
  end
  if quick_runner.quickrunner.run(vm_hashes) == 1
    exit 1
  end
end
# Uniquify the actions and verify it is something we can work with
