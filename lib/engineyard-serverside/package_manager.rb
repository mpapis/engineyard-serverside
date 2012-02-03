module EY
  module Serverside
    module PackageManager
      def self.register(name, klass)
        @managers ||= {}
        @managers[name.to_sym] = klass
      end

      def self.resolve(config)
        manager = @managers.values.detect do |klass|
          klass.required?(config.release_path)
        end
        manager.new(config) if manager
      end

      def self.[](name)
        @managers and @managers[name.to_sym]
      end

      class Base
        include LoggedOutput
        include Runnable

        def initialize(config = nil)
          @config = config
        end

        def bundle
          roles :app_master, :app, :solo, :util do
            setup
            install unless installed?
            execute
          end
        end
      end

      Dir[File.expand_path('../package_manager/*.rb', __FILE__)].each {|manager| require manager}
    end
  end
end
