#!/usr/bin/env ruby
require_relative '../vendor/bundle/bundler/setup'
['./errors', './config', './provisioner', './stages', './utils', './controller', './jenkins', './bamboo', './operationcenter', './checker', './quickrunner'].each do |relative|
  require_relative relative
end
['trollop'].each do |g|
  require g
end

reap = lambda do |config, opts|
    provisioner = config.provisioner
    offline_agents = provisioner.offline_agents
    provisioner.garbage_collect(offline_agents)
end

opts = Trollop::options do
  opt :configuration, "Location of the target agent pool.",
   :required => true, :type => :string, :multi => false
  opt :decryption_key, "File path for the decryption key for secure configurations",
   :required => false, :type => :string, :multi => false
end
config = PoolConfig.load(opts[:configuration], opts[:decryption_key])
#action calls method (lambda) with config file params and opts
reap.call(config, opts)
# Uniquify the actions and verify it is something we can work with