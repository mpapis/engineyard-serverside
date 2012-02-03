module EY
  module Serverside
    class Task
      include Runnable

      attr_reader :config
      alias :c :config

      def initialize(conf)
        @config = conf
        @roles = :all
      end

      def require_custom_tasks
        deploy_file = ["config/eydeploy.rb", "eydeploy.rb"].map do |short_file|
          File.join(c.repository_cache, short_file)
        end.detect do |file|
          File.exist?(file)
        end

        if deploy_file
          puts "~> Loading deployment task overrides from #{deploy_file}"
          instance_eval(File.read(deploy_file))
          true
        else
          false
        end
      end

    end
  end
end
