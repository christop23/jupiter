neofetch

export NNN_FCOLORS='c1e2272e006033f7c6d6abc4'                                 # use a different color for each context
export NNN_TRASH=1                                                            # trash (needs trash-cli) instead of delete
export NNN_PLUG='f:finder;o:fzopen;p:mocq;d:diffs;t:nmount;v:imgview'         # enable plugins

if [ -z $DISPLAY ] && [ "$(tty)" = "/dev/tty1" ]; then 
exec sway
fi

