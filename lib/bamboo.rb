require_relative './stages'
require_relative './errors'
require_relative './provisioner'

class BambooProvisioner < Provisioner::ProvisionerType

  def initialize(configuration)
    super
  end

  def offline_delta
    delta = online_agent_ips_to_urls.size - @configuration.min_pool_size
  end

  # Map of all agents that are not disabled and ready to run jobs.
  def online_agent_ips_to_urls
    agent_urls = get_agent_urls
    online_agent_ips_to_urls = Hash.new
    bamboo_username = @configuration.bamboo_username
    bamboo_password = @configuration.bamboo_password
    agent_urls.each do |agent_url|
      raw_data = `curl -b bamboo-cookies.txt -c bamboo-cookies.txt -s -u #{bamboo_username}:#{bamboo_password} #{agent_url}`
      if !raw_data['(Disabled)'] && !raw_data['(will be disabled when build finishes)'] && raw_data[@configuration.name]
        doc = Nokogiri::HTML(raw_data)
        agent_ip = doc.xpath("//span[@id='systemInfo_ipAddress']").first.text
        online_agent_ips_to_urls[agent_ip] = agent_url
      end
    end
    return online_agent_ips_to_urls
  end

  # Returns a map of agents that are diabled and not running jobs.
  def deletable_agent_ips_to_urls
    agent_urls = get_agent_urls
    online_agent_ips_to_urls = Hash.new
    bamboo_username = @configuration.bamboo_username
    bamboo_password = @configuration.bamboo_password
    agent_urls.each do |agent_url|
      raw_data = `curl -b bamboo-cookies.txt -c bamboo-cookies.txt -s -u #{bamboo_username}:#{bamboo_password} #{agent_url}`
      if agent_disabled?(raw_data) && raw_data[@configuration.name]
        doc = Nokogiri::HTML(raw_data)
        agent_ip = doc.xpath("//span[@id='systemInfo_ipAddress']").first.text
        online_agent_ips_to_urls[agent_ip] = agent_url
      end
    end
    return online_agent_ips_to_urls
  end

  def agent_disabled?(raw_data)
    # Ensure that it is disabled and not running any jobs
    if raw_data['Idle'] && raw_data['(Disabled)'] && !raw_data['icon-building-06.gif']
      return true
    else
      return false
    end
  end

  def registration(vm_hashes)
    vm_hashes.each do |vm_hash|
      vm_ip = vm_hash['TEMPLATE']['NIC']['IP']
      `#{ssh_prefix} root@#{vm_ip} -t "su - bamboo -c '/home/bamboo/bamboo-agent-home/bin/bamboo-agent.sh restart'"`
    end 
  end

  def take_offline?(vm)
    vm_ip = vm.to_hash['TEMPLATE']['NIC']['IP']
    bamboo = @configuration.bamboo
    bamboo_username = @configuration.bamboo_username
    bamboo_password = @configuration.bamboo_password
    endpoint = (bamboo[-1] == 47 || bamboo[-1] == '/') ?
    bamboo + 'agent/viewAgents.action' : bamboo + '/agent/viewAgents.action'
    agent_url = get_single_agent_url(bamboo_username, bamboo_password, endpoint, vm.to_hash['NAME'])
    disable_endpoint = agent_url.gsub("admin\/agent\/viewAgent.action?","admin\/agent\/disableAgent.action?")
    `curl -b bamboo-cookies.txt -c bamboo-cookies.txt -s -u '#{bamboo_username}':'#{bamboo_password}' '#{disable_endpoint}'`
  end

  def get_agent_urls
    bamboo = @configuration.bamboo
    bamboo_username = @configuration.bamboo_username
    bamboo_password = @configuration.bamboo_password
    endpoint = (bamboo[-1] == 47 || bamboo[-1] == '/') ?
      bamboo + 'agent/viewAgents.action' : bamboo + '/agent/viewAgents.action'
    
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
    return agent_full_urls
  end

  ##
  # Clean up all the offline agents until we reach a fixed point.

  def get_single_agent_url(bamboo_username, bamboo_password, endpoint, agent_name)
    raw_data = `curl -b bamboo-cookies.txt -c bamboo-cookies.txt -s -u '#{bamboo_username}':'#{bamboo_password}' '#{endpoint}' | grep '/admin/agent/viewAgent.action?agentId=' | grep #{agent_name}`
    unless $?.exitstatus.zero?
      STDERR.puts "Could not get agent data: #{endpoint}."
      `curl -b bamboo-cookies.txt -c bamboo-cookies.txt -s -u '#{bamboo_username}':'#{bamboo_password}' '#{endpoint}' > bamboo-agent-page.html`
      unless $?.exitstatus.zero?
        STDERR.puts "Can not access bamboo server. This is definitely a problem."
        raise BambooMasterServerError, "Could not access bamboo server: #{endpoint}."
      end
    end
    agent_path = raw_data.match(/href="(.+?)"/)[1].to_s
    puts "endpoint #{endpoint}"
    agent_url = @configuration.bamboo.chomp('/') + agent_path
    puts "agent_url #{agent_url}"
    return agent_url
  end
  
  def reap_agents
    bamboo = @configuration.bamboo
    bamboo_username = @configuration.bamboo_username
    bamboo_password = @configuration.bamboo_password
    ips_to_url = deletable_agent_ips_to_urls
    # First reject all the agents that we kinda know to be active and then from those find the ones that are older than 5 minutes and kill all of them
    garbage_agents = opennebula_state.select do |vm_hash|
      vm_ip = vm_hash['TEMPLATE']['NIC']['IP']
      if ips_to_url.keys.include?(vm_ip)
        STDOUT.puts "Agent is deleteable: #{vm_hash['NAME']}, IP = #{vm_ip}, ID = #{vm_hash['ID']}."
        true
      else
        false
      end
    end
    # Whatever is left on the OpenNebula side after filtering out the active agents and the ones younger than X minutes is considered garbage
    # but we still do a whole bunch of checks just to make sure no other job is running on the agent
    garbage_agents.each do |vm_hash|
      vm_ip = vm_hash['TEMPLATE']['NIC']['IP']
      agent_url = ips_to_url[vm_ip]
      remove_endpoint = agent_url.gsub("admin\/agent\/viewAgent.action?","admin\/agent\/removeAgent.action?")
      `curl -b bamboo-cookies.txt -c bamboo-cookies.txt -s -u '#{bamboo_username}':'#{bamboo_password}' '#{remove_endpoint}'`
      vm = Utils.vm_by_id(vm_hash['ID'])
      vm.delete
    end
  end

end
