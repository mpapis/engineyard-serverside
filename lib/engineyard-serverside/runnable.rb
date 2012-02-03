module EY
  module Serverside
    module Runnable
      def roles(*task_roles)
        raise "Roles must be passed a block" unless block_given?

        begin
          @roles = task_roles
          yield
        ensure
          @roles = :all
        end
      end

      # Returns +true+ if the command is successful,
      # raises EY::Serverside::RemoteFailure with a list of failures
      # otherwise.
      def run(cmd, &blk)
        run_on_roles(cmd, &blk)
      end

      def sudo(cmd, &blk)
        run_on_roles(cmd, %w[sudo sh -l -c], &blk)
      end

      private

      def run_on_roles(cmd, wrapper=%w[sh -l -c], &block)
        servers = EY::Serverside::Server.from_roles(@roles)
        futures = EY::Serverside::Future.call(servers, block_given?) do |server, exec_block|
          to_run = exec_block ? block.call(server, cmd.dup) : cmd
          server.run(Escape.shell_command(wrapper + [to_run]))
        end

        unless EY::Serverside::Future.success?(futures)
          failures = futures.select {|f| f.error? }.map {|f| f.inspect}.join("\n")
          raise EY::Serverside::RemoteFailure.new(failures)
        end
      end

    end
  end
end
