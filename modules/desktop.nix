{ pkgs, ... }: {
  programs.niri.enable = true;

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
