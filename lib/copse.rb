# frozen_string_literal: true

require "zlib"

require_relative "copse/version"
require_relative "copse/url_options"
require_relative "copse/worktree"
require_relative "copse/database"
require_relative "copse/procfile"
require_relative "copse/session"
require_relative "copse/zeroconf"

# Copse gives every Rails app and every git worktree its own hostname and its
# own port, derived rather than assigned, so nothing collides and nothing has to
# be chosen.
module Copse
  # The port space derivation draws from.
  PORT_RANGE = (3000..9999).freeze

  # Well-known service ports inside PORT_RANGE. These are excluded from the
  # available set rather than probed around, so derivation stays a pure function
  # of the hostname -- a reserved port is unreachable by construction.
  #
  # Changing this list shifts every index in AVAILABLE_PORTS above the change and
  # therefore moves most derived ports. That is a breaking change to the promise
  # that teammates derive the same port (R4); it requires a major version bump.
  RESERVED_PORTS = [
    3036, # vite_ruby dev server default
    3306, # MySQL
    3389, # RDP
    4200, # Angular dev server
    4369, # Erlang EPMD
    5000, # macOS AirPlay Receiver, Flask
    5060, # SIP
    5173, # Vite default
    5432, # PostgreSQL
    5601, # Kibana
    5672, # RabbitMQ
    5900, # VNC
    6379, # Redis
    6432, # PgBouncer
    7000, # macOS AirPlay Receiver, Cassandra
    8000, # common alternate HTTP
    8025, # Mailhog / Mailpit web UI
    8080, # common alternate HTTP
    8443, # common alternate HTTPS
    8500, # Consul
    8888, # Jupyter
    9000, # PHP-FPM, SonarQube
    9092, # Kafka
    9200, # Elasticsearch
    9418  # git protocol
  ].freeze

  # The ordered set derivation indexes into. Frozen at load: there is no
  # configuration accessor, so there is no memoized state that can go stale.
  AVAILABLE_PORTS = (PORT_RANGE.to_a - RESERVED_PORTS).freeze

  # The supervisors `bin/dev` can be generated against. Only the supervisor
  # differs: the derivation is a pure function of the worktree and knows nothing
  # about either one.
  PROCESS_MANAGERS = %w[foreman overmind].freeze

  # Boots the app. This is what `bin/dev` calls.
  #
  # Returns the exit status of the foreground process so `bin/dev` can propagate
  # it, which matters for shell `&&` chains and scripted use.
  #
  # `process_manager: :overmind` hands the whole Procfile to Overmind instead,
  # replacing this process, and `args` is forwarded to it (`bin/dev -l web`).
  #
  # `zeroconf: true` publishes the derived hostname under `.local` over multicast
  # DNS instead of `.localhost`, for machines whose clients do not resolve
  # `.localhost` -- and for reaching the app from a phone. Left nil it follows
  # COPSE_ZEROCONF, so a single developer can opt in without editing the committed
  # `bin/dev`. `subdomains` names extra labels to publish under the app's own
  # hostname (`jane.cora.thicc.local`), for apps that serve several; it follows
  # COPSE_SUBDOMAINS the same way, and does nothing without zeroconf, where the
  # resolver answers for every label already.
  def self.start(root: Dir.pwd, process_manager: :foreman, args: [], zeroconf: nil, subdomains: nil,
                 out: $stdout)
    worktree, advertiser = derive(root: root, zeroconf: zeroconf, subdomains: subdomains, out: out)
    session = Session.new(worktree, out: out, advertiser: advertiser)

    # `exec_overmind` never returns, so falling through to the foreman session
    # means overmind is not installed *on this machine*. That is a fallback rather
    # than an error on purpose: `bin/dev` is committed, and a teammate without
    # overmind should still boot.
    session.exec_overmind(args) if process_manager.to_s == "overmind" && session.overmind_available?

    session.start
  end

  # The naming decision, split out of `start` so it can be tested without booting
  # anything. Returns the worktree and, when zeroconf naming is on, the advertiser
  # that will publish its hostname.
  #
  # A missing `zeroconf` gem is a fallback rather than an error, for the same
  # reason a missing overmind is: the request can come from a committed `bin/dev`,
  # and a machine that cannot honour it should still boot. The port is unchanged
  # by the fallback -- it is derived from the `.localhost` name either way -- so
  # what is lost is the name, not the session.
  def self.derive(root: Dir.pwd, zeroconf: nil, subdomains: nil, out: $stdout, env: ENV)
    return [Worktree.new(root), nil] unless Zeroconf.requested?(zeroconf, env: env)

    unless Zeroconf.available?
      out.puts "copse: zeroconf naming was asked for, but the `zeroconf` gem is not installed " \
               "for this Ruby. Add `gem \"zeroconf\"` to the development group. " \
               "Booting under .localhost instead."
      return [Worktree.new(root), nil]
    end

    worktree = Worktree.new(root, domain: Zeroconf.domain)
    hostnames = Zeroconf.hostnames(worktree.host, Zeroconf.subdomains(subdomains, env: env))
    [worktree, Zeroconf::Advertiser.new(hostnames, port: worktree.port, out: out)]
  end

  # The derived port for a hostname. A pure function: same hostname, same port,
  # on every machine, in every terminal, across reboots and Ruby versions.
  def self.port_for(hostname)
    AVAILABLE_PORTS.fetch(Zlib.crc32(hostname) % AVAILABLE_PORTS.size)
  end

  # A second port derived from the same hostname, for a JS bundler's own dev
  # server. Salting keeps it stable (R4) and inside the available set (so it can
  # never land on a reserved service port) while guaranteeing it differs from the
  # primary port for that same hostname.
  def self.companion_port_for(hostname)
    primary = port_for(hostname)
    index = Zlib.crc32("vite:#{hostname}") % AVAILABLE_PORTS.size
    candidate = AVAILABLE_PORTS.fetch(index)
    return candidate unless candidate == primary

    AVAILABLE_PORTS.fetch((index + 1) % AVAILABLE_PORTS.size)
  end
end

require_relative "copse/railtie" if defined?(Rails::Railtie)
