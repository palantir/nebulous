require_relative './stages'
require_relative './errors'
require_relative './provisioner'
require 'jenkins_api_client'
require 'nokogiri'
require 'securerandom'

class OperationCenterProvisioner < Provisioner::ProvisionerType

  def initialize(configuration)
    super
    @jenkins_client = jenkins_client
  end

  def offline_delta
    delta = online_agent_names.size - @configuration.min_pool_size
  end

  ##
  # Instantiating a jenkins client is verbose, so let's just do it once.

  def jenkins_client
    jenkins = "#{@configuration.jenkins.chomp('/')}/"
    return ::JenkinsApi::Client.new(:username => @configuration.jenkins_username,
                              :password => @configuration.jenkins_password, :server_url => jenkins)
  end

  ##
  # A curl request is the safest way to ensure that the agent is disabled
  # and not running any jobs.

  def agent_disabled?(agent_url)
    `curl -s -u #{@configuration.jenkins_username}:#{@configuration.jenkins_password} #{agent_url} | grep 'Off-line (disabled)'`
     if $?.exitstatus.zero?
        STDOUT.puts "#{agent_url} on OC jenkins is disabled and not running any jobs."
        return true
     end
     STDOUT.puts "#{agent_url} on OC jenkins is not disabled."
     return false
  end

  ##
  # Disable agent on jenkins.

  def disable_agent(agent_url)
    job = ::JenkinsApi::Client::Job.new(@jenkins_client)
    agent_config_endpoint = agent_url + "/config.xml"
    jobXml = `curl -u #{@configuration.jenkins_username}:#{@configuration.jenkins_password} #{agent_config_endpoint}`
    doc = Nokogiri::XML(jobXml)
    disabled  = doc.at_css "disabled"
    disabled.content = true
    job_disabled = true
    jobXml = doc.to_html
    agent_name = agent_url.match('\/([^\/]+)\/$')[1]
    begin
      job.create_or_update(agent_name, jobXml)
    rescue
      STDERR.puts $!, $@ # Print exception
      sleep 5
    end
  end

  ##
  # Find the agent that is tied to the ON VM and take it offline.

  def take_offline?(vm)
    vm_ip = vm.to_hash['TEMPLATE']['NIC']['IP']
    list_agent_urls.each do |url|
      if "#{url}".include?("#{vm_ip}")
        STDOUT.puts "Attempting to disable agent at #{url}."
        url_endpoint = url.content
        disable_agent(url_endpoint)
        break
      end
    end
  end
  
  ##
  # List the urls that we can use to access the agents individually.

  def list_agent_urls
    nodes_url = @configuration.jenkins + "/api/xml"
    raw_data = `curl -s -u #{@configuration.jenkins_username}:#{@configuration.jenkins_password} -k #{nodes_url}`
    job_xml = Nokogiri::XML(raw_data)
    agent_urls = job_xml.xpath("//job//url").select{ |k| k.to_s.include?("#{@configuration.name}")}
  end

  ##
  # Get the name of the offline agents. Agent names play nicely with the jenkins api 
  # as they are the same class as jobs.

  def online_agent_names
    online_agents = []
    list_agent_urls.each do |url|
      if !agent_disabled?(url.content)
        agent_name = url.content.match('\/([^\/]+)\/$')[1]
        online_agents.push(agent_name)
      end
    end
    online_agents
  end

  def offline_agent_names
    offline_agents = []
    list_agent_urls.each do |url|
      if agent_disabled?(url.content)
        agent_name = url.content.match('\/([^\/]+)\/$')[1]
        offline_agents.push(agent_name)
      end
    end
    offline_agents
  end
  
  ##
  # After provisioning agents successfully perform the registration to jenkins.

  def registration(vm_hashes)
    STDOUT.puts "Registering shared slave to Jenkins Operation Center."
    vm_hashes.each do |vm_hash|
      agent_ip = vm_hash['TEMPLATE']['NIC']['IP']
      agent_name = "#{@configuration.name}-#{agent_ip}"
      slave_uid = SecureRandom.uuid
      jobXml = File.open("slave.xml")
      doc = Nokogiri::XML(jobXml)
      host  = doc.at_css "host"
      host.content = agent_ip
      credentialsid = doc.at_css "credentialsId"
      credentialsid.content = @configuration.credentials_id
      mode = doc.at_css "mode"
      mode.content = @configuration.mode
      uid  = doc.at_css "uid"
      uid.content = slave_uid
      label = doc.at_css "labelString"
      label.content = @configuration.labels.join(' ')
      jobXml = doc.to_html
      job = ::JenkinsApi::Client::Job.new(@jenkins_client)
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

  def delete_agents_from_jenkins(agent_names)
    job = ::JenkinsApi::Client::Job.new(@jenkins_client)
    offline_agents = []
    agent_names.each do |agent_name|
      STDOUT.puts "Deleting shared slave #{agent_name} on Jenkins."
      begin
        disable_agent("#{@configuration.jenkins}/job/#{agent_name}/")
        job.delete(agent_name) # delete job if exists
      rescue
        next
      end
      STDOUT.puts "Deleted share slave successfully"
    end
  end

  ##
  # Find all the agents that are offline and delete them on jenkins and on ON

  def reap_agents
    online_agents = online_agent_names
    offline_agents = offline_agent_names

    # Find all the agents that are offline on jenkins and exist in ON
    garbage_agents = opennebula_state.select do |vm_hash|
      vm_ip = vm_hash['TEMPLATE']['NIC']['IP']
      agent_name = "#{@configuration.name}-#{vm_ip}"
      STDOUT.puts "Checking if #{agent_name} is offline"
      offline_agents.include?(agent_name)
    end

    if garbage_agents.empty?
      STDOUT.puts "Did not find any agents offline on Jenkins but exist on ON."
    end

    garbage_agents.each do |vm_hash|
      STDOUT.puts "Killing VM: #{vm_hash['NAME']}."
      vm = Utils.vm_by_id(vm_hash['ID'])
      vm.delete
    end
    # After deleting agents on ON side, remove on jenkins
    delete_agents_from_jenkins(offline_agents)

    # Now find agents no longer exists on Jenkins that exist on ON
    garbage_agents = opennebula_state.select do |vm_hash|
      vm_ip = vm_hash['TEMPLATE']['NIC']['IP']
      agent_name = "#{@configuration.name}-#{vm_ip}"
      STDOUT.puts "Checking id agent #{agent_name} exists on Jenkins"
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
  end

end