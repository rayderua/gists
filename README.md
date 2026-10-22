# gists

Small bash helpers I use at work. Each one is a file you source from
`~/.bashrc`; it adds a shell function with its own `help` and tab completion.

| Script | What it does | Docs |
|---|---|---|
| [`kubenv`](scripts/kubenv.sh) | Per-terminal kubectl context and namespace; kubeconfig kept as one file per cluster in `~/.kube/config.d/` | [docs/kubenv.md](docs/kubenv.md) |
| [`claude-agent`](scripts/claude-agent.sh) | Runs Claude Code as a separate, unprivileged user that sees only the projects you share with it | [docs/claude-agent.md](docs/claude-agent.md) |

## Install

```bash
git clone git@github.com:rayderua/gists.git
cd gists
./install.sh              # all scripts, or: ./install.sh kubenv
```

`install.sh` links `~/.<name>.sh` to `scripts/<name>.sh`, so a `git pull`
updates the scripts in place. An existing file at that path is moved to
`~/.<name>.sh.bak.<date>`. It does not edit `~/.bashrc`; it prints the line
to add if it isn't there yet:

```bash
[ -f ~/.kubenv.sh ] && . ~/.kubenv.sh
[ -f ~/.claude-agent.sh ] && . ~/.claude-agent.sh
```

Remove the links with `./install.sh --uninstall [name...]`.

## Layout

```
scripts/   the scripts, sourced from ~/.bashrc
docs/      one page per script: setup, workflows, how it works
install.sh links scripts into $HOME
```

The full list of subcommands lives in each script's `help` (`kubenv help`,
`claude-agent help`); the docs explain setup and workflows rather than
repeat it.
