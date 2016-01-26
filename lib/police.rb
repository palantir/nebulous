#!/usr/bin/env ruby
require_relative '../vendor/bundle/bundler/setup'
['./errors', './config', './provisioner', './stages', './utils', './controller', './jenkins', './bamboo', './operationcenter', './checker'].each do |relative|
  require_relative relative
end
['trollop'].each do |g|
  require g
end

check = lambda do |config, opts|
  checker = config.checker
  vm_hashes = checker.opennebula_state
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

opts = Trollop::options do
  opt :configuration, "Location of the target agent pool.",
   :required => true, :type => :string, :multi => false
  opt :decryption_key, "File path for the decryption key for secure configurations",
   :required => false, :type => :string, :multi => false
end
config = PoolConfig.load(opts[:configuration], opts[:decryption_key])
check.call(config, opts)