require_relative './stages'
require_relative './errors'
require 'jenkins_api_client'
require 'nokogiri'

##
# Supertype for provisioners.

class Provisioner

  class ProvisionerType

    def initialize(configuration)
      @configuration = configuration
      configuration.provision.each_with_index {|stage, index| Stages.from_config(stage, index)}
    end

    ##
    # Just delegate to the configuration object because it has all the pieces to access
    # OpenNebula and perform the necessary comparisons and filtering.

    def opennebula_state
      @configuration.opennebula_state
    end

    ##
    # Must be defined in the subclass because it is going to override the delta calculation.

    def forked_provisioner
      raise ForkingProvisionerDefinitionError, "Must be defined in the subclass."
    end

    ##
    # By default the delta is the difference between the configured pool size and what currently exists in OpenNebula
    # but wrappers can override this method which can be used during forking to do the right thing.

    def delta
      required_pool_size = @configuration.count
      actual_pool_size = opennebula_state.length # TODO: Figure out whether we need to filter to just running VMs
      delta = required_pool_size - actual_pool_size
    end

    ##
    # Look at the current delta and generate the required number of forking provisioners.

    def partition(partition_size)
      (1..delta).each_slice(partition_size).map {|slice| forked_provisioner(slice.length)}
    end

    ##
    # Get the state and see if the delta is positive. If the delta is positive then instantiate that
    # many new servers so we can continue with the provisioning process by running the required scripts
    # through SSH. This should return just the VM data because we are going to use SSH to figure out if
    # they are up and running and ready for the rest of the process.

    def instantiate(vm_name_prefix = nil)
      if delta > 0
        STDOUT.puts "Pool delta: pool = #{@configuration.name}, delta = #{delta}."
        @configuration.instantiate!(delta, vm_name_prefix)
      else
        []
      end
    end

    ##
    # Required for most SSH commands.

    def ssh_prefix
      ['ssh', '-o UserKnownHostsFile=/dev/null',
        '-o StrictHostKeyChecking=no', '-o BatchMode=yes', '-o ConnectTimeout=20'].join(' ')
    end

    ##
    # We need to wait until we can reliably make SSH connections to each host and log any errors
    # for the hosts that are unreachable.

    def ssh_ready?(vm_hashes)
      ssh_test = lambda do |vm_hash|
        ip_address = vm_hash['TEMPLATE']['NIC']['IP']
        raise VMIPError, "IP not found: #{vm_hash}." if ip_address.nil?
        STDOUT.puts "Running #{ssh_prefix} root@#{ip_address} -t 'uptime'"
        system("#{ssh_prefix} root@#{ip_address} -t 'uptime'")
      end
      counter = 0
      while !vm_hashes.all? {|vm_hash| ssh_test.call(vm_hash)}
        counter += 1
        tries_left = 60 - counter
        STDOUT.puts "Couldn't connect to all agents. Will try #{tries_left} more times"
        break if counter > 60
        sleep 5
      end
      accumulator = []
      vm_hashes.each do |vm_hash|
        if ssh_test.call(vm_hash)
          STDOUT.puts "VM ready: #{vm_hash['NAME']}."
          accumulator << vm_hash
        else
          STDERR.puts "Unable to establish SSH connection to VM: #{vm_hash}."
        end
      end
      accumulator
    end

    ##
    # Look at the configuration and see what kinds of provisioning stages there are and
    # generate commands accordingly. Each stage can have multiple commands.

    def stages(provisioning_stages)
      provisioning_stages.each_with_index.map {|stage, index| Stages.from_config(stage, index)}
    end

    ##
    # For each VM generate the commands we are going to run and copy them over.

    def generate_ssh_commands(vm_hashes)
      stage_collection = Stages::StageCollection.new(*stages(@configuration.provision))
      stage_collection.generate_files
      vm_hashes.map do |vm|
        ip_address = vm['TEMPLATE']['NIC']['IP']
        STDOUT.puts "Generating commands for #{vm['NAME']}."
        stage_collection.scp_files(ip_address)
        stage_collection.final_command(ip_address)
      end
    end

    ##
    # Generate the SSH commands and then run them on each VM through SSH. Ignore keys and other stuff.
    # Input is an array of VM hashes that instantiate returns.

    def provision(vm_hashes)
      ready_vms = ssh_ready?(vm_hashes)
      final_commands = generate_ssh_commands(ready_vms)
      final_commands.each do |command| # All the commands for a VM
        STDOUT.puts "Running command: #{command}."
        system(command)
      end
    end

  end

  ##
  # Jenkins specific registration and garbage collection.

  class JenkinsProvisioner < ProvisionerType

    class ForkingProvisioner < JenkinsProvisioner

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
    end

    @@registration_wait_time = 30

    def forked_provisioner(delta)
      ForkingProvisioner.new(delta, @configuration)
    end

    ##
    # After provisioning perform the registration to jenkins.

    def registration(vm_hashes)
      jenkins_username = @configuration.jenkins_username
      jenkins_password = @configuration.jenkins_password
      jenkins = @configuration.jenkins
      private_key_path = @configuration.private_key_path
      credentials_id = @configuration.credentials_id
      labels = @configuration.labels
      client = ::JenkinsApi::Client.new(:username => jenkins_username,
                                        :password => jenkins_password, :server_url => jenkins)
      vm_hashes.each do |vm_hash|
        agent_ip = vm_hash['TEMPLATE']['NIC']['IP']
        agent_name = "agent - #{agent_ip}"
        node = ::JenkinsApi::Client::Node.new(client)
        node.create_dumb_slave({
          :name => agent_name, :remote_fs => '/home/jenkins',
          :description => "Ephemeral agent meant to run only 1 job and then die.",
          :slave_host => agent_ip, :private_key_file => private_key_path,
          :executors => 1, :labels => labels.join(", "), :credentials_id => credentials_id})
          sleep @@registration_wait_time
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

  ##
  # Enterprise Jenkins specific registration and garbage collection.

  class OCProvisioner < ProvisionerType

    class ForkingProvisioner < OCProvisioner

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
    end

    @@registration_wait_time = 30

    def forked_provisioner(delta)
      ForkingProvisioner.new(delta, @configuration)
    end

    ##
    # After provisioning perform the registration to jenkins.

    def registration(vm_hashes)
      STDOUT.puts "Registering shared slave to Jenkins OC."
      jenkins_username = @configuration.jenkins_username
      jenkins_password = @configuration.jenkins_password
      jenkins = @configuration.jenkins
      private_key_path = @configuration.private_key_path
      credentials_id = @configuration.credentials_id
      labels = @configuration.labels
      client = ::JenkinsApi::Client.new(:username => jenkins_username,
                                        :password => jenkins_password, :server_url => jenkins)
      vm_hashes.each do |vm_hash|
        agent_ip = vm_hash['TEMPLATE']['NIC']['IP']
        agent_name = "agent - #{agent_ip}"
        jobXml = File.open("slave.xml")
        doc = Nokogiri::XML(jobXml)
        host  = doc.at_css "host"
        host.content = agent_ip
        jobXml = doc.to_html
        job = ::JenkinsApi::Client::Job.new(client)
        begin
          job.create_or_update(agent_name, jobXml)
        rescue
          STDERR.puts $!, $@ # Print exception
          job.create_or_update(agent_name, jobXml) # Try one more time.
          next
        end
        STDOUT.puts "Registered Job Successfully"
          sleep @@registration_wait_time
      end
    end

    def deleteJobs(vm_hashes)
      STDOUT.puts "Deleting all jobs on Jenkins OC."
      jenkins_username = @configuration.jenkins_username
      jenkins_password = @configuration.jenkins_password
      jenkins = @configuration.jenkins
      private_key_path = @configuration.private_key_path
      credentials_id = @configuration.credentials_id
      labels = @configuration.labels
      client = ::JenkinsApi::Client.new(:username => jenkins_username,
                                        :password => jenkins_password, :server_url => jenkins)
      vm_hashes.each do |vm_hash|
        agent_ip = vm_hash['TEMPLATE']['NIC']['IP']
        agent_name = "agent - #{agent_ip}"
        #First disable job.
        jobXml = File.open("slave.xml")
        doc = Nokogiri::XML(jobXml)
        disabled  = doc.at_css "disabled"
        disabled.content = true
        jobXml = doc.to_html
        job = ::JenkinsApi::Client::Job.new(client)
        begin
          job.create_or_update(agent_name, jobXml)
        rescue
          STDERR.puts $!, $@ # Print exception
          job.create_or_update(agent_name, jobXml) # Try one more time.
          next
        end
        #delete job once disbaled.
        begin
          job.delete(agent_name) # delete job if exists
        rescue
          next
        end
        STDOUT.puts "Deleted Job Successfully"
        sleep @@registration_wait_time
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

  ##
  # Bamboo specific registration and garbage collection.

  class BambooProvisioner < ProvisionerType

    ##
    # Override delta to be a specific size.

    class ForkingProvisioner < BambooProvisioner

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
    end

    def forked_provisioner(delta)
      ForkingProvisioner.new(delta, @configuration)
    end

    ##
    # The agent based nature of Bamboo means we can do everything during provisioning
    # and registration is no-op.

    def registration(vm_hashes)
    end

    ##
    # Garbage collection through HTTP is a pain and we need to play nice with any other nodes on the same master that
    # are offline.

    def delete_offline_ephemeral(url)
      bamboo = @configuration.bamboo
      username = @configuration.bamboo_username
      password = @configuration.bamboo_password
      raw_info = `curl -b bamboo-cookies.txt -c bamboo-cookies.txt -s -u '#{username}':'#{password}' '#{url}'`
      raise BambooAgentInfoError, "Non-zero exit: #{url}." unless $?.exitstatus.zero?
      remove_endpoint = (bamboo[-1] == 47 || bamboo[-1] == '/') ?
        "#{bamboo}admin/agent/removeAgent.action?agentId=" : "#{bamboo}/admin/agent/removeAgent.action?agentId="
      if raw_info["ephemeral"] && raw_info["Offline"]
        agent_id = raw_info.match(/agentId=(\d+)/)[1]
        agent_remove_endpoint = remove_endpoint + agent_id
        STDOUT.puts "Remvoing agent: #{agent_remove_endpoint}."
        `curl -b bamboo-cookies.txt -c bamboo-cookies.txt -s -u '#{username}':'#{password}' '#{agent_remove_endpoint}'`
        return true
      end
      false
    end

    ##
    # Waiting for things to go offline can sometimes take too long so it is better to remove them when they are disabled?
    # TODO: This method and the above one are copies of each other and should be combined into one.

    def delete_disabled_ephemeral(url)
      bamboo = @configuration.bamboo
      username = @configuration.bamboo_username
      password = @configuration.bamboo_password
      raw_info = `curl -b bamboo-cookies.txt -c bamboo-cookies.txt -s -u '#{username}':'#{password}' '#{url}'`
      raise BambooAgentInfoError, "Non-zero exit: #{url}." unless $?.exitstatus.zero?
      remove_endpoint = (bamboo[-1] == 47 || bamboo[-1] == '/') ?
        "#{bamboo}admin/agent/removeAgent.action?agentId=" : "#{bamboo}/admin/agent/removeAgent.action?agentId="
      if raw_info["ephemeral"] && raw_info["(Disabled)"]
        agent_id = raw_info.match(/agentId=(\d+)/)[1]
        agent_remove_endpoint = remove_endpoint + agent_id
        STDOUT.puts "Remvoing agent: #{agent_remove_endpoint}."
        `curl -b bamboo-cookies.txt -c bamboo-cookies.txt -s -u '#{username}':'#{password}' '#{agent_remove_endpoint}'`
        return true
      end
      false
    end

    ##
    # Because there is lag in how disabled agents can sometimes be not disabled we need to really make sure that a disabled agent is disabled
    # the best I can think of is check 3 times and verify that each time the status was disabled. Sleep some seconds between each try.
    # TODO: There is a potential problem here. If we can not find the IP address then the count will not be 3 and we will consider it active
    # but we really want to consider it inactive. The problem is that without an IP address we can not reliably match things up on the OpenNebula side
    # so if an agent is epehemeral but does not have an IP address then we need to log that.

    @@disable_count_sleep = 60
    @@disabled_count_check = 3

    def verify_disabled(bamboo, bamboo_username, bamboo_password, endpoint)
      agent_url_ip_mapping = {}
      agent_disabled_counts = Hash.new {|h, k| h[k] = 0}
      (1..@@disabled_count_check).each do |i|
        agent_full_urls = get_agent_urls(bamboo, bamboo_username, bamboo_password, endpoint)
        agent_full_urls.reject! {|agent_url| offline_or_local?(agent_url, bamboo_username, bamboo_password)}
        agent_full_urls.map do |url|
          STDOUT.puts "Performing verification: #{url}."
          raw_info = `curl -b bamboo-cookies.txt -c bamboo-cookies.txt -s -u '#{bamboo_username}':'#{bamboo_password}' '#{url}'`
          raise BamgooAgentInfoError, "Problem during verification: #{url}." unless $?.exitstatus.zero?
          start_index = raw_info =~ /systemInfo_ipAddress/
            # See if we can even extract an IP address
            if start_index
              end_index = start_index + 400
              ip_slice = raw_info[start_index..end_index]
              ip_match = ip_slice.match(/(\d+(.\d+)+)/)
              STDOUT.puts "Agent: #{url}, #{ip_match}."
              ephemeral = raw_info["ephemeral"]
              disabled = raw_info["(Disabled)"]
              if disabled && ephemeral && ip_match
                STDOUT.puts "Agent is disabled and is ephemeral so should be considered inactive: #{ip_match}."
                agent_url_ip_mapping[url] = ip_match[1]
                agent_disabled_counts[url] += 1
              else
                STDOUT.puts "Agent is not disabled: #{url}, #{ip_match}, #{ephemeral}."
                agent_disabled_counts[url] -= 1
              end
            else
              STDERR.puts "Could not extract an IP address for agent: #{url}."
              agent_disabled_counts[url] -= 1
            end
        end
        puts "Sleeping #{@@disable_count_sleep}."
        sleep @@disable_count_sleep if i < @@disabled_count_check
      end
      agent_disabled_counts.each do |address, count|
        if count != @@disabled_count_check
          STDERR.puts "Verification count failure for agent: #{address}."
        end
      end
      return agent_disabled_counts, agent_url_ip_mapping
    end

    ##
    # Used to filter out offline agents from consideration for various tasks.

    def offline_or_local?(agent_url, bamboo_username, bamboo_password)
      raw_data = `curl -b bamboo-cookies.txt -c bamboo-cookies.txt -s -u '#{bamboo_username}':'#{bamboo_password}' '#{agent_url}'`
      raise BambooAgentInfoError, "Offline check failure: #{agent_url}." unless $?.exitstatus.zero?
      if raw_data["Offline"] || raw_data["(Local)"]
        STDOUT.puts "Agent offline or local agent so filtering it from consideration: #{agent_url}."
        return true
      end
      false
    end

    ##
    # Clean up all the offline agents until we reach a fixed point.

    def get_agent_urls(bamboo, bamboo_username, bamboo_password, endpoint)
      raw_data = `curl -b bamboo-cookies.txt -c bamboo-cookies.txt -s -u '#{bamboo_username}':'#{bamboo_password}' '#{endpoint}' | grep '/admin/agent/viewAgent.action?agentId='`
      unless $?.exitstatus.zero?
        STDERR.puts "Could not get agent data: #{endpoint}."
        `curl -b bamboo-cookies.txt -c bamboo-cookies.txt -s -u '#{bamboo_username}':'#{bamboo_password}' '#{endpoint}' > bamboo-agent-page.html`
        unless $?.exitstatus.zero?
          STDERR.puts "Can not access bamboo server. This is definitely a problem."
          raise BambooMasterServerError, "Could not access bamboo server: #{endpoint}."
        end
      end
      agent_urls = raw_data.split("</a>").map {|line| line.match(/href="(.+?)"/)}.reject(&:nil?).map {|m| m[1]}
      # We double count here so just get all the unique ones
      agent_full_urls = agent_urls.map {|url| (bamboo[-1] == 47 || bamboo[-1] == '/') ? "#{bamboo}#{url[1..-1]}" : "#{bamboo}#{url}"}.uniq
      initial_length = agent_full_urls.length
      STDOUT.puts "Cleaning up offline agents."
      agent_full_urls.reject! {|agent_url| STDOUT.puts "Checking offline status: #{agent_url}."; delete_offline_ephemeral(agent_url)}
      final_length = agent_full_urls.length
      if initial_length != final_length
        STDOUT.puts "Cleared out some offline ephemeral agents. Seeing if there are more to clean up."
        return get_agent_urls(bamboo, bamboo_username, bamboo_password, endpoint)
      end
      return agent_full_urls
    end

    @@job_summary_verification = 4
    @@job_summary_wait_time = 30

    ##
    # There is also a job summary page that seems to update more frequently so anything on that page that matches anything in the list of URLs
    # must be considered active so we have to add it to the set of agent urls

    def job_summary_verification(agent_urls, agent_url_template, bamboo, bamboo_username, bamboo_password)
      raise ArgumentError, "agent url template can not be nil." if agent_url_template.nil? && agent_urls.any?
      endpoint = ((l = bamboo[-1]) == 47 || l == '/') ?
        bamboo + 'build/admin/ajax/getDashboardSummary.action' : bamboo + '/build/admin/ajax/getDashboardSummary.action'
      # get the data X times Y seconds apart
      job_stats = (1..@@job_summary_verification).map do |i|
        raw_data = `curl -b bamboo-cookies.txt -c bamboo-cookies.txt -s -u '#{bamboo_username}':'#{bamboo_password}' '#{endpoint}'`
        json_data = JSON.parse(raw_data)
        STDOUT.puts raw_data
        puts "Sleeping #{@@job_summary_wait_time}."
        sleep @@job_summary_wait_time if i < @@job_summary_verification 
        json_data
      end
      agent_ids = job_stats.map do |job_data|
        builds = job_data['builds']
        ids = builds.map do |build|
          agent = build['agent']
          agent ? agent['id'].to_s : nil
        end
      end.flatten.reject(&:nil?).uniq
      STDOUT.puts "Found active agents on the job dashboard page: #{agent_ids.join(', ')}."
      # Anything that matches the IDs we just got is currently running a job so we have to add it to active agent list 
      agent_ids.each do |id|
        STDOUT.puts "Adding agent to active list because it was found on the job page: Agent ID = #{id}."
        agent_urls << agent_url_template.gsub(/agentId=\d+/, "agentId=#{id}") 
      end
      agent_urls.uniq!
    end

    ##
    # Scrape the bamboo agents to see which are still active and clean up the dead ones
    # on the OpenNebula side. Don't clean anything that is younger than 5 minutes.
    # Fail safely by exiting early if there is any chance that we might garbage collect an agent when we shouldn't.
    # There is no elegance here, just pure brute force. At the end of this process we are left with only the active agents
    # and we preserve those VMs on the OpenNebula side (modulo dumb race conditions on Bamboo's side).

    def garbage_collect
      bamboo = @configuration.bamboo
      bamboo_username = @configuration.bamboo_username
      bamboo_password = @configuration.bamboo_password
      endpoint = (bamboo[-1] == 47 || bamboo[-1] == '/') ?
        bamboo + 'agent/viewAgents.action' : bamboo + '/agent/viewAgents.action'
      STDOUT.puts "Agents endpoint: #{endpoint}."
      agent_url_template = (endpoint + "?agentId=123").sub('viewAgents', 'viewAgent')
      # We have removed local and offline agents at this point and can start counting how many times we see something down
      disabled_counts, agent_url_ip_mapping = *verify_disabled(bamboo, bamboo_username, bamboo_password, endpoint)
      # We reject all the agents that have a disabled count of @@disabled_count_check because we want at the end to be left with active agents
      agent_full_urls = agent_url_ip_mapping.keys
      agent_full_urls.reject! do |url|
        if (verification_count = disabled_counts[url]) == @@disabled_count_check
          STDOUT.puts "Agent down, removing from active set: down count = #{verification_count}, #{url}."
          true
        else
          STDOUT.puts "Agent up, keeping in active set: #{url}, verification count = #{verification_count}."
          false
        end
      end
      STDOUT.puts "Verification counts: #{disabled_counts}."
      # So we checked everything X times and whatever is left now has even higher chance of being active but we add back in anything that is on the job page
      job_summary_verification(agent_full_urls, agent_url_template, bamboo, bamboo_username, bamboo_password)
      # At this point we should only have the active agents so we ge the IP addresses of the active agents
      agent_ip_addrs = agent_full_urls.map do |url|
        raw_info = `curl -b bamboo-cookies.txt -c bamboo-cookies.txt -s -u '#{bamboo_username}':'#{bamboo_password}' '#{url}'`
        raise BambooAgentInfoError, "Could not get raw agent info: #{url}." unless $?.exitstatus.zero?
        if raw_info["Capabilities"].nil?
          STDERR.puts "Something went wrong when grabbing agent data: #{url}."
          raise BambooAgentPageSignatureError, "Unable to find signature on the page: #{raw_info}."
        end
        start_index = raw_info =~ /systemInfo_ipAddress/
          if start_index
            end_index = start_index + 400
            ip_slice = raw_info[start_index..end_index]
            ip_match = ip_slice.match(/(\d+(.\d+)+)/)
            STDOUT.puts "Agent IP address: #{ip_match}."
            # We only care about disabled agents that are ephemeral
            ephemeral = raw_info["ephemeral"]
            disabled = raw_info["(Disabled)"]
            want_ip = !(disabled && ephemeral)
            if disabled && ephemeral
              STDOUT.puts "Agent is disabled so should be considered inactive: #{ip_match}."
              nil
            else
              ip_match
            end
          else
            nil
          end
      end.reject(&:nil?).map {|m| m[1]}
      STDOUT.puts "Active agents: #{agent_ip_addrs.join(', ')}."
      epoch_now = Time.now.to_i
      time_for_dying = 60 * 60 * 12 # twelve hours old
      # First reject all the agents that we kinda know to be active and then from those find the ones that are older than 5 minutes and kill all of them
      garbage_agents = opennebula_state.reject do |vm_hash|
        vm_ip = vm_hash['TEMPLATE']['NIC']['IP']
        if agent_ip_addrs.include?(vm_ip)
          STDOUT.puts "Agent is active so keeping VM alive: #{vm_hash['NAME']}, IP = #{vm_ip}, ID = #{vm_hash['ID']}."
          true
        else
          false
        end
      end.select do |vm_hash|
        vm_start_time = Time.at(vm_hash['STIME'].to_i).to_i
        beyond_time_threshold = epoch_now - vm_start_time > time_for_dying # Old enough to die
      end
      # Whatever is left on the OpenNebula side after filtering out the active agents and the ones younger than X minutes is considered garbage
      # but we still do a whole bunch of checks just to make sure no other job is running on the agent
      garbage_agents.each do |vm_hash|
        vm_ip = vm_hash['TEMPLATE']['NIC']['IP']
        STDOUT.puts "Checking children of bamboo agent on #{vm_ip}."
        subtask = `#{ssh_prefix} root@#{vm_ip} -t 'while [[ $(ps aux | grep bamboo | grep -v grep | awk "{ print \$2 }" | xargs pgrep -P) ]]; do sleep 2; echo "Sub-task running"; done'`
        STDOUT.puts "Checking Bamboo process uptime on agent #{vm_ip}."
        process_uptime = `#{ssh_prefix} root@#{vm_ip} -t 'ps -eo pid,comm,etime,args | grep java | grep -v grep | sed "s/  */ /g" | cut -d " " -f 4'`
        if process_uptime.strip.match(/\d+/).nil?
          STDERR.puts "Could not find java process uptime on agent: #{vm_ip}."
        end
        STDOUT.puts "Java process uptime: #{process_uptime}."
        uptime_minutes = process_uptime.match(/(\d+):/)
        if uptime_minutes && uptime_minutes[1].to_i < 10 && process_uptime.split(":").length < 3
          puts "Java process has not been up for at least 10 minutes so not deleting agent: #{vm_ip}."
          next
        end
        STDOUT.puts "Making sure self-killer is not running: #{vm_ip}."
        `#{ssh_prefix} root@#{vm_ip} -t 'while [[ $(ps aux | grep "self-disable" | grep -v grep)]]; do sleep 60; echo "self killer running"; done'`
        STDOUT.puts "Stopping agent before killing VM: #{vm_ip}."
        `#{ssh_prefix} root@#{vm_ip} -t './bamboo-agent-home/bin/bamboo-agent.sh stop'` 
        STDOUT.puts "Making sure bamboo is stopped: #{vm_ip}."
        `#{ssh_prefix} root@#{vm_ip} -t 'while [[ $(ps aux | grep bamboo | grep -v grep) ]]; do sleep 2; echo "Bamboo still up"; done'`
        STDOUT.puts "Dumping cfg.xml file:"
        cfg_file = "cfg.xml"
        `#{ssh_prefix} root@#{vm_ip} -t 'cat ./bamboo-agent-home/bamboo-agent.cfg.xml' > #{cfg_file}`
        STDOUT.puts "Killing VM: #{vm_hash['NAME']}, #{vm_hash['ID']}, #{vm_ip}."
        vm = Utils.vm_by_id(vm_hash['ID'])
        vm.delete
      end
    end

  end

end
