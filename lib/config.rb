require 'digest/sha1'
require 'opennebula'
require 'yaml'
require_relative './errors'

# All configuration loading and validation should happen here
class PoolConfig

  ##
  # Super type for configuration types.

  class ConfigurationType

    ON = ::OpenNebula # Need a shorter constant

    @@base_types = [String, Integer, Float, true.class, false.class]

    @@instantiation_wait_count = 300 # Try to see if the VM is running this many times before giving up

    ##
    # Go through the options hash and decrypt any secure values with the given key.

    def decrypt_secure_values(options, key)
      options.each do |k, v|
        case v
        when *@@base_types
          v
        when Array
          options[k] = decrypt_secure_array(v, key)
        when Hash
          if (s = v['secure'])
            options[k] = decrypt_secure_string(s, key)
          else
            options[k] = decrypt_secure_values(v, key)
          end
        else
          raise UnknownConfigurationKeyValueError, "Unknown yaml type: #{k}, #{v}."
        end
      end
    end

    ##
    # Iterate through the array and decrypt any secure values.

    def decrypt_secure_array(array, key)
      array.map do |v|
        case v
        when *@@base_types
          v
        when Array
          decrypt_secure_array(v, key)
        when Hash
          if (s = v['secure'])
            decrypt_secure_string(s, key)
          else
            decrypt_secure_values(v, key)
          end
        else
          raise UnknownConfigurationKeyValueError, "Unknown yaml type: #{k}, #{v}."
        end
      end
    end

    ##
    # Base case: decrypt value with public RSA key and return it. The assumption is that the string is base64 encoded.

    def decrypt_secure_string(str, key)
      key.public_decrypt(Base64.decode64(str))
    end

    ##
    # In some cases need to make sure there are no secure values because it will lead to hard to debug errors.

    def secure_values?(options)
      options.each do |k, v|
        case v
        when Array
          secure_array_values?(v)
        when Hash
          if v['secure']
            raise UnexpectedSecureValueError, "Unexpected secure value for key: #{k}. Please make sure you pass the decryption key for secure configurations"
          else
            secure_values?(v)
          end
        when *@@base_types
        else
          raise UnknownConfigurationKeyValueError, "Unknown yaml type: #{k}."
        end
      end
    end

    ##
    # Same as above but for arrays.

    def secure_array_values?(array)
      array.each do |v|
        case v
        when Array
          secure_array_values?(v)
        when Hash
          secure_values?(v)
        when *@@base_types
        else
          raise UnknownConfigurationKeyValueError, "Unknown yaml type: #{v}."
        end
      end
    end

    ##
    # Keep the raw hash around and then expose it through various methods.

    def initialize(options = {}, decryption_key_path)
      @options = options
      # If we have a key then load it and decrypt any secure values
      if decryption_key_path
        require 'openssl'
        require 'base64'
        key_content = File.read(File.expand_path(decryption_key_path))
        key = OpenSSL::PKey::RSA.new(key_content)
        decrypt_secure_values(@options, key)
      else # make sure there are no secure values because we didn't get a key
        secure_values?(@options)
      end
      # Dynamically define all the instance readers that are keys of the options hash
      @options.keys.each do |key|
        singleton_class.instance_eval do
          define_method(key.to_sym) do
            item = @options[key]
            if item.nil?
              raise NilConfigurationValueError, "Item is nil: #{key}."
            else
              item
            end
          end
        end
      end
    end

    def get_template_id
      templates = ON::TemplatePool.new(Utils.client)
      templates.info_all
      potential_templates = templates.to_hash['VMTEMPLATE_POOL']['VMTEMPLATE'].select {|info| info['NAME'].include?(template_name)}
      if potential_templates.length > 1
        raise SeveralTemplatesMatchesError, "The template name was not unique enough and several templates matched: #{potential_templates.map {|t| t['NAME']}.join(', ')}."
      end
      if potential_templates.empty?
        raise TemplateNotFoundError, "Could not find template with the given name: #{template_name}."
      end
      matched_template_id = potential_templates.first['ID'].to_i
      singleton_class.instance_eval do
        define_method(:template_id) do
          matched_template_id
        end
      end
      matched_template_id
    end

    ##
    # Make sure the right configuration parameters exist and show an error message if they don't.

    def validate
      configuration_items = self.class.class_variable_get(:@@configuration_items)
      missing = configuration_items.reduce([]) do |accumulator, item|
        if @options[item].nil?
          accumulator << item
        end
        accumulator
      end
      if missing.any?
        raise MissingConfigurationParameterError, "#{self.class} configuration error. Missing configuration parameters: #{missing.join(', ')}."
      end
      extra_items = @options.reject {|k, v| configuration_items.include?(k)}
      if extra_items.any?
        raise ExtraConfigurationParameterError, "Unknown configuration parameters found for configuration class #{self.class}: #{extra_items.keys.join(', ')}."
      end
    end

    ##
    # Wrap an existing configuration so that the +opennebula_state+ method returns the set of IP addresses that were provided on the command line.

    def synthetic(*ip_addresses)
      SyntheticConfigurationType.new(self, ip_addresses)
    end

    ##
    # Returns the Integer id of the user that is in ~/.one/one_auth.

    def auth_user_id
      auth_user = Utils.client.one_auth.split(':').first
      user_pool = ON::UserPool.new(Utils.client)
      user_pool.info
      auth_user_info = user_pool.to_hash['USER_POOL']['USER'].select {|u| u['NAME'] == auth_user}.first
      auth_user_info['ID'].to_i
    end

    ##
    # Try up to 10 times to get the state and then re-raise the exception if there was one.

    def opennebula_state
      counter = 0
      begin
        pool = ON::VirtualMachinePool.new(Utils.client, auth_user_id)
        result = pool.info
        if ON.is_error?(result)
          require 'pp'
          pp result
          raise PoolInformationError, "Unable to get pool information. Something is wrong with RPC endpoint."
        end
        vms = pool.to_hash['VM_POOL']['VM']
        everything = vms.nil? ? [] : (Array === vms ? vms : [vms])
        # Filter things down to just this pool
        everything.select do |vm|
          pool = vm['USER_TEMPLATE']['POOL']
          name_match = vm['NAME'].include?(name)
          if pool.nil?
            name_match
          else
            name_match && pool == name
          end
        end
      rescue Exception => ex
        STDERR.puts ex
        counter += 1
        raise if counter > 20
        sleep 5
        retry
      end
    end

    def hashify_vm_object(vm)
      h = vm.to_hash['VM']
      raise NilVMError, "Nil VM." if h.nil?
      h
    end

    ##
    # There is more error handling code than there is actual instantiation code so all of it
    # goes here. Best effort service here with a bunch of timeouts.

    def instantiation_error_handling(vm_objects)
      STDERR.puts "Verifying SSH connections."
      counter = 0
      # reject all failed vms
      run_state_tester = lambda do |vms|
        vms.reject! {|vm| vm.status.include?('fail')}
        vms.all? do |vm|
          vm.info
          vm.status.include?('run') || vm.status.include?('fail')
        end
      end
      while !run_state_tester[vm_objects]
        counter += 1
        if counter > @@instantiation_wait_count
          STDERR.puts "VMs did not transition to running state in the allotted time."
          STDERR.puts "Filtering results and returning running VMs so provisioning process can continue."
          running = []
          vm_objects.each do |vm|
            vm.info
            if vm.status.include?('run')
              running << hashify_vm_object(vm)
            else
              STDERR.puts "VM did not transition to running state: #{vm.to_hash}."
            end
          end
          return running # Just return whatever we can
        end
        sleep 5
      end
      vm_objects.map {|vm| hashify_vm_object(vm)} # Map to hashes and return
    end

    ##
    # Create the required number of VMs and return an array of hashes representing the VMs.
    # We need to wait until we have an IP address for each VM. Re-try 60 times with 1 second timeout for the VMs to be ready.

    def instantiate!(count, vm_name_prefix)
      raise ArgumentError, "Count must be positive." unless count > 0
      template_id = get_template_id
      template = ON::Template.new(ON::Template.build_xml(template_id), Utils.client)
      if ON.is_error?(template)
        raise OpenNebulaTemplateError, "Problem getting template with id: #{template_id}."
      end
      vm_objects = (0...count).map do |i|
        vm_name = vm_name_prefix ? "#{vm_name_prefix}-#{name}" : name
        actual_name = vm_name + '-' + Digest::SHA1.hexdigest(`date`.strip + i.to_s).to_s
        shortened_name = actual_name[0...38] # The entire host name must be less than 63 chars so this plus .itools.one.??? adds up
        vm_id = template.instantiate(shortened_name, false)
        STDOUT.puts "Got VM by id: #{vm_id}."
        vm = Utils.vm_by_id(vm_id)
        vm.update("pool=#{name}", true)
        vm.info
        vm.info!
        vm
      end
      # Unfortunate naming but this will return an array of hashes representing the VMs
      instantiation_error_handling(vm_objects)
    end

  end

  ##
  # Wrapper that fakes anything related to getting OpenNebula state to only return the set of IP addresses
  # that was used to instantiate it. This also means that deletion and other kinds of operations will not work.

  class SyntheticConfigurationType < ConfigurationType

    ##
    # The configuration we are wrapping and the list of IP addresses we are faking.

    def initialize(configuration, ip_addresses)
      @configuration = configuration
      @ip_addresses = ip_addresses
    end

  end

  ##
  # Contains configuration parameters for jenkins pools.

  class Jenkins < ConfigurationType

    @@configuration_items = ['name', 'type', 'count', 'template_name',
      'provision', 'jenkins', 'jenkins_username', 'jenkins_password',
      'credentials_id', 'private_key_path']

    def initialize(options = {}, decryption_key_path = nil) 
      super(options, decryption_key_path)
      validate
    end

    def provisioner
      Provisioner::JenkinsProvisioner.new(self)
    end

  end

  ##
  # Contains configuration parameters for bamboo pools.

  class Bamboo < ConfigurationType

    @@configuration_items = ['name', 'type', 'count', 'template_name',
      'provision', 'bamboo', 'bamboo_username', 'bamboo_password']

    def initialize(options = {}, decryption_key_path = nil)
      super(options, decryption_key_path)
      validate
    end

    def provisioner
      Provisioner::BambooProvisioner.new(self)
    end

  end

  ##
  # Load a yaml file, parse it, and create the right configuration instance

  def self.load(filepath, key_path = nil)
    raw_data = YAML.load(File.read(filepath))
    case (config_type = raw_data['type'])
    when 'jenkins'
      Jenkins.new(raw_data, key_path)
    when 'bamboo'
      Bamboo.new(raw_data, key_path)
    else
      raise UnknownConfigurationTypeError, "Unknown configuration type: #{config_type}."
    end
  end

end
