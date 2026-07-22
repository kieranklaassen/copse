# frozen_string_literal: true

require "zlib"

require_relative "copse/version"
require_relative "copse/worktree"
require_relative "copse/session"

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

  # Boots the app. This is what `bin/dev` calls.
  #
  # Returns the exit status of the foreground process so `bin/dev` can propagate
  # it, which matters for shell `&&` chains and scripted use.
  def self.start(root: Dir.pwd)
    Session.new(Worktree.new(root)).start
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
