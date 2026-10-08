{ pkgs, ... }: {
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

  programs.helix = {
    enable = true;
    defaultEditor = true;
    extraPackages = [ pkgs.nil ];
  };

  programs.chromium = {
    enable = true;
    extensions = [
      { id = "nngceckbapebfimnlniiiahkandclblb"; }  # bitwarden
      {
        id = "cekpbngipfahnpmhegjojbpchoidhjml";    # adnauseam, not on the web store
        version = "3.29.2";
        crxPath = pkgs.fetchurl {
          url = "https://github.com/dhowe/AdNauseam/releases/download/v3.29.2/adnauseam-3.29.2.chromium.crx";
          hash = "sha256-im+fPXCVntH2T7Jc8KF8qHgL03qSFqT4kHCObknr7Hk=";
        };
      }
    ];
  };

  programs.firefox = {
      enable = true;
      policies = {
        ExtensionSettings = {
          "{446900e4-71c2-419f-a6a7-df9c091e268b}" = {
            install_url = "https://addons.mozilla.org/firefox/downloads/file/5076543/bitwarden_password_manager-2026.9.3.xpi";
            installation_mode = "force_installed";
            updates_disabled = false;
          };
          "adnauseam@rednoise.org" = {
            install_url = "https://addons.mozilla.org/firefox/downloads/file/4909199/adnauseam-3.28.8.xpi";
            installation_mode = "force_installed";
            updates_disabled = false;
          };
        };
      };
  };
  
  xdg.configFile."tmux" = { source = ./tmux; recursive = true; };
  xdg.configFile."niri" = { source = ./niri; recursive = true; };
  xdg.configFile."fish" = { source = ./fish; recursive = true; };
  xdg.configFile."ashell" = { source = ./ashell; recursive = true; };
  xdg.configFile."swaylock" = { source = ./swaylock; recursive = true; };

  programs.alacritty.enable = true;
  programs.fuzzel.enable = true;

  
  home.packages = [ pkgs.ashell pkgs.playerctl pkgs.brightnessctl pkgs.bitwarden-desktop pkgs.wl-clipboard pkgs.delta pkgs.tmux pkgs.swaylock ];
}
