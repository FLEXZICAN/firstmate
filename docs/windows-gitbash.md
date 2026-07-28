# Windows (Git Bash / MINGW64)

Firstmate runs on Windows under Git for Windows' MINGW64 bash.
WSL is not this: it reports `Linux`, behaves as Linux, and takes no Windows branch anywhere.

Every Windows-specific behavior sits behind one seam, `bin/fm-platform-lib.sh`.
Sourcing that file on macOS or Linux defines functions and changes nothing else, so the POSIX paths stay byte-identical to upstream.
That is deliberate: this support is carried as a branch that merges from upstream periodically, and confining divergence to branches upstream does not have keeps those merges clean.

## Substrate facts the seam settles

- **`ln -s` silently copies.**
  MSYS2's default is not a symlink but a copy, which breaks any algorithm using symlink creation as a mutex - concretely the wake-queue watcher lock, which is claimed with `ln -s` and verified with `readlink`.
  The seam exports `MSYS=winsymlinks:nativestrict` at source time, so `ln -s` either makes a real NTFS symlink or fails outright.
  Native symlink creation needs Developer Mode or elevation.
- **Line endings.**
  `.gitattributes` pins `eol=lf` for the whole tree.
  A CRLF checkout breaks heredoc terminators, `#!/usr/bin/env bash` shebangs, and ShellCheck.
- **`kill -0` does not speak Windows pids**, and MSYS `ps` cannot see native processes such as `claude.exe`.
  Liveness and the harness-ancestry walk use a Windows process-table snapshot, bridged from the MSYS pid space through the MSYS root's WINPID.
- **`python3` may resolve without running.**
  Windows ships a Microsoft Store app-execution alias that prints an advertisement and exits 0.
  `fm_platform_python3_works` is the single owner of that question; presence on `PATH` is never taken as proof.
- **A lock under `/tmp` is not a lock under a drive path.**
  MSYS maps `/tmp` to `AppData\Local\Temp`, and the lock's owner-directory symlink does not survive that mount: the acquire fails and leaves `.steal` debris.
  `*.lock.steal.steal.steal/` therefore is not by itself evidence that native symlinks regressed - check where the home sits first.

## Crewmate spawn

Spawn diverges from POSIX in two places, both in `bin/fm-spawn.sh`.

### The worktree is leased, not inferred

On POSIX, firstmate types `treehouse get` into the pane and then polls the backend for the pane's live directory, taking the move away from the project as proof the worktree was acquired.

Neither half of that works here:

- **Nothing reports the pane's live directory.**
  Herdr omits `foreground_cwd` on Windows, so every read is empty and the wait always times out - even when treehouse succeeded.
  `cwd` is frozen at pane creation and does not follow a `cd`.
- **The subshell is not POSIX.**
  `treehouse get` opens `cmd.exe` here, so the marker probe that the zellij and cmux adapters use for exactly this gap (`printf ...; pwd; printf ...`) is not runnable either.

So Windows does not ask the question.
It runs `treehouse get --lease --lease-holder fm-<id>` itself and is told the absolute path on stdout.
This is the same durable-lease mechanism `bin/fm-home-seed.sh` already uses for secondmate homes, and `bin/fm-bootstrap.sh` already refuses to dispatch on a treehouse too old to support it.

The lease outlives the process that took it, which is what makes it safe against a crashed crewmate.
The cost is that a spawn dying between the lease and the metadata write must hand the worktree back itself, because nothing else knows the lease exists yet; `fm-spawn.sh`'s abort cleanup does that.
Once `state/<id>.meta` records `worktree=`, teardown owns the return and needs no change - it already calls `treehouse return --force`.

### The pane is switched to bash first

The pane's shell is whatever the terminal launched, and on Windows that is PowerShell or cmd.
Herdr takes it from `default_shell` in the user's global `config.toml` and exposes no per-tab override.

Every command firstmate sends a crewmate is POSIX, and not incidentally so: the harness launch line carries `VAR=value cmd` environment prefixes that no Windows-native shell accepts.
So the pane is switched to the same MINGW64 Git Bash firstmate runs in, once, before any POSIX text is sent.

Two traps this avoids by construction:

- **A bare `bash` from PowerShell is not Git Bash.**
  It resolves to `C:\Windows\System32\bash.exe`, the WSL entry point.
  With no WSL distro installed that fails with `CreateProcessEntryCommon:502: execvpe /bin/bash failed 2`; with one installed it would put the crewmate in a different operating system.
  The launcher is always named by absolute path.
- **`<root>\bin\bash.exe` and `<root>\usr\bin\bash.exe` are not interchangeable.**
  The first is Git for Windows' launcher and sets `MSYSTEM=MINGW64`; the second is the raw MSYS binary and yields `MSYSTEM=MSYS`, a different `PATH`, and a different runtime from the one firstmate resolved its own tools against.
  The launcher is preferred; the raw binary is a fallback.

Which quoting form the pane needs is settled by probing it, not by assuming.
`& '<path>' ...` runs the launcher in PowerShell and is a syntax error in cmd; `"<path>" ...` runs it in cmd and merely echoes the string in PowerShell.
Neither can do damage in the shell it is not meant for, so they are tried in order and the pane is asked which one worked.

Firstmate then `cd`s the pane into the worktree and verifies it landed there.
That check is load-bearing rather than defensive: a PowerShell profile ending in `Set-Location` - an ordinary dotfiles shape - moves every new pane regardless of the `--cwd` it was created with, and without the check the agent could start in the primary checkout.

## Known gaps

- A lease is durable, so it is not reclaimed by `treehouse prune` the way an idle non-leased worktree is.
  Recorded tasks are covered - teardown returns the worktree from `state/<id>.meta` - but a worktree whose metadata was lost entirely stays held until someone returns it by hand.
  `treehouse status --json` names the holder as `fm-<task-id>`, which is enough to identify one.
- Herdr publishes no stable Windows release asset, so one CI test gate-skips.
- `tmux`, the verified reference backend, is not available on Windows, so Herdr has no local backend to be compared against.
- `GOTMPDIR` is exported as an MSYS path (`/tmp/fm-<id>/gotmp`).
  A native Go toolchain does not read that as a Windows path, so Go projects have not been exercised here.

## Regression entry points

```sh
tests/fm-platform-lib.test.sh
bin/fm-test-run.sh --lane windows-gitbash-parallel --jobs 6
bin/fm-test-run.sh --lane windows-gitbash-serial
```

CI runs the same two halves as the `windows-gitbash` job on `windows-latest`, which also asserts the substrate is MINGW/MSYS and the checkout is LF.
