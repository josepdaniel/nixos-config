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

  fonts.packages = [ pkgs.nerd-fonts.jetbrains-mono ];
}
