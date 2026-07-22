# Residual Review Findings

Branch `feat/copse-per-worktree-dev`, head `a80fbc8`.
Review run `20260722-125406-df23c632` (artifacts under `/tmp/compound-engineering-501/ce-code-review/`).

Twelve of fourteen findings were applied in `a80fbc8`. What follows is everything
that was **not** applied, plus what the applying revealed.

No tracker ticket was filed for any of these: `gh` is authenticated but this
repository has no git remote, so `gh repo view` fails and GitHub Issues is
unreachable. Both fallback tiers are unavailable, which makes this committed file
the durable record rather than a convenience copy. File these as issues once the
repo has a remote.

## Decisions the review left open -- both now RESOLVED

Recorded here as the decision log. Both were resolved and implemented rather than
left hanging; the reasoning is kept because in each case the option that looked
better on paper turned out not to exist.

### #10 -- RESOLVED: offset the base copse hands foreman

Chosen: pass foreman `PORT = derived + 100` (`Session::FOREMAN_PORT_OFFSET`).

Rejected: removing `PORT` from `foreman_env` entirely, which read as the cleaner
option. Foreman then falls back to `base_port = 5000` -- which is the macOS AirPlay
Receiver port *and* is on copse's own reserved list, so the first secondary would
have landed somewhere actively hostile. Offsetting keeps the values near the
derived neighbourhood and guarantees no child is handed the web port.

The regression test now asserts the **first** secondary's port, which is the one
that was broken; the original test only checked the second, which is exactly why
this was missed.

### #12 -- RESOLVED: refuse to rewrite substitutions and subshells

Chosen: treat `$(`, backticks, and `(` as unfixable, warn, and leave the line
byte-for-byte alone -- the same handling pipelines and background `&` already get.

Rejected: exec-prefix-only for those shapes. That option does not exist:
`exec (cd x && y)` is a shell syntax error, so there is no prefix form to fall back
to, and splicing before the last operator puts `exec` *inside* the parentheses,
leaving the outer command un-exec'd. Depth tracking was also rejected as more
machinery for a shape that is vanishingly rare in a Procfile. Refusing to rewrite
what cannot be reasoned about is correct by construction.

A pipe inside a substitution now reports the substitution as the reason rather than
the pipe, since the substitution is the root cause.

## Historical record of the two decisions as originally posed

### #10 -- Foreman's base `PORT` equals the web port (P2, `lib/copse/session.rb:194`)

Foreman derives each child's port as `base_port + index * 100`, and copse hands it
`PORT` = the derived port. So the **first** secondary receives exactly the web
process's port. If that secondary binds it, it collides with puma, and copse then
prints its own "another app or worktree most likely derived the same port" message
-- pointing at the wrong cause. Measured with `PORT=4321`: first child `4321`,
second `4421`.

The existing test asserts the *second* secondary's port, which is why this was
missed: it is the one case where foreman's arithmetic is visible and harmless.

Two answers:

1. Give foreman a bumped base (`PORT = worktree.port + 100`, or pass `-p`) so no
   child can be handed the web port.
2. Stop putting `PORT` in `foreman_env` at all, now that `COPSE_PORT` carries the
   derived value and the README already tells secondaries to read it.

Option 2 is cleaner but changes what a secondary sees in `PORT` from "a number" to
"foreman's default 5000-based ladder", which may surprise someone. Option 1 keeps
the shape and just moves it out of the way.

### #12 -- Operator scan ignores `$( )`, backticks, and `( )` (P3, `lib/copse/procfile.rb:146`)

Only `'` and `"` change the scanner's state, so operators inside a command
substitution or subshell are treated as top-level. Measured:

- `bin/x $(a && b)` becomes `bin/x $(a && exec b)` -- `exec` spliced *inside* the
  substitution, and the outer command is not exec'd at all. No warning.
- `(cd frontend && yarn build --watch)` becomes `(cd frontend && exec ...)`, and
  SIGTERM to the outer shell left the inner process alive.
- `$(ls *.css | head -1)` produces a false "pipeline" warning.

Two answers:

1. Track `$(` / backtick / `(` depth and ignore operators at depth > 0. Precise,
   more code.
