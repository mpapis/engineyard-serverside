module EY
  module Serverside
    module PackageManager
      class Bundler < Base

        #
        # check whether we need to use this manager
        #
        def self.required?(release_path)
          File.exist?("#{release_path}/Gemfile")
        end

        #
        # check whether the manager is installed
        #
        def installed?
          egrep_escaped_version = bundler_version.gsub(/\./, '\.')
          # the grep "bundler " is so that gems like bundler08 don't get
          # their versions considered too
          #
          # the [,$] is to stop us from looking for e.g. 0.9.2, seeing
          # 0.9.22, and mistakenly thinking 0.9.2 is there
          has_bundler_cmd = "gem list bundler | grep \"bundler \" | egrep -q '#{egrep_escaped_version}[,)]'"
          sudo has_bundler_cmd
        end

        #
        # install the package manager
        #
        def install
          clean_bundle_on_system_version_change
          sudo clean_environment
          sudo"gem install bundler -q --no-rdoc --no-ri -v '#{bundler_version}'"
        end

        #
        # setup and check further dependencies
        #
        def setup
          check_repository
          setup_sqlite3_if_necessary
          check_ey_config
        end

        #
        # execute the package manager command
        #
        def execute
          run "#{clean_environment} && cd #{@config.release_path} && ruby -S bundle _#{bundler_version}_ install #{bundler_config}"
          write_system_version
        end

        private

        #
        # repository and configuration checks
        #
        def check_repository
          info "~> Gemfile found."
          if lockfile
            info "~> Gemfile.lock found."
            unless lockfile.any_database_adapter?
              warning <<-WARN
Gemfile.lock does not contain a recognized database adapter.
A database-adapter gem such as mysql2, mysql, or do_mysql was expected.
This can prevent applications that use MySQL or PostreSQL from booting.

To fix, add any needed adapter to your Gemfile, bundle, commit, and redeploy.
Applications that don't use MySQL or PostgreSQL can safely ignore this warning.
              WARN
            end
          else
            warning <<-WARN
Gemfile.lock is missing!
You can get different versions of gems in production than what you tested with.
You can get different versions of gems on every deployment even if your Gemfile hasn't changed.
Deploying will take longer.

To fix this problem, commit your Gemfile.lock to your repository and redeploy.
            WARN
          end
        end

        #
        # check ey_config dependency
        #
        def check_ey_config
          if lockfile
            configured_services = @config.parsed_configured_services
            if !configured_services.empty? && !lockfile.has_ey_config?
              warning "Gemfile.lock does not contain ey_config. Add it to get EY::Config access to: #{configured_services.keys.join(', ')}."
            end
          end
        end

        def setup_sqlite3_if_necessary
          if lockfile && lockfile.uses_sqlite3?
            [
             ["Create databases directory if needed", "mkdir -p #{@config.shared_path}/databases"],
             ["Creating SQLite database if needed", "touch #{@config.shared_path}/databases/#{@config.framework_env}.sqlite3"],
             ["Create config directory if needed", "mkdir -p #{@config.release_path}/config"],
             ["Generating SQLite config", <<-WRAP],
cat > #{@config.shared_path}/config/database.sqlite3.yml<<'YML'
#{@config.framework_env}:
  adapter: sqlite3
  database: #{@config.shared_path}/databases/#{@config.framework_env}.sqlite3
  pool: 5
  timeout: 5000
YML
WRAP
             ["Symlink database.yml", "ln -nfs #{@config.shared_path}/config/database.sqlite3.yml #{@config.release_path}/config/database.yml"],
            ].each do |what, cmd|
              info "~> #{what}"
              run(cmd)
            end

            # FIXME: Is this actually necessary?
            owner = [@config.user, @config.group].join(':')
            info "~> Setting ownership to #{owner}"
            sudo "chown -R #{owner} #{@config.release_path}"
          end
        end

        def lockfile
          @lockfile_parse ||= begin
            lockfile_path = File.join(@config.release_path, "Gemfile.lock")
            File.exist?(lockfile_path) and LockfileParser.new(File.read(lockfile_path))
          end
        end

        def bundler_version
          lockfile ? lockfile.bundler_version : LockfileParser.default_version
        end

        def bundler_config
          options = "--gemfile #{@config.gemfile_path} --path #{@config.bundled_gems_path} --binstubs #{@config.binstubs_path} --without #{@config.bundle_without}"

          if lockfile
            options << ' --deployment' # deployment mode is not supported without a Gemfile.lock
          end

          options
        end

        def clean_bundle_on_system_version_change
          # diff exits with 0 for same and 1/2 for different/file not found.
          check_ruby   = "#{@config.ruby_version_command} | diff - #{@config.ruby_version_file} >/dev/null 2>&1"
          check_system = "#{@config.system_version_command} | diff - #{@config.system_version_file} >/dev/null 2>&1"
          say_cleaning = "echo 'New deploy or system version change detected, cleaning bundled gems.'"
          clean_bundle = "rm -Rf #{@config.bundled_gems_path}"

          run "#{check_ruby} && #{check_system} || (#{say_cleaning} && #{clean_bundle})"
        end

        def write_system_version
          store_ruby_version   = "#{@config.ruby_version_command} > #{@config.ruby_version_file}"
          store_system_version = "#{@config.system_version_command} > #{@config.system_version_file}"

          run "mkdir -p #{@config.bundled_gems_path} && #{store_ruby_version} && #{store_system_version}"
        end

        # GIT_SSH needs to be defined in the environment for customers with private bundler repos in their Gemfile.
        def clean_environment
          %Q[export GIT_SSH="#{ssh_executable}" && export LANG="en_US.UTF-8" && unset RUBYOPT BUNDLE_PATH BUNDLE_FROZEN BUNDLE_WITHOUT BUNDLE_BIN BUNDLE_GEMFILE]
        end

        # If we don't have a local version of the ssh wrapper script yet,
        # create it on all the servers that will need it.
        # TODO - This logic likely fails when people change deploy keys.
        def ssh_executable
          path = ssh_wrapper_path
          roles :app_master, :app, :solo, :util do
            run(generate_ssh_wrapper)
          end
          path
        end

        # We specify 'IdentitiesOnly' to avoid failures on systems with > 5 private keys available.
        # We set UserKnownHostsFile to /dev/null because StrickHostKeyChecking no doesn't
        # ignore existing entries in known_hosts; we want to actively ignore all such.
        # Learned this at http://lists.mindrot.org/pipermail/openssh-unix-dev/2009-February/027271.html
        # (Thanks Jim L.)
        def generate_ssh_wrapper
          path = ssh_wrapper_path
          identity_file = "~/.ssh/#{@config.app}-deploy-key"
  <<-WRAP
  [[ -x #{path} ]] || cat > #{path} <<'SSH'
  #!/bin/sh
  unset SSH_AUTH_SOCK
  ssh -o 'CheckHostIP no' -o 'StrictHostKeyChecking no' -o 'PasswordAuthentication no' -o 'LogLevel DEBUG' -o 'IdentityFile #{identity_file}' -o 'IdentitiesOnly yes' -o 'UserKnownHostsFile /dev/null' $*
  SSH
  chmod 0700 #{path}
  WRAP
        end

        def ssh_wrapper_path
          "#{@config.shared_path}/config/#{@config.app}-ssh-wrapper"
        end
      end

      register :bundler, Bundler
    end
  end
end
