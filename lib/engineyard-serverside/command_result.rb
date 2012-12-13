module EY
  module Serverside
    class CommandResult
      attr_reader :command, :exitstatus, :output

      def initialize(command, exitstatus, output)
        @command, @exitstatus, @output = command, exitstatus, output
      end

      def success?
        exitstatus == 0
      end

      def inspect
        <<-EOM
$ #{command}
# => #{exitstatus})

#{output}
        EOM
      end
    end
  end
end
