# stolen wholesale from capistrano, thanks Jamis!
require 'base64'
require 'fileutils'
require 'json'
require 'engineyard-serverside/rails_asset_support'

module EY
  module Serverside
    class DeployBase < Task
      include LoggedOutput
      include ::EY::Serverside::RailsAssetSupport

      # default task
      def deploy
        debug "Starting deploy at #{Time.now.asctime}"
        update_repository_cache
        cached_deploy
      end

      def cached_deploy
        debug "Deploying app from cached copy at #{Time.now.asctime}"
        require_custom_tasks
        push_code

        info "~> Starting full deploy"
        copy_repository_cache

        with_failed_release_cleanup do
          create_revision_file
          run_with_callbacks(:bundle)
          setup_services
          symlink_configs
          conditionally_enable_maintenance_page
          run_with_callbacks(:migrate)
          run_with_callbacks(:compile_assets) # defined in RailsAssetSupport
          callback(:before_symlink)
          # We don't use run_with_callbacks for symlink because we need
          # to clean up manually if it fails.
          symlink
        end

        callback(:after_symlink)
        run_with_callbacks(:restart)
        disable_maintenance_page

        cleanup_old_releases
        debug "Finished deploy at #{Time.now.asctime}"
      rescue Exception
        debug "Finished failing to deploy at #{Time.now.asctime}"
        puts_deploy_failure
        raise
      end

      def restart_with_maintenance_page
        require_custom_tasks
        conditionally_enable_maintenance_page
        restart
        disable_maintenance_page
      end

      def enable_maintenance_page
        maintenance_page_candidates = [
          "public/maintenance.html.custom",
          "public/maintenance.html.tmp",
          "public/maintenance.html",
          "public/system/maintenance.html.default",
        ].map do |file|
          File.join(c.latest_release, file)
        end

        # this one is guaranteed to exist
        maintenance_page_candidates <<  File.expand_path(
          "default_maintenance_page.html",
          File.dirname(__FILE__)
          )

        # put in the maintenance page
        maintenance_file = maintenance_page_candidates.detect do |file|
          File.exists?(file)
        end

        @maintenance_up = true
        roles :app_master, :app, :solo do
          maint_page_dir = File.join(c.shared_path, "system")
          visible_maint_page = File.join(maint_page_dir, "maintenance.html")
          run Escape.shell_command(['mkdir', '-p', maint_page_dir])
          run Escape.shell_command(['cp', maintenance_file, visible_maint_page])
        end
      end

      def conditionally_enable_maintenance_page
        if c.migrate? || required_downtime_stack?
          enable_maintenance_page
        end
      end

      def required_downtime_stack?
        %w[ nginx_mongrel glassfish ].include? c.stack
      end

      def disable_maintenance_page
        @maintenance_up = false
        roles :app_master, :app, :solo do
          run "rm -f #{File.join(c.shared_path, "system", "maintenance.html")}"
        end
      end

      def run_with_callbacks(task)
        callback("before_#{task}")
        send(task)
        callback("after_#{task}")
      end

      # task
      def push_code
        info "~> Pushing code to all servers"
        futures = EY::Serverside::Future.call(EY::Serverside::Server.all) do |server|
          server.sync_directory(config.repository_cache)
        end
        EY::Serverside::Future.success?(futures)
      end

      # task
      def restart
        @restart_failed = true
        info "~> Restarting app servers"
        roles :app_master, :app, :solo do
          run(restart_command)
        end
        @restart_failed = false
      end

      def restart_command
        %{LANG="en_US.UTF-8" /engineyard/bin/app_#{c.app} deploy}
      end

      # task
      def bundle
        package_manager and package_manager.bundle
      end

      # task
      def cleanup_old_releases
        clean_release_directory(c.release_dir)
        clean_release_directory(c.failed_release_dir)
      end

      # Remove all but the most-recent +count+ releases from the specified
      # release directory.
      # IMPORTANT: This expects the release directory naming convention to be
      # something with a sensible lexical order. Violate that at your peril.
      def clean_release_directory(dir, count = 3)
        @cleanup_failed = true
        ordinal = count.succ.to_s
        info "~> Cleaning release directory: #{dir}"
        sudo "ls -r #{dir} | tail -n +#{ordinal} | xargs -I@ rm -rf #{dir}/@"
        @cleanup_failed = false
      end

      # task
      def rollback
        if c.all_releases.size > 1
          rolled_back_release = c.latest_release
          c.release_path = c.previous_release(rolled_back_release)

          revision = File.read(File.join(c.release_path, 'REVISION')).strip
          info "~> Rolling back to previous release: #{short_log_message(revision)}"

          run_with_callbacks(:symlink)
          sudo "rm -rf #{rolled_back_release}"
          bundle
          info "~> Restarting with previous release."
          with_maintenance_page { run_with_callbacks(:restart) }
        else
          info "~> Already at oldest release, nothing to roll back to."
          exit(1)
        end
      end

      # task
      def migrate
        return unless c.migrate?
        @migrations_reached = true
        roles :app_master, :solo do
          cmd = "cd #{c.release_path} && PATH=#{c.binstubs_path}:$PATH #{c.framework_envs} #{c.migration_command}"
          info "~> Migrating: #{cmd}"
          run(cmd)
        end
      end

      # task
      def copy_repository_cache
        info "~> Copying to #{c.release_path}"
        run("mkdir -p #{c.release_path} #{c.failed_release_dir} && rsync -aq #{c.exclusions} #{c.repository_cache}/ #{c.release_path}")

        info "~> Ensuring proper ownership."
        sudo("chown -R #{c.user}:#{c.group} #{c.deploy_to}")
      end

      def create_revision_file
        run create_revision_file_command
      end

      def services_command_check
        "which /usr/local/ey_resin/ruby/bin/ey-services-setup"
      end

      def services_setup_command
        "/usr/local/ey_resin/ruby/bin/ey-services-setup #{config.app}"
      end

      def setup_services
        info "~> Setting up external services."
        previously_configured_services = c.parsed_configured_services
        begin
          sudo(services_command_check)
        rescue StandardError => e
          info "Could not setup services. Upgrade your environment to get services configuration."
          return
        end
        sudo(services_setup_command)
      rescue StandardError => e
        unless previously_configured_services.empty?
          warning <<-WARNING
External services configuration not updated. Using previous version.
Deploy again if your services configuration appears incomplete or out of date.
#{e}
          WARNING
        end
      end


      def symlink_configs(release_to_link=c.release_path)
        info "~> Preparing shared resources for release."
        symlink_tasks(release_to_link).each do |what, cmd|
          info "~> #{what}"
          run(cmd)
        end
        owner = [c.user, c.group].join(':')
        info "~> Setting ownership to #{owner}"
        sudo "chown -R #{owner} #{release_to_link}"
      end

      def symlink_tasks(release_to_link)
        [
          ["Set group write permissions", "chmod -R g+w #{release_to_link}"],
          ["Remove revision-tracked shared directories from deployment", "rm -rf #{release_to_link}/log #{release_to_link}/public/system #{release_to_link}/tmp/pids"],
          ["Create tmp directory", "mkdir -p #{release_to_link}/tmp"],
          ["Symlink shared log directory", "ln -nfs #{c.shared_path}/log #{release_to_link}/log"],
          ["Create public directory if needed", "mkdir -p #{release_to_link}/public"],
          ["Create config directory if needed", "mkdir -p #{release_to_link}/config"],
          ["Create system directory if needed", "ln -nfs #{c.shared_path}/system #{release_to_link}/public/system"],
          ["Symlink shared pids directory", "ln -nfs #{c.shared_path}/pids #{release_to_link}/tmp/pids"],
          ["Symlink other shared config files", "find #{c.shared_path}/config -type f -not -name 'database.yml' -exec ln -s {} #{release_to_link}/config \\;"],
          ["Symlink mongrel_cluster.yml", "ln -nfs #{c.shared_path}/config/mongrel_cluster.yml #{release_to_link}/config/mongrel_cluster.yml"],
          ["Symlink database.yml", "ln -nfs #{c.shared_path}/config/database.yml #{release_to_link}/config/database.yml"],
          ["Symlink newrelic.yml if needed", "if [ -f \"#{c.shared_path}/config/newrelic.yml\" ]; then ln -nfs #{c.shared_path}/config/newrelic.yml #{release_to_link}/config/newrelic.yml; fi"],
        ]
      end

      # task
      def symlink(release_to_link=c.release_path)
        info "~> Symlinking code."
        run "rm -f #{c.current_path} && ln -nfs #{release_to_link} #{c.current_path} && chown -R #{c.user}:#{c.group} #{c.current_path}"
        @symlink_changed = true
      rescue Exception
        sudo "rm -f #{c.current_path} && ln -nfs #{c.previous_release(release_to_link)} #{c.current_path} && chown -R #{c.user}:#{c.group} #{c.current_path}"
        @symlink_changed = false
        raise
      end

      def callback(what)
        @callbacks_reached ||= true
        if File.exist?("#{c.release_path}/deploy/#{what}.rb")
          run Escape.shell_command(base_callback_command_for(what)) do |server, cmd|
            per_instance_args = [
              '--current-roles', server.roles.join(' '),
              '--config', c.to_json,
            ]
            per_instance_args << '--current-name' << server.name.to_s if server.name
            cmd << " " << Escape.shell_command(per_instance_args)
          end
        end
      end

      protected

      def starting_time
        @starting_time ||= Time.now
      end

      def base_callback_command_for(what)
        [serverside_bin, 'hook', what.to_s,
          '--app', config.app,
          '--release-path', config.release_path.to_s,
          '--framework-env', c.environment.to_s,
        ].compact
      end

      def serverside_bin
        basedir = File.expand_path('../../..', __FILE__)
        File.join(basedir, 'bin', 'engineyard-serverside')
      end

      def puts_deploy_failure
        if @cleanup_failed
          info "~> [Relax] Your site is running new code, but clean up of old deploys failed."
        elsif @maintenance_up
          info "~> [Attention] Maintenance page still up, consider the following before removing:"
          info " * Deploy hooks ran. This might cause problems for reverting to old code." if @callbacks_reached
          info " * Migrations ran. This might cause problems for reverting to old code." if @migrations_reached
          if @symlink_changed
            info " * Your new code is symlinked as current."
          else
            info " * Your old code is still symlinked as current."
          end
          info " * Application servers failed to restart." if @restart_failed
          info ""
          info "~> Need help? File a ticket for support."
        else
          info "~> [Relax] Your site is still running old code and nothing destructive has occurred."
        end
      end

      def with_maintenance_page
        conditionally_enable_maintenance_page
        yield if block_given?
        disable_maintenance_page
      end

      def with_failed_release_cleanup
        yield
      rescue Exception
        info "~> Release #{c.release_path} failed, saving release to #{c.failed_release_dir}."
        sudo "mv #{c.release_path} #{c.failed_release_dir}"
        raise
      end

      def package_manager
        @manager ||= EY::Serverside::PackageManager.resolve(c)
      end
    end   # DeployBase

    class Deploy < DeployBase
      def self.new(config)
        # include the correct fetch strategy
        include EY::Serverside::Strategies.const_get(config.strategy)::Helpers
        super
      end
    end
  end
end
