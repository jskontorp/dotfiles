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

# --- Terminal integration ---
# Emit OSC 7 so Ghostty and other terminals know the cwd for new tabs/splits
autoload -Uz add-zsh-hook
__osc7_cwd() {
  printf '\e]7;file://%s%s\a' "${HOST}" "${PWD}"
}
# Register once — guard prevents double-registration on re-source
(( ${chpwd_functions[(Ie)__osc7_cwd]} )) || add-zsh-hook chpwd __osc7_cwd
__osc7_cwd  # emit once at shell startup
