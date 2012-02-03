module EY
  module Serverside
    module PackageManager
      class Npm < Base

        #
        # check whether we need to use this manager
        #
        def self.required?(release_path)
          File.exist?("#{release_path}/package.json")
        end

        #
        # check whether the manager is installed
        #
        def installed?
          run('which npm 2>&1')
        end

        #
        # install the package manager
        #
        def install
          run('curl http://npmjs.org/install.sh | sh')
        end

        #
        # setup and check further dependencies
        #
        def setup
          check_ey_config
        end

        #
        # execute the package manager command
        #
        def execute
          run "cd #{@config.release_path} && npm install"
        end

        private

        def check_ey_config
          require 'json'
          json = JSON.parse("#{@config.release_path}/package.json")
          configured_services = @config.parsed_configured_services
          if !configured_services.empty? && !json['dependencies'].keys.include?('ey_config')
            warning "package.json does not contain ey_config. Add it to get EYConfig access to: #{configured_services.keys.join(', ')}."
          end
        end
      end

      register :npm, Npm
    end
  end
end

