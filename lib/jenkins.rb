require_relative './stages'
require_relative './errors'
require_relative './provisioner'
require 'jenkins_api_client'
require 'nokogiri'

class JenkinsProvisioner < Provisioner::ProvisionerType

  class ForkingProvisioner < JenkinsProvisioner

    def initialize(delta, configuration)
      @delta = delta
      super(configuration)
      @jenkins_node_client = ::JenkinsApi::Client::Node.new(jenkins_client)
    end

    def delta
      @delta
    end

  end

  def initialize(configuration)
    super
  end

  @@registration_wait_time = 30

  def forked_provisioner(delta)
    ForkingProvisioner.new(delta, @configuration)
  end

  def jenkins_client
    jenkins_username = @configuration.jenkins_username
    jenkins_password = @configuration.jenkins_password
    jenkins = @configuration.jenkins
    private_key_path = @configuration.private_key_path
    credentials_id = @configuration.credentials_id
    ::JenkinsApi::Client.new(:username => jenkins_username,
                              :password => jenkins_password, :server_url => jenkins)
  end

  ##
  # After provisioning perform the registration to jenkins.

  def registration(vm_hashes)
    vm_name = @configuration.name
    labels = @configuration.labels
    client = @jenkins_node_client
    vm_hashes.each do |vm_hash|
      agent_ip = vm_hash['TEMPLATE']['NIC']['IP']
      agent_name = "#{vm_name}-#{agent_ip}"
      client.create_dumb_slave({
        :name => agent_name, :remote_fs => '/home/jenkins',
        :description => "Ephemeral agent meant to run only 1 job and then die.",
        :slave_host => agent_ip, :private_key_file => private_key_path,
        :executors => 1, :labels => labels.join(", "), :credentials_id => credentials_id})
        sleep @@registration_wait_time
    end
  end
  
  def deleteJobs
    #TO-DO
  end

  def take_offline?(vm)
    ip = vm.to_hash['TEMPLATE']['NIC']['IP']
    client = @jenkins_node_client
    list_nodes = client.list(filter='#{ip}')
    if list_nodes.size > 1
      abort("Only delete one node at a time!")
    else
      node_name = list_nodes.first
      count = 0
      begin
        client.toggle_temporarilyOffline(node_name, reason="Reaping old node.")
        rescue
          STDOUT.puts "retrying to take node #{node_name} offline."
          count += 1
          sleep 30
          retry
      end while !client.is_temporarilyOffline?(node_name) && count < 30
      if client.is_temporarilyOffline?(node_name)
        vm.delete
        return true
      else
        STDOUT.puts "Failed to take #{node_name} offline."
        client.delete(node_name)
        return false
      end
    end
  end
  ##
  # Garbage collection means asking Jenkins what nodes it currently has and then performing
  # the cleanup on the OpenNebula side. Don't clean anything that is younger than 5 minutes.

  def garbage_collect
    jenkins = @configuration.jenkins
    jenkins_username = @configuration.jenkins_username
    jenkins_password = @configuration.jenkins_password
    endpoint = (jenkins[-1] == 47 || jenkins[-1] == '/') ?
      jenkins + 'get
      /agents' : jenkins + '/getBncl/agents'
    agent_ips = JSON.parse(`curl -b bamboo-cookies.txt -c bamboo-cookies.txt -s -k -u #{jenkins_username}:#{jenkins_password} #{endpoint}`.strip)
    STDOUT.puts "Found active agents: #{agent_ips.join(', ')}."
    epoch_now = Time.now.to_i
    garbage_agents = opennebula_state.reject do |vm_hash|
      vm_ip = vm_hash['TEMPLATE']['NIC']['IP']
      agent_ips.include?(vm_ip)
    end.select do |vm_hash|
      vm_start_time = Time.at(vm_hash['STIME'].to_i).to_i
      beyond_time_threshold = epoch_now - vm_start_time > (5 * 60) # Older than 5 minutes
    end
    if garbage_agents.empty?
      STDOUT.puts "Did not find any garbage agents."
    end
    garbage_agents.each do |vm_hash|
      STDOUT.puts "Killing VM: #{vm_hash}."
      vm = Utils.vm_by_id(vm_hash['ID'])
      vm.delete
    end
  end
end