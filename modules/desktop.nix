{ pkgs, ... }: {
  programs.niri.enable = true;
  security.pam.services.swaylock = { };

  systemd.user.services.polkit-gnome-authentication-agent-1 = {
    description = "polkit-gnome-authentication-agent-1";
    wantedBy = [ "graphical-session.target" ];
    after = [ "graphical-session.target" ];
    serviceConfig = {
      Type = "simple";
      ExecStart = "${pkgs.polkit_gnome}/libexec/polkit-gnome-authentication-agent-1";
      Restart = "on-failure";
      RestartSec = 1;
    };
  };

  services.greetd = {
    enable = true;
    settings.default_session.command =
      "${pkgs.tuigreet}/bin/tuigreet --time --cmd niri-session";
  };

  services.pipewire = {
    enable = true;
    pulse.enable = true;
  };

  hardware.bluetooth.enable = true;
  services.blueman.enable = true;
  services.printing.enable = true;
  services.power-profiles-daemon.enable = true;

  fonts = {
    packages = [
      pkgs.nerd-fonts.jetbrains-mono
      pkgs.inter
      pkgs.noto-fonts
      pkgs.noto-fonts-cjk-sans
      pkgs.noto-fonts-color-emoji
    ];
    fontconfig.defaultFonts = {
      sansSerif = [ "Inter" "Noto Sans" ];
      serif = [ "Noto Serif" ];
      monospace = [ "JetBrainsMono Nerd Font" ];
      emoji = [ "Noto Color Emoji" ];
    };
  };
}
