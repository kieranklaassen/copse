# Changelog

## Unreleased

- Adds an optional second naming mode: `<branch>.<project>.<machine>.local`,
  published over multicast DNS, instead of `<branch>.<project>.localhost`
  published to nobody. `.localhost` is a *SHOULD* that Safari on macOS ≤ 15 and
  bare-glibc Linux do not honour; `.local` is answered by the mDNS responder every
  desktop and phone already runs, and is answered for every device on the network
  — so the app can be opened from a phone. Opt in per machine with
  `COPSE_ZEROCONF=1`, or for a team with `Copse.start(zeroconf: true)`.
  One trade to know about: `.local` is not a secure context and `.localhost` is,
  so service workers, `getUserMedia`, geolocation, WebAuthn, `crypto.subtle` and
  the rest of the secure-context features stop working under it. See the README.
- The derived port is now a function of the `.localhost` hostname whatever mode is
  in use, so turning zeroconf naming on moves no port — not for the developer
  turning it on, and not against teammates who have not. Nothing changes for an
  app on `.localhost`.
- Exports `BINDING=0.0.0.0` and appends the advertised name to
  `RAILS_DEVELOPMENT_HOSTS`, on the zeroconf path only. A `.local` name resolves
  to this machine's network address rather than loopback, and Rails' development
  host allowlist covers `.localhost` and `.test` but not `.local`. An inherited
  `BINDING` wins, as does an explicit `-b` or a `bind` in `config/puma.rb`.
- `COPSE_SUBDOMAINS=jane,peter` (or `subdomains:`) publishes extra names under the
  app's own, for apps that serve one subdomain per tenant. Under `.localhost`
  every label resolves for free; mDNS answers only for names something announced.
- The names are withdrawn when the session ends. Under Overmind, which replaces
  Copse's process, the advertiser is forked into a process that watches Overmind's
  pid rather than being kept in a thread that the `exec` would destroy.
- The `zeroconf` gem (>= 1.2.0) stays an optional dependency and is required only
  when the mode is asked for. A machine without it says so in one line and boots
  on `.localhost`, the same fallback as a teammate without Overmind — and since
  the port does not move, the fallback costs the name and nothing else.

## 0.1.0 (2026-07-24)

First release.

- Derives a hostname per app and per git worktree: `<project>.localhost` for a
  main worktree, `<branch>.<project>.localhost` for a linked one, falling back to
  the directory name on a detached `HEAD` or outside git entirely.
- Derives a stable port from the hostname — `CRC32` indexed into `3000..9999`
  minus 25 well-known service ports. A pure function, identical across machines,
  terminals, reboots, and Ruby versions, with no stored state and no coordination.
- Runs the `web` process in the foreground with the terminal's stdin, stdout, and
  stderr, so `binding.irb` and `debug` work as they do under a bare
  `rails server`. Remaining `Procfile.dev` entries run under foreman and are
  terminated when the foreground process exits.
- Exports `PORT`, `COPSE_PORT`, `COPSE_HOST`, `COPSE_URL`, and `VITE_RUBY_PORT`.
  Non-`web` processes should read `COPSE_PORT`: foreman rewrites `PORT` per child.
- Sets `default_url_options` for routes and Action Mailer in development, only
  when Copse booted the app and only when the app has not set its own `host`.
- Gives a linked worktree its own development database, derived from the same slug
  as the hostname: `cora_development` becomes `cora_development_fix_billing`. A
  main worktree keeps the database it already has, and `config/database.yml` is
  never modified — the loaded configuration is renamed at boot. Development only;
  file-backed databases (SQLite) and entries marked `database_tasks: false` are
  left alone, replicas follow their primary, and names are capped at 63 bytes.
  Copse does not create the database: run `bin/rails db:prepare`. The suffix is
  derived from the checkout on disk rather than from Copse's own environment, so
  `db:prepare` and `bin/rails console` reach the same database as `bin/dev`, and
  a stale `COPSE_DATABASE_SUFFIX` cannot rename a main worktree's database.
- Exports `COPSE_DATABASE_SUFFIX` in a linked worktree, for other processes to
  read; Copse never reads it back. In a main worktree it is removed from the child
  environment, so a stale value inherited from another worktree's session cannot
  be believed there either.
- `bin/rails generate copse:install` wires up `bin/dev` and creates a minimal
  `Procfile.dev` only when the app has none.
- Supports Overmind as an alternative supervisor:
  `copse:install --process-manager=overmind` writes a `bin/dev` that hands the
  whole `Procfile.dev`, `web` included, to `overmind start` with the derived
  environment — no split session, because Overmind's per-process pty already
  keeps the debugger working. An app whose `bin/dev` already drives Overmind gets
  that variant by default rather than being downgraded to foreman. Overmind is
  probed at run time, so a teammate without it falls back to the foreman session.
  The derived port is passed to Overmind as `-p` and `OVERMIND_SKIP_ENV=1` is set,
  so no env file can beat it — the same reason foreman is given `--env /dev/null`.
- Warns when a Procfile entry runs the Tailwind CLI with a bare `--watch`, which
  exits when stdin closes and so ends the whole foreman session with status 0.

### Notes

- Zero runtime dependencies. Foreman is invoked as a subprocess, never required,
  and is only needed for apps with non-`web` Procfile entries.
- Requires Ruby >= 3.2.0.
- Pipelines and background (`&`) Procfile lines cannot be made signal-transparent;
  Copse warns and leaves them alone. See the README.
