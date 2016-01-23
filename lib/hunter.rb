#!/usr/bin/env ruby
require_relative '../vendor/bundle/bundler/setup'
['./errors', './config', './provisioner', './stages', './utils', './controller', './jenkins', './bamboo', './operationcenter', './checker'].each do |relative|
  require_relative relative
end
['trollop'].each do |g|
  require g
end

def take_offline(vm, config)
  provisioner = config.provisioner
  provisioner.take_offline?(vm)
end

# Return the max number of agents we will attempt to take offline.
# This is the niumber of online agents minus min number of allowed
# offline agents. Ex. If we have 25 agents online, and min is 23,
# this method will return 2.

def delta_reap_size(config)
  provisioner = config.provisioner
  provisioner.offline_delta
end

##
# Take the options hash and see if there is a partition option and act accordingly

def make_vm_list(config, delete_age, size)
  vm_list = []
  currtime = Time.now.to_i
  STDOUT.puts "Making vm list of size #{size} for vms older than #{delete_age} days"
  provisioner = config.provisioner
  vm_hashes = provisioner.opennebula_state
  vm_hashes.each do |vm_hash|
    if vm_list.size >= size
      STDOUT.puts "Found #{size} vms older than #{delete_age}, exiting loop"
      break
    end
    stime = vm_hash['HISTORY_RECORDS']['HISTORY']['STIME'].to_i
    vm_age = (currtime - stime) / (3600 * 24)
    STDOUT.puts "Age of vm is #{vm_age}"
    if vm_age >= delete_age
      STDOUT.puts "Age of vm is greater than delete age, adding to vm_list"
      vm_list.push(vm_hash)
    end
  end
  STDOUT.puts "Searching for #{size} vms and found #{vm_list.size}, returning list"
  vm_list
end

hunt = lambda do |config, opts|
  
  # Get max number of agents we are allowed to take off
  max_reap_size = delta_reap_size(config)
  if max_reap_size <= 0
    abort("Enough vms are offline! Exiting...")
  end

  # If we want to take off less agents than the maximum threshold,
  # allow removal of fewer agents

  if max_reap_size > opts[:size]
    reap_size = opts[:size]
  else

  # If we want to take off more agents than what's allowed
  # try to reach our goal as best as possible.
    reap_size = max_reap_size
  end

  vm_hashes = make_vm_list(config, opts[:age], reap_size)
  STDOUT.puts "Hunted #{vm_hashes.size} old vms. Time to take them offline!"
  vm_hashes.each do |vm_hash|
    take_offline(vm_hash, config)
  end
  STDOUT.puts "Successfully marked the old agents offline!"
end

opts = Trollop::options do
  opt :configuration, "Location of the target agent pool.",
   :required => true, :type => :string, :multi => false
  opt :size, "Maximum number of VMs to take offline.",
   :required => true, :type => :integer, :multi => false
  opt :age, "Replace all VMs that are older than this age.",
   :required => true, :type => :integer, :multi => false
  opt :decryption_key, "File path for the decryption key for secure configurations",
   :required => false, :type => :string, :multi => false
end
config = PoolConfig.load(opts[:configuration], opts[:decryption_key])
hunt.call(config, opts)
