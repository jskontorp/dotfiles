# core.zsh — Shared shell config, sourced by machine-specific zshrc files.
# History, shell behaviour, aliases, PATH, and terminal integration.

# --- History ---
HISTFILE=~/.zsh_history
HISTSIZE=10000
SAVEHIST=10000
setopt share_history
setopt hist_ignore_dups
setopt hist_ignore_space
setopt hist_verify          # expand !! but show it before running
setopt extended_history     # timestamps in history

# --- Shell behaviour ---
setopt auto_cd              # type a dir name to cd into it
setopt interactivecomments  # allow # comments in terminal
export EDITOR="nvim"

# Disable XON/XOFF flow control so Ctrl-S doesn't freeze the terminal.
# Required because Ghostty's `ctrl+<digit>` keybinds emit \x13 (Ctrl-S) +
# digit to drive tmux window switching; without this, pressing Ctrl+1..9
# outside tmux would pause output until Ctrl-Q.
[[ -t 0 ]] && stty -ixon 2>/dev/null

# --- Aliases ---
alias cat="bat --paging=never"
alias lg="lazygit"

# ls → eza
alias ls="eza --color=always --group-directories-first"
alias ll="eza -la --color=always --group-directories-first --icons"
alias la="eza -a --color=always --group-directories-first --icons"
alias lt="eza -T --color=always --group-directories-first --icons --level=2"

# --- Helpers ---
source_if() { [[ -f "$1" ]] && source "$1"; }

# --- PATH ---
case ":$PATH:" in
  *":$HOME/.local/bin:"*) ;;
  *) export PATH="$HOME/.local/bin:$PATH" ;;
esac

# pnpm global bin — platform default per pnpm docs.
# pnpm ≥10 places globally-added shims under $PNPM_HOME/bin (older versions
# used $PNPM_HOME directly), but the standalone installer still drops
# `pnpm` itself at $PNPM_HOME/pnpm, and pre-pnpm-10 shims (e.g. `pi`,
# `claude` installed before the migration) may still live at the legacy
# location. Keep both on PATH so fresh shells resolve every binary
# regardless of when it was installed. Mirrors `justfile` [linux] update.
# Idempotent.
case "$(uname -s)" in
  Darwin) export PNPM_HOME="$HOME/Library/pnpm" ;;
  Linux)  export PNPM_HOME="$HOME/.local/share/pnpm" ;;
esac
if [[ -n "${PNPM_HOME:-}" ]]; then
  case ":$PATH:" in
    *":$PNPM_HOME/bin:"*) ;;
    *) export PATH="$PNPM_HOME/bin:$PATH" ;;
  esac
  case ":$PATH:" in
    *":$PNPM_HOME:"*) ;;
    *) export PATH="$PNPM_HOME:$PATH" ;;
  esac
fi

# libpq (keg-only) — psql/pg_dump client tools without the full server
if [[ -d /opt/homebrew/opt/libpq/bin ]]; then
  case ":$PATH:" in
    *":/opt/homebrew/opt/libpq/bin:"*) ;;
    *) export PATH="/opt/homebrew/opt/libpq/bin:$PATH" ;;
  esac
fi

# --- Terminal integration ---
# Emit OSC 7 so Ghostty and other terminals know the cwd for new tabs/splits
autoload -Uz add-zsh-hook
__osc7_cwd() {
  printf '\e]7;file://%s%s\a' "${HOST}" "${PWD}"
}
# Register once — guard prevents double-registration on re-source
(( ${chpwd_functions[(Ie)__osc7_cwd]} )) || add-zsh-hook chpwd __osc7_cwd
__osc7_cwd  # emit once at shell startup