2. Treat any command containing them as exec-prefix-only rather than splicing
   inside. Far simpler, and adequate given how rare these are in a Procfile.

The tests added in `a80fbc8` do not cover this shape either way, so whichever is
chosen needs its own case.

## What applying the fixes revealed

Two things worth recording because they change what the fixes actually accomplish.

- **#4's fix changes the failure mode rather than removing it.** RubyGems resolves
  `spec.files` against the working directory at build time, so anchoring the globs
  to `__dir__` does not make the gemspec buildable from anywhere -- it makes
  building from elsewhere fail **loudly** (`InvalidSpecificationException`, exit 1)
  instead of silently producing a publishable empty gem with exit 0. That is the
  safety-critical half. `gem build` from the repo root remains the supported path,
  as it is for every gem. Verified both directions.

- **A bare `FOO=1 cmd` with no other metacharacters is still left untouched.**
  `#8`'s fix routes assignment-prefixed segments through `env(1)`, but only where
  the transform runs at all; a command with no shell metacharacters is never
  rewritten, so it behaves identically with or without copse. Not a regression, but
  the inconsistency is deliberate and undocumented.

## Test gaps left open

The first two were attempted and abandoned as unavoidably flaky rather than
skipped for convenience.

- **A second SIGTERM arriving during teardown.** The fix for #1 keeps the trap
  installed across teardown, but landing a signal inside that window reliably needs
  timing control the harness does not have. The forward path is a fault-injection
  seam in `teardown` rather than a sleep race.
- **`write_temp_procfile` raising partway through.** #11's fix records the temp
  directory the moment it exists; proving it needs an injected failure between
  `Dir.mktmpdir` and `File.open`.
- `Procfile.top_level_operators` has no case for an escaped double quote inside a
  double-quoted argument.
- The singular/plural message branches in `report_if_foreman_died_early` and
  `foreman_error_message` are only exercised with one secondary.
- `Worktree#git`'s `Errno::EACCES` rescue (git present but not executable) is
  untested; only `Errno::ENOENT` is covered.
- `Worktree` is untested against `--separate-git-dir` and submodule worktrees,
  where `--git-common-dir` resolution can differ from the linked-worktree case.
- The CI `package` job now installs and loads the built gem, but still never runs
  the test suite against the packaged artifact.

## Advisory notes (anchor 50, not applied)

- `strip_port_flag` misses the attached short form `-p3000`, which is valid Rails
  CLI, so that one spelling still boots on 3000. A gap in Q4's chosen approach
  rather than a reversal of it.
- `bundler_overrides` nils **every** key absent from `Bundler.original_env`, not
  only bundler-owned ones. A `bin/dev` that exports `NODE_ENV` or prepends
  `node_modules/.bin` keeps it for the web process and loses it for every foreman
  child. Narrowing to `/\ABUNDLE_/`, `RUBYOPT`, `RUBYLIB`, `GEM_HOME`, `GEM_PATH`
  plus the `PATH` restoration would fix the asymmetry.
- `port_for` and `companion_port_for` repeat the CRC32-index-fetch formula; a
  private `index_for(seed)` would name it once.
- `Worktree#git` treats every non-zero git exit as "not a git worktree". Correct
  for the cases that matter, but a corrupted `.git` would silently yield a
  wrong-but-plausible hostname with no signal.
- Derived ports are deliberately reproducible, so `http://<project>.localhost:<port>`
  is guessable without probing. No exploit beyond what `localhost:3000` already
  exposes -- the server still binds loopback -- but a README line saying the port is
  not a secret would be honest.

## Coverage limits of this review

- **The cross-model adversarial pass did not run.** `codex` and `cursor-agent` are
  both installed, but running the pass would have sent this unpublished gem's full
  source to an external provider without being asked. The in-process
  `adversarial-reviewer` ran instead, so the adversarial lens is same-family and not
  corroborated across serving families.
- **CI has never executed.** Every claim about `.github/workflows/ci.yml` -- before
  and after the fix -- comes from running its commands locally. Ruby 3.4/4.0 and
  Ubuntu's `dash`, where the `exec` transform could behave differently from macOS's
  bash-as-sh, are untested by anything but reasoning.
