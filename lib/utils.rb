module Utils

  ON = ::OpenNebula

  ##
  # This operation comes up often enough in various classes that it should be a utility method.

  def self.vm_by_id(id)
    ON::VirtualMachine.new(ON::VirtualMachine.build_xml(id), client)
  end

  ##
  # Load the credentials and instantiate a client with those credentials.

  def self.client
    # Look at https://github.com/OpenNebula/one/blob/master/src/oca/ruby/opennebula/client.rb#L135
    # If endpoint is not provided then RPC endpoint will be picked up from various places
    # I personally like ENV['ONE_XMLRPC'] so it can be passed in as an environment variable
    # but ${HOME}/.one/one_auth is also good and the format is user:pass
    ON::Client.new(nil, nil, {:sync => true, :timeout => 30})
  end

end
