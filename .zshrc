# +------------------------+
# | ZSH Configuration file |
# +------------------------+

# ---- HISTORY ----------------------------------
HISTFILE=~/.histfile
HISTSIZE=1000
SAVEHIST=1000

# ---- Completion -------------------------------
autoload -U compinit
zstyle ':completion:*' menu select
zmodload zsh/complist
compinit
_comp_options+=(globdots)	

# ---- ALIASES ----------------------------------

## Same command but with extra features
alias ls='exa --git --icons'
alias cat='bat --theme=gruvbox-dark'

## Shorthands
alias nv='nvim'
alias ll='ls -l'
alias la='ls -a'
alias lla='ls -la'
alias duh='du -h'

## Fuzzy finder utilities
alias sk='sk --reverse'
alias frm='rm -rf $(exa | sk -m)'
alias fcd='cd $(fd --type=d | sk)'
alias fgd='cd $(dirname $(fd -H -g \*.git ~/*/) | sk)'

## Quickly start a dev server
alias sv='python -m http.server 3000'

# ---- PLUGINS ----------------------------------

## Starship prompt
eval "$(starship init zsh)"

## Random color script
colorscript random

## Syntax highlighting and suggestion
source /usr/share/zsh/plugins/zsh-autosuggestions/zsh-autosuggestions.zsh
source /usr/share/zsh/plugins/zsh-syntax-highlighting/zsh-syntax-highlighting.zsh

ZSH_AUTOSUGGEST_STRATEGY=(history completion)
