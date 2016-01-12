#!/usr/bin/env ruby
require_relative '../vendor/bundle/bundler/setup'
['./errors', './config', './provisioner', './stages', './utils', './controller', './jenkins', './bamboo', './operationcenter', './checker'].each do |relative|
  require_relative relative
end
['trollop'].each do |g|
  require g
end

def provisioner_actions(provisioner, checker, vm_hashes)
  run_results = Hash['SUCCESS', [], 'FAILED', []]
  failed_results = Hash['SUCCESS', [], 'FAILED', []]
  run_results = provisioner.send(:run, vm_hashes)
  run_results['FAILED'].each do |failed_vm|
    ip = failed_vm['TEMPLATE']['NIC']['IP']
    STDOUT.puts "Failed to provision #{ip}. Will try one more time to re-provision."
    failed_results = provisioner.send(:run, [failed_vm])
  end
  failed_results['FAILED'].each do |failed_vm|
    # Delete all the bad ones so we can detect the delta at next round
    vm = Utils.vm_by_id(failed_vm['ID'])
    vm.delete
  end
  failed_results['SUCCESS'].each do |good_vm|
    provisioner.registration([good_vm])
  end
  run_results['SUCCESS'].each do |good_vm|
    provisioner.registration([good_vm])
  end
end

create = lambda do |config, opts|
	provisioner = config.provisioner
	vm_hashes = provisioner.instantiate
	run_results = provisioner_actions(provisioner, config.checker, vm_hashes)
end

opts = Trollop::options do
  opt :configuration, "Location of the target agent pool.",
   :required => true, :type => :string, :multi => false
  opt :decryption_key, "File path for the decryption key for secure configurations",
   :required => false, :type => :string, :multi => false
end
config = PoolConfig.load(opts[:configuration], opts[:decryption_key])
create.call(config, opts)
