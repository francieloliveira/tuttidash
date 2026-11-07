# Tema do painel e das lanes. Título do painel = etapa (fila, revisão, prova, instalação).
# Título da lane = ociosa · nome  ou  executar · nome · card.
set -g status-position bottom
set -g status-interval 5
set -g status-style "bg=colour235,fg=colour250"
set -g status-left "#[fg=colour235,bg=colour39,bold] TD #[default] "
set -g status-left-length 12
set -g status-right "#[fg=colour245]#(bash ~/.transcentia/tools/status-lanes.sh)  #[fg=colour255,bold]%H:%M "
set -g status-right-length 80
set -g pane-border-status top
set -g pane-border-lines heavy
set -g pane-border-style "fg=colour238"
set -g pane-active-border-style "fg=colour39"
# Cor pelo estágio no título. O texto do título já é a etapa — não repete ícone de pessoa.
set -g pane-border-format " #{?#{m:fila*,#{pane_title}},#[fg=colour39#,bold],#{?#{m:revis*,#{pane_title}},#[fg=colour141#,bold],#{?#{m:prova*,#{pane_title}},#[fg=colour41#,bold],#{?#{m:instala*,#{pane_title}},#[fg=colour220#,bold],#{?#{m:executar*,#{pane_title}},#[fg=colour208#,bold],#{?#{m:ociosa*,#{pane_title}},#[fg=colour245],#{?#{m:trabalho*,#{pane_title}},#[fg=colour208#,bold],#[fg=colour250#,bold]}}}}}}#{pane_title} #[default]"

# Scroll com o mouse/trackpad. Os painéis da janela "lanes" são attach aninhados
# nas sessões lane-<lane> (mesmo servidor tmux): com mouse ligado, a rolagem
# passa para a sessão da lane, que guarda até 50 mil linhas.
set -g mouse on
set -g history-limit 50000
