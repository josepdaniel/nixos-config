{ pkgs, inputs, ... }: {

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
    pkgs.dig
    pkgs.htop
    pkgs.whois
    pkgs.thunderbird
    pkgs.zed-editor
    inputs.nix-claude-code.packages.${pkgs.stdenv.hostPlatform.system}.default
  ];
}
