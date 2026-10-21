{ pkgs, ... }: {

  home.packages = [
    pkgs.delta
  ];

  programs.tmux = {
    enable = true;
    mouse = true;
    terminal = "tmux-256color";
    escapeTime = 0;

    extraConfig = ''
      # use wl-copy
      set -s copy-command 'wl-copy'

      # make colours work
      set -as terminal-features ",xterm-ghostty:RGB"

      # hjkl
      bind-key l select-pane -R
      bind-key h select-pane -L
      bind-key k select-pane -U
      bind-key j select-pane -D

      # new shell
      bind-key t display-popup -E -w 70% -h 70% -d "#{pane_current_path}" "$SHELL"

      # show diff
      bind-key y display-popup -E -w 90% -h 90% -d "#{pane_current_path}" "git diff | delta --side-by-side --paging always"
    '';
  };
}
