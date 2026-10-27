# Tema único das janelas tmux (painel e lanes). Carregado por painel.command e lanes.command.
set -g status-position bottom
set -g status-interval 5
set -g status-style "bg=colour235,fg=colour250"
set -g status-left "#[fg=colour235,bg=colour39,bold] #S #[default] "
set -g status-left-length 20
set -g status-right "#[fg=colour245]#(bash ~/.transcentia/tools/status-lanes.sh)  #[fg=colour255,bold]%H:%M "
set -g status-right-length 80
set -g pane-border-status top
set -g pane-border-lines heavy
set -g pane-border-style "fg=colour238"
set -g pane-active-border-style "fg=colour39"
set -g pane-border-format "  #{?#{m:*claude*,#{pane_title}},#[fg=colour208#,bold]◆ ,#{?#{m:*grok*,#{pane_title}},#[fg=colour33#,bold]◆ ,#{?#{m:*[Tt]este*,#{pane_title}},#[fg=colour41#,bold]✔ ,#{?#{m:*[Dd]ispatcher*,#{pane_title}},#[fg=colour141#,bold]⇄ ,#{?#{m:*[Bb]uild*,#{pane_title}},#[fg=colour220#,bold]⚒ ,#[fg=colour245#,bold]● }}}}}#{pane_title} #[default] "

# Scroll com o mouse/trackpad em cada lane. Os painéis da janela "lanes" são attach aninhados
# nas sessões lane-<lane> (mesmo servidor tmux): com mouse ligado em todas, a rolagem passa
# para a sessão da lane, que guarda até 50 mil linhas de histórico.
set -g mouse on
set -g history-limit 50000
