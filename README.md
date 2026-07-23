# Copse

A hostname and a port for every Rails app and every git worktree — while the debugger keeps working.

```
~/code/cora             on main         →  http://cora.localhost:5368
~/code/cora-fix-billing on fix-billing  →  http://fix-billing.cora.localhost:4783
~/code/other-app        on main         →  http://other-app.localhost:8119
```

Derived from the directory name and the branch, so nothing collides and nothing has to be chosen. No daemon, no reverse proxy, no privileged listener, zero runtime dependencies.

## Installation

```ruby
group :development do
  gem "copse"
end
```

```sh
bundle install
bin/rails generate copse:install
bin/dev
```

The generator writes a `bin/dev` that calls Copse, and creates `Procfile.dev` only if you don't have one. An existing `Procfile.dev` is never modified; an existing `bin/dev` is copied to `bin/dev.before-copse` first.

Already on [Overmind](https://github.com/DarthSim/overmind)? The generator sees it in your `bin/dev` and keeps it. Ask for either supervisor explicitly with `--process-manager=overmind` or `--process-manager=foreman`.

## Why

Two apps both want port 3000, so you hand-assign `-p 3001` and then forget which app owns which number — and your teammates picked different ones. Worse, everything lands on `localhost`, so every app shares one cookie jar and one `localStorage`: signing into one signs you out of another.

The hostname is not routing traffic. It gives each app a distinct **browser origin**, which is the half that fixes the cookie jar, and that needs no listener.

### Versus puma-dev

[puma-dev](https://github.com/puma/puma-dev) gives you a bare `https://app.test` with no port. It buys that by running your app as a background daemon, which takes the web process off your terminal — and `binding.irb` with it. Rails' own `bin/dev` stays local but multiplexes stdin through foreman, which breaks the debugger too ([rails/rails#52459](https://github.com/rails/rails/issues/52459)).

Copse runs `web` in the foreground, holding your terminal's stdin and process group; everything else in `Procfile.dev` goes to foreman. The trade is explicit: **you keep the `:5368`.** If a bare hostname matters more than your debugger, use puma-dev.

## Names

| Where you are | Hostname |
|---|---|
| Main worktree | `<project>.localhost` |
| Linked worktree | `<branch>.<project>.localhost` |
| Linked worktree, detached `HEAD` | `<directory>.<project>.localhost` |
| Not a git repository | `<directory>.localhost` |

`<project>` is always the **main** worktree's directory name, so `~/code/cora-fix-billing` on `fix-billing` is `fix-billing.cora.localhost`, not `cora-fix-billing.cora.localhost`.

Names reduce to one DNS label: lowercased, anything outside `[a-z0-9]` collapsed to `-`, capped at 63 characters. `feat/billing-v2` → `feat-billing-v2`. It's a whitelist, not a substitution — git permits `;`, `$(`, and quotes in branch names, and the result reaches your environment and a generated Procfile.

## Ports

`CRC32(hostname)` indexed into `3000..9999` minus 25 well-known service ports. A pure function: same hostname, same port, on every machine and across reboots and Ruby versions, with no stored state and no coordination.

Uncoordinated means collisions are possible. Measured over 20,000 seeded trials against 6,975 available ports:

| Worktrees at once | Chance two share a port |
|---|---|
| 10 | ~0.6% |
| 10, using Vite | ~2.5% |
| 40 | ~10% |

Vite doubles it because a Vite app draws two ports. On a collision Copse names the port and the hostname instead of leaving you with Puma's bare `Address already in use`; rename a worktree or branch to fix it.

Changing the range or the reserved list would move nearly every derived port, so it's a breaking change gated by a test that pins the whole set.

## Environment

| Variable | Value |
|---|---|
| `COPSE_HOST` | `cora.localhost` |
| `COPSE_URL` | `http://cora.localhost:5368` |
| `COPSE_PORT` | the derived port |
| `PORT` | the derived port — **`web` process only** |
| `VITE_RUBY_PORT` | the derived companion port |

**In a non-`web` process, read `COPSE_PORT`, not `PORT`.** Foreman assigns its children `base_port + index * 100`, so a secondary's `PORT` is a number Copse never derived. Copse deliberately hands foreman an offset base, so no secondary is ever given the `web` process's own port.

In development Copse also sets `default_url_options` for routes and Action Mailer. It stays out of the way otherwise: not in other environments, not under a plain `bin/rails server`, and not when your app set its own `host`. Puma still prints `Listening on http://127.0.0.1:5368` — that's the address it bound; Copse's line is the name to visit.

`VITE_RUBY_PORT` is picked up by `vite_ruby` automatically. Vite is the only bundler that needs it: esbuild via `jsbundling-rails`, `cssbundling-rails`, `tailwindcss-rails`, Propshaft, and importmap have no port at all.

## foreman

Needed only if `Procfile.dev` has anything besides a `web` line:

```ruby
gem "foreman", group: :development
```

Teardown is verified against **0.90.0+**; older versions warn. Under a version manager gems are per-Ruby-version, so switching Ruby can make foreman vanish with no change to your code.

## overmind

```sh
bin/rails generate copse:install --process-manager=overmind
```

Overmind fixes the debugger the other way: every process gets its own tmux pty, so stdin is never multiplexed and you attach with `overmind connect web`. That makes the foreground-`web` split pointless — under Overmind, Copse contributes only the environment and hands the whole `Procfile.dev` over:

```ruby
exit Copse.start(process_manager: :overmind, args: ARGV)
```

Consequences of Overmind supervising everything, `web` included:

- **`PORT` is Overmind's, `base + index * 100`.** So `web` must be the **first** entry in `Procfile.dev` to get the derived port. Copse warns if it isn't. Every process still gets the derived port under `COPSE_PORT`.
- **The derived port is passed as `-p`, and `OVERMIND_SKIP_ENV=1` is set.** Overmind applies env files *over* the environment it's handed, so a stale `PORT` in one would otherwise win. `-p` is what defeats that — including in `.overmind.env`, which `OVERMIND_SKIP_ENV` doesn't skip. Neither touches your app's own loading: `dotenv-rails` still reads `.env` inside Rails, exactly as on the foreman path.
- `bin/dev`'s arguments go to `overmind start` *after* Copse's, so `bin/dev -l web` works and `bin/dev -p 4000` still overrides the derived port.
- No pty problems, so none of the stdin traps below apply.

`bin/dev` is committed, and Overmind is a binary rather than a gem, so it's checked at run time, not generate time: a teammate without Overmind falls back to the foreman session automatically. Which is a reason to keep `foreman` in the Gemfile anyway if `Procfile.dev` has non-`web` entries — that machine will need it.

## Where `*.localhost` resolves

RFC 6761 §6.3 makes `.localhost` special with a *SHOULD*, not a MUST, so support is uneven. Two separate questions: does the client resolve the name, and does it then reach a server bound to IPv4 loopback — which is what Rails binds, while `*.localhost` resolves `::1` first.

Measured on macOS 26.5.2, no `/etc/hosts` entry:

| Client | Resolves | Connects | |
|---|---|---|---|
| Chromium / Chrome / Edge | ✅ | ✅ | **verified here**, nested labels included |
| `curl` 8.2.1 | ✅ | ✅ | **verified here** — falls back past `::1` |
| System resolver | ✅ | — | **verified here** — `["::1", "127.0.0.1"]` |
| Firefox | ✅ | ✅ | *unverified* — built in since Firefox 84 |
| Safari, macOS 26+ | ✅ | ✅ | *unverified* — fix is in the OS resolver, which **is** verified |
| Safari / `curl`, macOS ≤ 15 | ❌ | — | *unverified* — [WebKit #160504](https://bugs.webkit.org/show_bug.cgi?id=160504) |
| Linux + `systemd-resolved` | ✅ | — | *unverified* — `systemd-resolved.service(8)` |
| Linux, bare glibc | ❌ | — | *unverified* — no `.localhost` case in glibc |

Rows marked *unverified* come from primary sources, not from this machine.

For a ❌ row, add a hosts entry — with two caveats:

```
127.0.0.1  fix-billing.cora.localhost
```

Neither glibc nor the macOS resolver supports wildcards, so that's **one line per hostname, meaning one per branch**. And it does nothing for Chrome, which hardcodes `.localhost` and [ignores your hosts file](https://issues.chromium.org/issues/41175806) for these names.

On macOS ≤ 15 or bare-glibc Linux and need Safari or `curl`? puma-dev's resolver approach doesn't have this gap. That's a real reason to prefer it.

## Requirements

- Ruby >= 3.2.0 (Rails 8.1's own floor; note 3.2 reached EOL 2026-04-01)
- Rails 7.1+ for the generator and URL options — the derivation itself needs neither Rails nor git
- `foreman` >= 0.90.0, only for apps with non-`web` Procfile entries — or Overmind instead, on the `--process-manager=overmind` path

Rails 8's development host allowlist already includes `.localhost`, so no `config.hosts` change is needed.

## Notes

- `Ctrl-C` can take up to foreman's shutdown timeout (5s default) if a watcher doesn't exit promptly.
- **Coming from Overmind, a bare `tailwindcss --watch` will take your whole session down.** The Tailwind CLI exits when stdin closes; Overmind's pty kept it open, foreman gives it none. The watcher exits **0** a second or two after boot and foreman's cascade ends `web` with it, so a CSS problem reads as an intentional shutdown. Use `--watch=always`. Copse warns when it sees the bare flag.
- Some Procfile lines cannot be made signal-transparent, so Copse warns and leaves them exactly as written rather than rewriting them into something subtly different. Their children may survive teardown; split them into separate entries to fix it. The shapes are a **pipeline** (`a | b`), a **background `&`**, a **command substitution** (`$(...)` or backticks), and a **subshell** (`(...)`). Each keeps a shell in front of the real process, and no `exec` placement collapses that into one signalable pid — `exec (cd x && y)` is not even valid shell syntax.
- Out of scope: reverse proxy, daemon, TLS, port registry, and `/etc/hosts` management.

## License

MIT — see [LICENSE.txt](LICENSE.txt).
