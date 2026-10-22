# claude-agent

Runs [Claude Code](https://claude.com/claude-code) as a separate,
unprivileged Linux user. The agent sees only the projects you share with it,
not the rest of your home directory: SSH keys, cloud credentials,
`~/.kube/config` and so on.

Sharing is a [bindfs](https://bindfs.org/) mount of your project into
`/home/claude/projects/<name>`. The mount maps owners both ways: the agent
sees the files as its own, and files it creates show up as yours in the
original directory.

Run `claude-agent help` for all subcommands.

## Setup

The commands use `claude` as the agent's user name. To pick another one,
replace it below and set `AGENT_USER=<name>` before sourcing the script.

### 1. Packages

```bash
sudo apt install bindfs        # Fedora: sudo dnf install bindfs
```

You also need `sudo`: the script uses it to act as the agent user and to
mount and unmount shares.

### 2. Create the agent user

```bash
sudo useradd --create-home --shell /bin/bash claude
sudo passwd --lock claude      # no password login; you get in through sudo
sudo chmod 700 /home/claude
```

Don't add the user to `sudo`, `docker` or other privileged groups: membership
in `docker` alone is equivalent to root.

### 3. Close your home directory to the agent

```bash
chmod o-rwx ~
sudo -u claude ls ~            # must fail with "Permission denied"
```

Most distributions already create home directories without access for others,
but check: if the agent can read your home, isolation is gone.

### 4. Install Claude Code for the agent and log in

```bash
sudo -iu claude
curl -fsSL https://claude.ai/install.sh | bash    # installs ~/.local/bin/claude
~/.local/bin/claude                               # log in, then /exit
exit
```

The script expects the binary at `/home/claude/.local/bin/claude`.

### 5. Git identity for the agent

So that commits made by the agent carry your name:

```bash
sudo -u claude git config --global user.name  "Your Name"
sudo -u claude git config --global user.email "you@example.com"
```

The agent has no SSH keys, so it can commit but not push. That's
deliberate: you review and push.

Global instructions for the agent (how to commit, how to reach Docker, etc.)
go into `/home/claude/.claude/CLAUDE.md`.

### 6. Optional: fewer password prompts

By default `sudo` asks for your password. To run things as the agent
without it, add a sudoers rule (`sudo visudo -f /etc/sudoers.d/claude-agent`):

```
you ALL=(claude) NOPASSWD: ALL
```

That covers `claude-agent run`, `claude-agent shell` and the `mkdir` in
`share`. Mounting and unmounting (`share`, `unshare`) still need root. Don't
allow `bindfs` without a password: anyone who can run it as root can mount
any directory anywhere, which is as good as root.

### 7. Install the script

```bash
./install.sh claude-agent
echo '[ -f ~/.claude-agent.sh ] && . ~/.claude-agent.sh' >> ~/.bashrc
```

## Usage

```bash
cd ~/work/my-service
claude-agent share my-service       # share $PWD as "my-service" (also registers it)
claude-agent my-service             # run Claude Code there
claude-agent my-service --new       # start a new session instead of continuing
claude-agent my-service -r          # pick a past session from a list
claude-agent list                   # registered projects and which are shared
claude-agent unshare my-service     # stop sharing
```

- **Sessions continue.** `claude-agent <name>` resumes the last session in
  that project (`claude -c`), so the agent keeps its context between runs.
  If the project has no session yet, a new one starts. Any other arguments go
  to `claude` as they are.
- **Shares don't survive a reboot.** Projects stay registered in
  `~/.config/claude-agent/projects`, so after a reboot it's enough to run
  `claude-agent share <name>`: the path is taken from the registry.
- **Registry without sharing:** `claude-agent add <name> [path]` and
  `claude-agent remove <name>`.
- `claude-agent shell` opens a login shell as the agent, e.g. to update
  Claude Code or check its settings.

## Limits

- Paths inside the agent's home can't be shared.
- The agent runs with the agent user's permissions: no sudo, no Docker, no
  access to your credentials. Anything it needs (a test cluster, a Docker
  host) has to be given to it on purpose.
