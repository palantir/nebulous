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
    super(configuration)
  end

  @@registration_wait_time = 30

  def forked_provisioner(delta)
    ForkingProvisioner.new(delta, @configuration)
  end

  ##
  # After provisioning perform the registration to jenkins.

  def registration(vm_hashes)
    STDOUT.puts "Registering shared slave to Jenkins Operation Center."
    jenkins_username = @configuration.jenkins_username
    jenkins_password = @configuration.jenkins_password
    jenkins = @configuration.jenkins
    credentials_id = @configuration.credentials_id
    private_key_path = @configuration.private_key_path
    labels = @configuration.labels
    client = ::JenkinsApi::Client.new(:username => jenkins_username,
                                      :password => jenkins_password, :server_url => jenkins)
    vm_hashes.each do |vm_hash|
      agent_ip = vm_hash['TEMPLATE']['NIC']['IP']
      agent_name = "agent-#{agent_ip}"
      slave_uid = SecureRandom.uuid
      jobXml = File.open("slave.xml")
      doc = Nokogiri::XML(jobXml)
      host  = doc.at_css "host"
      host.content = agent_ip
      credentialsid = doc.at_css "credentialsId"
      credentialsid.content = credentials_id
      uid  = doc.at_css "uid"
      uid.content = slave_uid
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
      sleep @@registration_wait_time
    end
  end

  def deleteJobs(vm_hashes)
    STDOUT.puts "Deleting all jobs on Jenkins."
    jenkins_username = @configuration.jenkins_username
    jenkins_password = @configuration.jenkins_password
    jenkins = @configuration.jenkins
    private_key_path = @configuration.private_key_path
    credentials_id = @configuration.credentials_id
    labels = @configuration.labels
    client = ::JenkinsApi::Client.new(:username => jenkins_username,
                                      :password => jenkins_password, :server_url => jenkins)
    vm_hashes.each do |vm_hash|
      counter = 0
      agent_ip = vm_hash['TEMPLATE']['NIC']['IP']
      agent_name = "agent-#{agent_ip}"
      #First disable job.
      jobXml = File.open("slave.xml")
      doc = Nokogiri::XML(jobXml)
      disabled  = doc.at_css "disabled"
      disabled.content = true
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
        STDOUT.puts "Disabled Job Successfully"
      else
        raise SharedSlaveNotCreatedError, "Shared Slave not Disabled."
      end
      begin
        job.delete(agent_name) # delete job if exists
      rescue
        next
      end
      STDOUT.puts "Deleted Job Successfully"
    end
  end
##
# Jenkins specific registration and garbage collection.

  def enableJobs(vm_hashes)
    STDOUT.puts "Re-enabling all jobs on Jenkins Operation Center."
    jenkins_username = @configuration.jenkins_username
    jenkins_password = @configuration.jenkins_password
    jenkins = @configuration.jenkins
    private_key_path = @configuration.private_key_path
    credentials_id = @configuration.credentials_id
    labels = @configuration.labels
    client = ::JenkinsApi::Client.new(:username => jenkins_username,
                                      :password => jenkins_password, :server_url => jenkins)
    vm_hashes.each do |vm_hash|
      counter = 0
      agent_ip = vm_hash['TEMPLATE']['NIC']['IP']
      agent_name = "agent-#{agent_ip}"
      #First disable job.
      jobXml = File.open("slave.xml")
      doc = Nokogiri::XML(jobXml)
      disabled  = doc.at_css "disabled"
      disabled.content = false
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
        STDOUT.puts "Enabled Job Successfully"
      else
        raise SharedSlaveNotCreatedError, "Shared Slave not Enabled."
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
      jenkins + 'getBncl/agents' : jenkins + '/getBncl/agents'
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