require_relative './stages'
require_relative './errors'
require_relative './provisioner'
require 'jenkins_api_client'
require 'nokogiri'
require 'securerandom'

class OperationCenterProvisioner < Provisioner::ProvisionerType

  class ForkingProvisioner < OperationCenterProvisioner

    def initialize(delta, configuration)
      @delta = delta
      super(configuration)
    end

    def delta
      @delta
    end

  end

  def initialize(configuration)
    super
    @jenkins_node_client = ::JenkinsApi::Client::Node.new(jenkins_client)
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

  def disable_state?(agent_url)
    `curl -u #{@configuration.jenkins_username}:#{@configuration.jenkins_password} #{agent_url} | grep 'Off-line (disabled)'`
     if $?.exitstatus.zero?
        STDOUT.puts "Agent is disabled."
        return true
     end
     return false
  end

  def disable_agent(agent_url)
      job = ::JenkinsApi::Client::Job.new(jenkins_client)
      agent_config_endpoint = agent_url + "/config.xml"
      jobXml = `curl -u #{@configuration.jenkins_username}:#{@configuration.jenkins_password} #{agent_config_endpoint}`
      doc = Nokogiri::XML(jobXml)
      disabled  = doc.at_css "disabled"
      disabled.content = true
      job_disabled = true
      jobXml = doc.to_html
      agent_name = agent_url.match('\/([^\/]+)\/$')[1]
      for counter in 0..20
        begin
          job.create_or_update(agent_name, jobXml)
          job_disabled = true
          break
        rescue
          STDERR.puts $!, $@ # Print exception
          sleep 5
          next
        end
      end
      if job_disabled
        STDOUT.puts "Disabled Job Successfully"
      else
        raise SharedSlaveNotUpdatedError, "Shared Slave not Disabled."
      end
  end

  def take_offline?(vm)
     ip=vm.to_hash['TEMPLATE']['NIC']['IP']
     list_node_urls.each do |url|
        STDOUT.puts "#{url}"
        if "#{url}".include?("#{ip}")
          STDOUT.puts "IP found #{ip}"
          url_endpoint=url.content
          disable_agent(url_endpoint)
          break
        end
      end
  end
  
  def list_node_urls
    nodes_url = @configuration.jenkins + "/api/xml"
    raw_data = `curl -u #{@configuration.jenkins_username}:#{@configuration.jenkins_password} -k #{nodes_url}`
    job_xml = Nokogiri::XML(raw_data)
    agent_urls = job_xml.xpath("//job//url")
    agent_urls
  end

  def online_agents
    online_agents = []
    list_node_urls.each do |url|
      if !disable_state?(url.content)
        agent_name = url.content.match('\/([^\/]+)\/$')[1]
        online_agents.push(agent_name)
      end
    end
    online_agents
  end

  def offline_agents
    offline_agents = []
    list_node_urls.each do |url|
      if disable_state?(url.content)
        agent_name = url.content.match('\/([^\/]+)\/$')[1]
        offline_agents.push(agent_name)
      end
    end
    offline_agents
  end
  ##
  # After provisioning perform the registration to jenkins.

  def registration(vm_hashes)
    STDOUT.puts "Registering shared slave to Jenkins Operation Center."
    vm_name = @configuration.name
    slave_label =@configuration.labels.join(' ')
    client = jenkins_client
    vm_hashes.each do |vm_hash|
      agent_ip = vm_hash['TEMPLATE']['NIC']['IP']
      agent_name = "#{vm_name}-#{agent_ip}"
      slave_uid = SecureRandom.uuid
      jobXml = File.open("slave.xml")
      doc = Nokogiri::XML(jobXml)
      host  = doc.at_css "host"
      host.content = agent_ip
      credentialsid = doc.at_css "credentialsId"
      credentialsid.content = @configuration.credentials_id
      uid  = doc.at_css "uid"
      uid.content = slave_uid
      label = doc.at_css "labelString"
      label.content = slave_label
      jobXml = doc.to_html
      job = ::JenkinsApi::Client::Job.new(client)
      job_created = false
      for counter in 0..20
        begin
          job.create_or_update(agent_name, jobXml)
          job_created = true
          break
        rescue
          STDERR.puts $!, $@ # Print exception
          sleep 5
          next
        end
      end
      if job_created
        STDOUT.puts "Registered Shared Slave Successfully"
      else
        raise SharedSlaveNotCreatedError, "Shared Slave not Created."
      end
    end
  end

  def delete_agents(agent_names)
    client = jenkins_client
    job = ::JenkinsApi::Client::Job.new(client)
    agent_names.each do |agent_name|
      STDOUT.puts "Deleting shared slave #{agent_name} on Jenkins."
      begin
        disable_agent("#{@configuration.jenkins}job/#{agent_name}/")
        job.delete(agent_name) # delete job if exists
      rescue
        next
      end
      STDOUT.puts "Deleted share slave successfully"
    end
  end

  def garbage_collect(offline_agents)
    jenkins = @configuration.jenkins
    jenkins_username = @configuration.jenkins_username
    jenkins_password = @configuration.jenkins_password

    # Find all the agents that are offline on jenkins and exist in ON
    garbage_agents = opennebula_state.select do |vm_hash|
      vm_ip = vm_hash['TEMPLATE']['NIC']['IP']
      agent_name = "#{@configuration.name}-#{vm_ip}"
      STDOUT.puts "Agent name: #{agent_name}"
      offline_agents.include?(agent_name)
    end
    if garbage_agents.empty?
      STDOUT.puts "Did not find any agents offline on Jenkins but exist on ON."
    end
    garbage_agents.each do |vm_hash|
      STDOUT.puts "Killing VM: #{vm_hash}."
      begin
        vm = Utils.vm_by_id(vm_hash['ID'])
        vm.delete
      rescue
        next
      end
    end
    # After deleting agents on ON side, remove on jenkins
    delete_agents(offline_agents)

    # Now find agents that exist on ON but no longer exists on Jenkins
    garbage_agents = opennebula_state.select do |vm_hash|
      vm_ip = vm_hash['TEMPLATE']['NIC']['IP']
      agent_name = "#{@configuration.name}-#{vm_ip}"
      STDOUT.puts "Agent name: #{agent_name}"
      !online_agents.include?(agent_name)
    end
    if garbage_agents.empty?
      STDOUT.puts "Did not find any agents on ON but don't exist on jenkins."
    end
    garbage_agents.each do |vm_hash|
      STDOUT.puts "Killing VM: #{vm_hash}."
      vm = Utils.vm_by_id(vm_hash['ID'])
      vm.delete
    end

    # Find all the agents that exist online on jenkins but not in ON, 
    # this should never happen though...
    if opennebula_state.size < (online_agents.size + offline_agents.size)
      opennebula_state.each do |vm_hash|
        on_ips = []
        on_ip = vm_hash['TEMPLATE']['NIC']['IP']
        on_ips.push(on_ip)
      end
      garbage_agents = online_agents.select do |agent_name|
        agent_ip = agent_name.match('([^-]+)$')[1]
        !on_ips.include?(agent_ip)
      end
      # After deleting agents on ON side, remove on jenkins

      delete_agents(garbage_agents)
    end
  end

end
