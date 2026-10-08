{ pkgs, ... }: {
  home.username = "joseph";
  home.homeDirectory = "/home/joseph";
  home.stateVersion = "26.05";
  programs.home-manager.enable = true;
  programs.git.enable = true;

  programs.helix = {
    enable = true;
    defaultEditor = true;
    extraPackages = [ pkgs.nil ];
  };
}
