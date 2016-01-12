require_relative './stages'
require_relative './errors'
require_relative './provisioner'

class BambooProvisioner < Provisioner::ProvisionerType

  def initialize(configuration)
    super
  end

  def registration(vm_hashes)
    vm_hashes.each do |vm_hash|
      vm_ip = vm_hash['TEMPLATE']['NIC']['IP']
      `#{ssh_prefix} root@#{vm_ip} -t "su - bamboo -c '/home/bamboo/bamboo-agent-home/bin/bamboo-agent.sh restart'"`
    end 
  end

  def job_running?(bamboo_username, bamboo_password, agent_url)
    `curl -b bamboo-cookies.txt -c bamboo-cookies.txt -s -u #{bamboo_username}:#{bamboo_password} #{agent_url} | grep 'icon-building-06.gif'`
    if $?.exitstatus.zero?
        return true
    end
    return false
  end

  def take_offline?(vm)
    vm_ip = vm_hash['TEMPLATE']['NIC']['IP']
    bamboo = @configuration.bamboo
    bamboo_username = @configuration.bamboo_username
    bamboo_password = @configuration.bamboo_password
    endpoint = (bamboo[-1] == 47 || bamboo[-1] == '/') ?
    bamboo + 'agent/viewAgents.action' : bamboo + '/agent/viewAgents.action'
    agent_url = get_single_agent_url(bamboo, bamboo_username, bamboo_password, endpoint, vm.to_hash['NAME'])
    # Query agent for 15 minutes at 30 sec intervals or until it is idle
    if !job_running?(bamboo_username, bamboo_password, agent_url)
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
      return true
    end
    return false
  end

  def verify_disabled(bamboo, bamboo_username, bamboo_password, endpoint)
  end

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

  ##
  # Clean up all the offline agents until we reach a fixed point.

  def get_single_agent_url(bamboo, bamboo_username, bamboo_password, endpoint, agent_name)
    raw_data = `curl -b bamboo-cookies.txt -c bamboo-cookies.txt -s -u '#{bamboo_username}':'#{bamboo_password}' '#{endpoint}' | grep '/admin/agent/viewAgent.action?agentId=' | grep #{agent_name}`
    unless $?.exitstatus.zero?
      STDERR.puts "Could not get agent data: #{endpoint}."
      `curl -b bamboo-cookies.txt -c bamboo-cookies.txt -s -u '#{bamboo_username}':'#{bamboo_password}' '#{endpoint}' > bamboo-agent-page.html`
      unless $?.exitstatus.zero?
        STDERR.puts "Can not access bamboo server. This is definitely a problem."
        raise BambooMasterServerError, "Could not access bamboo server: #{endpoint}."
      end
    end
    agent_url = raw_data.match(/href="(.+?)"/)
    return agent_url
  end

  ##
  # Scrape the bamboo agents to see which are still active and clean up the dead ones
  # on the OpenNebula side. Don't clean anything that is younger than 5 minutes.
  # Fail safely by exiting early if there is any chance that we might garbage collect an agent when we shouldn't.
  # There is no elegance here, just pure brute force. At the end of this process we are left with only the active agents
  # and we preserve those VMs on the OpenNebula side (modulo dumb race conditions on Bamboo's side).
  
  def reap_agents
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

    # First reject all the agents that we kinda know to be active and then from those find the ones that are older than 5 minutes and kill all of them
    garbage_agents = opennebula_state.reject do |vm_hash|
      vm_ip = vm_hash['TEMPLATE']['NIC']['IP']
      if agent_ip_addrs.include?(vm_ip)
        STDOUT.puts "Agent is active so keeping VM alive: #{vm_hash['NAME']}, IP = #{vm_ip}, ID = #{vm_hash['ID']}."
        true
      else
        false
      end
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

  def deleteJobs(vm_hashes)
    #TO-DO
  end

end