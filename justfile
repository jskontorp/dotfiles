# dotfiles
# Unified dotfiles for mac + vm. Machine-specific configs in machine/{mac,vm}/.

default:
  @just --list

install:
  ./install.sh

# Run the machine-specific justfile
[macos]
machine *args:
  just -f machine/mac/justfile {{args}}

[linux]
machine *args:
  just -f machine/vm/justfile {{args}}
