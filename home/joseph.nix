{ pkgs, ... }: {

  imports = [
    ./helix.nix
    ./tmux.nix
    ./fish.nix
    ./chromium.nix
  ];

  home.username = "joseph";
  home.homeDirectory = "/home/joseph";
  home.stateVersion = "26.05";

  programs.home-manager.enable = true;
  programs.git = {
    enable = true;
    settings.user = {
      name = "Joe";
      email = "josephtd28@gmail.com";
    };
  };

  xdg.configFile."nixpkgs" = {
    source = ./nixpkgs;
    recursive = true;
  };

  home.packages = [
    pkgs.delta
    pkgs.jq
    pkgs.yq
    pkgs.gron
    pkgs.uv
    pkgs.bun
  ];
}
