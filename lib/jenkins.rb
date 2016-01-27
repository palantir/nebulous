require_relative './stages'
require_relative './errors'
require_relative './provisioner'
require 'jenkins_api_client'
require 'nokogiri'

class JenkinsProvisioner < Provisioner::ProvisionerType

  def initialize(configuration)
    super
    @jenkins_client = jenkins_client
    @jenkins_node_client = ::JenkinsApi::Client::Node.new(@jenkins_client)
  end

  def offline_delta
    delta = online_agent_ips.size - @configuration.min_pool_size
  end

  def online_agent_ips
    online_agent_ips =[]
    @jenkins_node_client.list.each do |agent_name|
      if agent_name.start_with?("#{@configuration.name}")
        agent_ip = agent_name.match(/(.+?)-(.+?)$/)[2]
        if !agent_disabled?(agent_name)
          online_agent_ips.push(agent_ip)
        end
      end
    end
    online_agent_ips
  end

  def jenkins_client
    jenkins = "#{@configuration.jenkins.chomp('/')}/"
    return ::JenkinsApi::Client.new(:username => @configuration.jenkins_username,
                              :password => @configuration.jenkins_password, :server_url => jenkins)
  end

  def agent_disabled?(agent_name)
    # All running machines have a progress bar object.
    data=`curl -s -u #{@configuration.jenkins_username}:#{@configuration.jenkins_password} #{@configuration.jenkins.chomp('/')}/computer/#{agent_name}/`
     if !data['progress-bar-done'] && data['Disconnected by']
        STDOUT.puts "Jenkins agent is offline and not running any jobs."
        return true
     end
     return false
  end

  ##
  # After provisioning perform the registration to jenkins.

  def registration(vm_hashes)
    vm_hashes.each do |vm_hash|
      agent_ip = vm_hash['TEMPLATE']['NIC']['IP']
      agent_name = "#{@configuration.name}-#{agent_ip}"
      @jenkins_node_client.create_dumb_slave({
        :name => agent_name, :remote_fs => '/home/jenkins',
        :description => "Bncl Agent",
        :slave_host => agent_ip, :private_key_file => @configuration.private_key_path,
        :executors => 1, :labels => @configuration.labels.join(", "), 
        :credentials_id => @configuration.credentials_id,
        :mode => @configuration.mode})
    end
  end
  
  def delete_agent(agent_name)
    begin
      @jenkins_client.delete(agent_name)
    rescue
      STDOUT.puts "Agent with name #{agent_name} did not exist."
    end
  end

  def take_offline?(vm)
    vm_ip = vm.to_hash['TEMPLATE']['NIC']['IP']
    list_agent_names = @jenkins_node_client.list(filter='#{vm_ip}')
    if list_agent_names.size > 1
      abort("Only delete one node at a time!")
    else
      agent_name = list_agent_names.first
      @jenkins_node_client.toggle_temporarilyOffline(agent_name, reason="Reaping old node.")
    end
  end
  
  ##
  # Reap all the agents that are taken offline on jenkins by BNCL and that exist on ON but not on jenkins.

  def reap_agents
    jenkins = @configuration.jenkins
    jenkins_username = @configuration.jenkins_username
    jenkins_password = @configuration.jenkins_password
    list_agent_names = jenkins_node_client.list
    offline_agent_ips = []
    online_agent_ips = []
    all_agent_ips = []

    # loop through agents and delete the ones that are offline. Store online/oflline in seperate lists
    list_agent_names.each do |agent_name|
      if agent_name.to_s.start_with?(@configuration.name)
        agent_ip = agent_name.match(/(.+?)-(.+?)$/)[2]
        if agent_disabled?(agent_name)
          delete_agent(agent_name)
          offline_agent_ips.push(agent_ip)
        else
          online_agent_ips.push(agent_ip)
        end
        all_agent_ips.push(agent_ip)
      end
    end

    # Find agents that are offline in jenkins and running on ON.
    garbage_agents = opennebula_state.select do |vm_hash|
      vm_ip = vm_hash['TEMPLATE']['NIC']['IP']
      offline_agent_ips.include?(vm_ip)
    end

    if garbage_agents.empty?
      STDOUT.puts "Did not find any offline agents that still exists on ON."
    end

    garbage_agents.each do |vm_hash|
      STDOUT.puts "Killing VM: #{vm_hash['NAME']}."
      vm = Utils.vm_by_id(vm_hash['ID'])
      vm.delete
    end
  end
end