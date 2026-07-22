# Changelog

## 0.1.0 (unreleased)

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
- `bin/rails generate copse:install` wires up `bin/dev` and creates a minimal
  `Procfile.dev` only when the app has none.

### Notes

- Zero runtime dependencies. Foreman is invoked as a subprocess, never required,
  and is only needed for apps with non-`web` Procfile entries.
- Requires Ruby >= 3.2.0.
- Pipelines and background (`&`) Procfile lines cannot be made signal-transparent;
  Copse warns and leaves them alone. See the README.
