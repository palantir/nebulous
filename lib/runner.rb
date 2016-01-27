#!/usr/bin/env ruby
require_relative '../vendor/bundle/bundler/setup'
['./errors', './config', './provisioner', './stages', './utils', './controller', './jenkins', './bamboo', './operationcenter', './checker'].each do |relative|
  require_relative relative
end
['trollop'].each do |g|
  require g
end

def check_actions(checker, vm_hashes)
  check_results = checker.run(vm_hashes)
  check_results.each do |failed_vm|
    ip = failed_vm['TEMPLATE']['NIC']['IP']
    STDOUT.puts "#{ip} failed checks. Please delete or re-provision before registering the vm pool."
  end
  if check_results.empty?
      STDOUT.puts "Success! All vms were provisioned correctly and passed checks!"
  end
  check_results
end
##
# Regular actions with no forking involved.

def provisioner_actions(provisioner, vm_hashes, actions = [])
  raise EmptyActionArray, "Must provide at least one action to perform with provisioner." if actions.empty?
  run_results = []
  actions.each do |action|
    run_results = provisioner.send(action, vm_hashes)
    run_results.each do |failed_vm|
      ip = failed_vm['TEMPLATE']['NIC']['IP']
      STDOUT.puts "Failed to provision #{ip}. Please delete or re-provision before registering the vm pool."
    end
  end
  run_results
end

# All the allowed actions.

valid_actions = {
  # Check vm state
  'check' => lambda do |config, opts|
    #return checker object
    checker = config.checker
    vm_hashes = checker.opennebula_state
    ip_filter = opts[:synthetic]
    if ip_filter
      vm_hashes.select! {|vm_hash| ip_filter.include?(vm_hash['TEMPLATE']['NIC']['IP'])}
    end
    vm_hashes.each do |vm_hash|
      ip = vm_hash['TEMPLATE']['NIC']['IP']
      `ssh -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no -o BatchMode=yes -o ConnectTimeout=10 root@#{ip} -t 'rm -rf /root/bncl-check-results; mkdir /root/bncl-check-results;'`
    end
    check_results = checker.run(vm_hashes)
    vm_hashes.each do |vm_hash|
      ip = vm_hash['TEMPLATE']['NIC']['IP']
      `scp -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no -r root@#{ip}:/root/bncl-check-results /var/lib/jenkins/tmp-results/#{ip}`
    end
    check_results['FAILED'].each do |failed_vm|
      ip = failed_vm['TEMPLATE']['NIC']['IP']
      STDOUT.puts "#{ip} Failed checks. Please delete or re-provision."
    end
  end,
  # Spin up VMs and provision but don't register
  'provision' => lambda do |config, opts|
    actions = [:run]
    run_results = provisioner_actions(config, opts, actions)
    run_results['FAILED'].each do |failed_vm|
      ip = failed_vm['TEMPLATE']['NIC']['IP']
      STDOUT.puts "#{ip} Failed checks. Please delete or re-provision."
    end
  end,
  # Get what exists and try to re-register it
  're-register' => lambda do |config, opts|
    provisioner = config.provisioner
    vm_hashes = provisioner.opennebula_state
    ip_filter = opts[:synthetic]
    if ip_filter
      vm_hashes.select! {|vm_hash| ip_filter.include?(vm_hash['TEMPLATE']['NIC']['IP'])}
    end
    provisioner.registration(vm_hashes)
  end,
  're-provision' => lambda do |config, opts|
    provisioner = config.provisioner
    vm_hashes = provisioner.opennebula_state
    ip_filter = opts[:synthetic]
    if ip_filter
      vm_hashes.select! {|vm_hash| ip_filter.include?(vm_hash['TEMPLATE']['NIC']['IP'])}
    end
    run_results = provisioner.run(vm_hashes)
    run_results['FAILED'].each do |failed_vm|
      ip = failed_vm['TEMPLATE']['NIC']['IP']
      STDOUT.puts "Failed to provision #{ip}. Please delete or re-provision before registering"
    end
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
  end
}

opts = Trollop::options do
  opt :configuration, "Location of pool configuration yaml file",
   :required => false, :type => :string, :multi => false
  opt :action, "Type of action, e.g. #{valid_actions.keys.join(', ')}. Can be repeated several times",
   :required => true, :type => :string, :multi => true
  opt :decryption_key, "File path for the decryption key for secure configurations",
   :required => false, :type => :string, :multi => false
  opt :synthetic, "Provide a list of ip addresses to act on",
    :required => false, :type => :strings, :multi => false
end
config = PoolConfig.load(opts[:configuration], opts[:decryption_key])
opts[:action].uniq!
opts[:action].each do |action|
  case action
  when *valid_actions.keys
  else
    raise UnknownActionError, "Unknown action: #{action}."
  end
  opts[:action].each {|action| valid_actions[action].call(config, opts)}
end
