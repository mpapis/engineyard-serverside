require 'posix/spawn'
require 'engineyard-serverside/command_result'

module EY
  module Serverside
    # Our own little process spawning
    class Spawn
      READ_CHARS = 4096

      def self.spawn(cmd, out, err)
        new(cmd, out, err).call
      end

      attr_reader :status, :output

      def initialize(cmd, out, err)
        @cmd, @out, @err = cmd, out, err
        @output = ""
      end

      def call
        @pid, cin, @cout, @cerr = POSIX::Spawn.popen4(@cmd)
        cin.close unless cin.closed?

        catch(:eof) { read_loop }

        _, @status = Process.waitpid2(@pid)

        CommandResult.new(@cmd, @status.exitstatus, @output)
      ensure
        @cout.close if @cout && !@cout.closed?
        @cerr.close if @cerr && !@cerr.closed?
      end

      def read_loop
        while rv = IO.select([@cout, @cerr])
          ra, _, ea = *rv

          ra.each do |readio|
            case readio
            when @cout then read_into(readio, @out)
            when @cerr then read_into(readio, @err)
            else raise "unknown file descriptor from select"
            end
          end

          if @cout.eof? && @cerr.eof?
            throw :eof
          end
        end

        raise "select failed (timeout or bad file descriptor)"
      end

      def read_into(reader, writer)
        text = reader.read_nonblock(READ_CHARS)
        throw :eof if text.nil?
        @output << text
        writer << text
      rescue IO::WaitReadable
        # back to select, don't read again until select says to
      rescue EOFError, Errno::EIO
        # IO#eof? will catch these
      end
    end
  end
end
