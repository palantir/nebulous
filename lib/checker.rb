require_relative './stages'
require_relative './errors'
require_relative './controller'

##
# Supertype for checkers.

class Checker
  
  class CheckerType < BnclController

    #make stages in provisioner   
    def initialize(configuration)
      @configuration = configuration
      configuration.check.each_with_index {|stage, index| Stages.from_config(stage, index)}
    end

    ##
    # For each VM generate the commands we are going to run and copy them over.

    def generate_ssh_commands(vm_hash)
      stage_collection = Stages::StageCollection.new(*stages(@configuration.check))
      stage_collection.generate_files
      ip_address = vm_hash['TEMPLATE']['NIC']['IP']
      STDOUT.puts "Generating check commands for #{vm_hash['NAME']} and IP #{ip_address}."
      stage_collection.scp_files(ip_address)
      STDOUT.puts "Running checks"
      stage_collection.final_command(ip_address)
    end
  end

  class JenkinsChecker < CheckerType

    class ForkingChecker < JenkinsChecker
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

    def forked_checkers(delta)
      ForkingChecker.new(delta, @configuration)
    end

  end

  ##
  # Enterprise Jenkins specific registration and garbage collection.

  class OperationCenterChecker < CheckerType

    class ForkingChecker < OperationCenterChecker
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

    def forked_checker(delta)
      ForkingChecker.new(delta, @configuration)
    end

  end

  ##
  # Bamboo specific registration and garbage collection.

  class BambooChecker < CheckerType
    ##
    # Override delta to be a specific size.
    class ForkingChecker < BambooChecker
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

    def forked_checker(delta)
      ForkingChecker.new(delta, @configuration)
    end
  end
end
