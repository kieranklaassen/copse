# frozen_string_literal: true

require "socket"

module Copse
  # An optional second naming mode, for machines where `.localhost` does not
  # resolve.
  #
  # `.localhost` is a *SHOULD* (RFC 6761 §6.3), so whether a name under it
  # resolves is up to each client -- Safari and `curl` on macOS 15 and earlier do
  # not, and neither does bare glibc. `.local` is the opposite: RFC 6762 reserves
  # it for multicast DNS, and every desktop and phone OS already runs a responder
  # for it. Nothing has to special-case the name, because the name is *answered*.
  #
  # The trade is that an answer has to come from somewhere. Under `.localhost`
  # Copse advertises nothing and binds nothing; here it publishes the derived
  # hostname over mDNS for as long as the session runs, and the server has to bind
  # a real interface rather than loopback -- so the app is reachable by every
  # device on the network, phones included. That is the feature (it is how you
  # open the app on a phone) and the cost (it is on the network).
  #
  # See https://blog.julik.nl/2025/05/dev-subdomains-with-zeroconf for the
  # technique this implements.
  module Zeroconf
    # RFC 6762's TLD. Not configurable: a name outside `.local` is not a name
    # multicast DNS will answer for.
    TLD = "local"

    # The DNS-SD service type a web UI advertises -- the same one a printer's
    # admin page uses, which is what makes the app show up in `dns-sd -B _http._tcp`
    # and in Bonjour browsers.
    SERVICE = "_http._tcp.#{TLD}.".freeze

    # Accepted as "yes" in COPSE_ZEROCONF. Anything else, including `0` and an
    # empty value, is no: the variable is likely to end up in a shell profile, and
    # `COPSE_ZEROCONF=0` must be a way to turn it off rather than a way to spell
    # "any value is truthy".
    TRUTHY = %w[1 true yes on].freeze

    # Whether zeroconf naming was asked for. An explicit argument -- `bin/dev`
    # passing `zeroconf: true` -- always wins; otherwise the environment decides.
    #
    # The environment matters more than it looks. `bin/dev` is committed and
    # shared, but which naming mode a developer needs is a property of *their
    # machine*: same repo, same branch, Chrome on Linux is fine with `.localhost`
    # and Safari on macOS 15 is not. COPSE_ZEROCONF is how one teammate opts in
    # from their shell profile without changing the file everyone else runs.
    def self.requested?(flag = nil, env: ENV)
      return !!flag unless flag.nil?

      TRUTHY.include?(env["COPSE_ZEROCONF"].to_s.strip.downcase)
    end

    # Whether the optional dependency is installed. Copse declares no runtime
    # dependencies, so this is a require rather than a constant check.
    def self.available?
      require "zeroconf"
      true
    rescue LoadError
      false
    end

    # `<machine>.local` -- the apex the derived name is published under.
    #
    # The machine's own name is in there deliberately. Two developers on one
    # network working on one repository derive the same `<branch>.<project>`, and
    # mDNS is a shared namespace: without this, whoever announced last would own
    # the name and the other's browser would land on a colleague's laptop.
    def self.domain(hostname = Socket.gethostname)
      "#{machine(hostname)}.#{TLD}"
    end

    # The machine's name as one DNS label. `Socket.gethostname` already returns
    # `thicc.local` on a Mac, so only the first label is kept -- appending `.local`
    # to a name that ends in it would publish `thicc.local.local`.
    def self.machine(hostname = Socket.gethostname)
      Worktree.slug(hostname.to_s.split(".").first) || "workstation"
    end

    # Extra names to publish alongside the app's own, for apps that serve several
    # subdomains (one per tenant, per site, per brand). Under `.localhost` these
    # cost nothing -- the resolver answers for every label -- but mDNS answers only
    # for names something announced, so each one has to be named here.
    #
    # Slugged through the same whitelist as a branch name: these arrive from an
    # environment variable and end up in a DNS record.
    def self.subdomains(list = nil, env: ENV)
      values = list || env["COPSE_SUBDOMAINS"].to_s.split(",")
      Array(values).filter_map { |value| Worktree.slug(value) }.uniq
    end

    # The full set of names to advertise: the app's own, plus one per subdomain.
    def self.hostnames(host, subdomains = [])
      [host, *subdomains.map { |subdomain| "#{subdomain}.#{host}" }]
    end

    # Publishes hostnames over multicast DNS for as long as the session runs, and
    # withdraws them when it ends.
    #
    # Each name is a separate announcement on its own thread, because that is the
    # shape the zeroconf gem offers: `Service#start` binds a socket and loops
    # answering queries until told to stop. The threads are pure IO -- they hold no
    # lock the web process cares about and spend their lives in `IO.select` -- so
    # they sit alongside the foreground `Process.waitpid` without contending with
    # it.
    class Advertiser
      # How long `start` waits for the announcements to actually go out. Only a
      # bound on a callback the gem fires once its socket is open; the normal case
      # is milliseconds. Waiting at all is what makes `stop` reliable -- a service
      # that has not started yet ignores it.
      START_TIMEOUT = 2

      # How long `stop` waits for a thread to leave its `IO.select` before killing
      # it. Either way the thread's `ensure` sends the goodbye packet that
      # withdraws the name; this only decides whether it does so on request.
      STOP_TIMEOUT = 2

      # How often the forked advertiser checks whether the process it was forked
      # from is still alive. See `fork_watching_parent`.
      PARENT_POLL = 1

      attr_reader :hostnames, :port

      def initialize(hostnames, port:, out: $stdout)
        @hostnames = Array(hostnames).uniq
        @port = port
        @out = out
        @services = []
        @threads = []
      end

      # Returns whether anything is being advertised. False is not fatal anywhere:
      # the app still boots and still answers on its port, it just cannot be
      # reached by name.
      def start
        return false unless Zeroconf.available?

        interfaces = ::ZeroConf.service_interfaces
        if interfaces.empty?
          @out.puts "copse: no multicast-capable network interface is up, so #{@hostnames.first} " \
                    "is not being advertised. The app is still on port #{port}."
          return false
        end

        announced = Queue.new
        @hostnames.each { |hostname| advertise(hostname, interfaces, announced) }
        await(announced)
        # Every announcement died on the spot -- each one has already said why.
        return false unless advertising?

        @out.puts "=> Copse: advertising #{@hostnames.join(', ')} over mDNS on " \
                  "#{interfaces.map { |iface| iface.addr.ip_address }.join(', ')}"
        true
      end

      def stop
        @services.each do |service|
          service.stop
        rescue StandardError
          # Never started, or already stopped. Either way there is nothing to
          # withdraw.
        end

        @threads.each { |thread| thread.kill unless thread.join(STOP_TIMEOUT) }
        @services.clear
        @threads.clear
      end

      def advertising? = @threads.any?(&:alive?)

      # Advertises from a forked child that outlives this process, for the Overmind
      # path -- which `exec`s, and threads do not survive an `exec`.
      #
      # The child watches its parent rather than being signalled by it, because
      # after the `exec` there is no Copse left to do the signalling. `exec`
      # preserves the pid, so the pid the child remembers is Overmind's; when
      # Overmind exits the child is reparented and `Process.ppid` changes, which is
      # the cue to withdraw the names and go. Ctrl-C gets there first in the usual
      # case: the child shares the terminal's foreground process group, so it takes
      # the same SIGINT, unwinds, and sends its goodbye packets.
      #
      # Returns the child's pid, or nil if this platform cannot fork.
      def fork_watching_parent
        return nil unless Process.respond_to?(:fork)

        parent = Process.pid
        fork do
          Signal.trap("TERM") { raise Interrupt }
          begin
            sleep PARENT_POLL while Process.ppid == parent if start
          rescue Interrupt
            # Ctrl-C, or the SIGTERM converted above.
          ensure
            stop
          end
        end
      end

      # mDNS service instance names may not contain dots -- the gem raises on one --
      # so the hostname is flattened into a single label. This is the name that
      # shows up in `dns-sd -B _http._tcp` and in Bonjour browsers; the hostname
      # itself keeps its dots and is what a browser is pointed at.
      def self.instance_name(hostname)
        hostname.tr(".", "-")[0, Worktree::LABEL_LIMIT]
      end

      private

      def advertise(hostname, interfaces, announced)
        service = ::ZeroConf::Service.new(
          SERVICE, port, hostname,
          instance_name: self.class.instance_name(hostname),
          service_interfaces: interfaces,
          started_callback: -> { announced << hostname }
        )
        @services << service

        @threads << Thread.new do
          # One clear line, never a backtrace. This is background work the
          # developer did not ask about by name, and a multicast socket giving up
          # must not read like an application error.
          Thread.current.report_on_exception = false
          service.start
        rescue StandardError => e
          @out.puts "copse: stopped advertising #{hostname}: #{e.message} (#{e.class})"
        end
      end

      # Waits for every announcement to report itself, or for the deadline, or for
      # every thread to have died -- whichever comes first. A thread that died
      # already printed its own line.
      def await(announced)
        deadline = Time.now + START_TIMEOUT
        @hostnames.size.times do
          remaining = deadline - Time.now
          break if remaining <= 0 || !advertising?

          announced.pop(timeout: remaining)
        end
      end
    end
  end
end
