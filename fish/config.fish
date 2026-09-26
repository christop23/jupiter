# Disable greeting
set -U fish_greeting ""

# Starship prompt
if status is-interactive
    set -gx STARSHIP_CONFIG $HOME/.config/starship/starship.toml
    starship init fish | source
end

# Format man pages. bat does the syntax highlighting from the roff source, so
# man is told to keep its escapes and col is told to pass them through (-b) and
# not to re-space (-x).
set -x MANPAGER "sh -c 'col -bx | bat -l man -p'"

# Source fish_profile if exists
if test -f $HOME/.fish_profile
    source $HOME/.fish_profile
end

# PATH additions.
#
# Nothing here is added unconditionally any more. /opt/node/bin,
# $HOME/Applications/depot_tools and $GOPATH/bin were all prepended whether or
# not they existed, so every new shell carried two or three dead PATH entries
# and the first command run that happened to have a name in the same place
# resolved to the wrong thing.
for p in $HOME/.local/bin $HOME/bin
    if test -d $p
        if not contains -- $p $PATH
            set -p PATH $p
        end
    end
end

# Go, when it is installed. Nothing in this setup needs it -- the editor config
# that used to enable the Go language extras is gone -- but a Go toolchain
# installed by hand puts gopls and the formatters on PATH by convention, and
# adding the directory when it exists costs nothing. The old entry was
# unconditional, so every shell carried a dead path whether or not Go was there.
if test -d $HOME/go/bin
    if not contains -- $HOME/go/bin $PATH
        set -p PATH $HOME/go/bin
    end
end

#####################
### Key Bindings  ###
#####################
# Enable vim bindings
set -U fish_key_bindings fish_vi_key_bindings

# No mode indicator. This removes the only feedback that vi mode gives, so
# there is no way to tell from the prompt whether an inserted character will be
# text or a command. starship draws its own vi mode indicator when
# vi_mode = true in starship.toml, which is the better place for it, because
# this function is what suppresses it.
#
# To get the indicator back, delete this function. To keep the old behaviour,
# set vi_mode = true in starship.toml.
function fish_mode_prompt
    echo -n ''
end

# !! and !$ support
function __history_previous_command
    switch (commandline -t)
        case "!"
            commandline -t $history[1]
            commandline -f repaint
        case "*"
            commandline -i !
    end
end

function __history_previous_command_arguments
    switch (commandline -t)
        case "!"
            commandline -t ""
            commandline -f history-token-search-backward
        case "*"
            commandline -i '$'
    end
end

bind ! __history_previous_command
bind '$' __history_previous_command_arguments

##################
### Functions  ###
##################
# Better history
function history
    builtin history --show-time='%F %T '
end

function backup --argument filename
    # Quoted: the wallpapers in this repo have spaces in their names, so an
    # unquoted argument is not a theoretical problem here.
    cp "$filename" "$filename.bak"
end

# Copy DIR1 DIR2
function copy
    if test (count $argv) = 2; and test -d "$argv[1]"
        set from (string trim -r -c '/' "$argv[1]")
        set to "$argv[2]"
        command cp -r "$from" "$to"
    else
        command cp $argv
    end
end

# mkcd DIR
function mkcd
    mkdir -p "$argv[1]"; and cd "$argv[1]"
end

# Extract archives
#
# Order matters: *.tar.bz2 and *.tar.gz come before *.bz2 and *.gz, and *.tar
# before the catch-all, or the shorter patterns swallow the compound ones.
#
# "$file" is quoted throughout. The wallpapers shipped in this repo have spaces
# in their names, so an unquoted archive path is not hypothetical here.
function extract
    set file $argv[1]
    if test -f "$file"
        switch $file
            case '*.tar.bz2'
                tar xjf "$file"
            case '*.tar.gz' '*.tgz'
                tar xzf "$file"
            case '*.tbz2' '*.tbz'
                tar xjf "$file"
            case '*.bz2'
                bunzip2 "$file"
            case '*.rar'
                unrar x "$file"
            case '*.gz'
                gunzip "$file"
            case '*.tar'
                tar xvf "$file"
            case '*.zip'
                unzip "$file"
            case '*.Z'
                uncompress "$file"
            case '*.7z'
                7z x "$file"
            case '*'
                echo "'$file' cannot be extracted via extract()"
        end
    else
        echo "'$file' is not a valid file"
    end
end

##################
### Aliases    ###
##################
# ls replacements
alias ls='eza -al --color=always --group-directories-first --icons'
alias la='eza -a --color=always --group-directories-first --icons'
alias ll='eza -l --color=always --group-directories-first --icons'
alias lt='eza -aT --color=always --group-directories-first --icons'
alias l.='eza -a | grep -e "^\."'

# System helpers
alias grubup="sudo grub-mkconfig -o /boot/grub/grub.cfg"
alias fixpacman="sudo rm /var/lib/pacman/db.lck"
alias tarnow='tar -acf '
alias untar='tar -zxvf '
alias wget='wget -c '
alias psmem='ps auxf | sort -nr -k 4'
alias psmem10='ps auxf | sort -nr -k 4 | head -10'
alias ..='cd ..'
alias ...='cd ../..'
alias ....='cd ../../..'
alias .....='cd ../../../..'
alias ......='cd ../../../../..'

# Arch helpers
alias gitpkg='pacman -Q | grep -i "\-git" | wc -l'
# `update` is not defined here as well as in the System control block below.
# Two definitions of one alias is not a merge, it is a second assignment: the
# later one silently replaced this, so the pacman form below was unreachable.
# The yay form under System control is the one that runs.
alias cleanup='sudo pacman -Rns (pacman -Qtdq)'

# Shortcuts
alias apt='man pacman'
alias apt-get='man pacman'
alias please='sudo'
alias jctl="journalctl -p 3 -xb"
alias ff='fastfetch'
alias q='exit'
alias h='history'
alias c='clear'

# Git shortcuts
alias gs='git status'
alias ga='git add'
alias gc='git commit'
alias gcl='git clone'
alias gl='git log --oneline'
alias gd='git diff'
alias gpush='git push'
alias gpull='git pull'

# System control
alias wifi='nmtui'
alias install='yay -S'
alias update='yay -Syu'
alias search='yay -Ss'
alias lsearch='yay -Qs'
alias remove='yay -Rns'
alias shutdown='systemctl poweroff'

###################
### Environment ###
###################
# SHELL_CONFIG_DIR pointed at $HOME/.config, which is where starship looks for
# $SHELL_CONFIG_DIR/starship.toml. The config in this repo is at
# starship/starship.toml, so that path names a file that does not exist. It was
# masked by STARSHIP_CONFIG being set at the top of this file, so it only ever
# mattered if that line were removed; both now agree.
set -gx SHELL_CONFIG_DIR $HOME/.config/starship
set -gx GOPATH $HOME/go