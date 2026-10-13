{ pkgs, ... }:
let
  user = "joseph";
in
{
  # ---------------------------------------------------------------------------
  # System layer: things that must be root-owned or live outside $HOME.
  # ---------------------------------------------------------------------------

  programs.niri.enable = true;

  # swaylock authenticates through PAM. Without this stanza it can never
  # unlock, no matter how it is configured on the home side below.
  security.pam.services.swaylock = { };

  systemd.user.services.polkit-gnome-authentication-agent-1 = {
    description = "polkit-gnome-authentication-agent-1";
    wantedBy = [ "graphical-session.target" ];
    partOf = [ "graphical-session.target" ];
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
    settings.default_session.command = "${pkgs.tuigreet}/bin/tuigreet --time --cmd niri-session";
  };

  security.rtkit.enable = true;
  services.pipewire = {
    enable = true;
    pulse.enable = true;
  };

  hardware.bluetooth.enable = true;
  services.blueman.enable = true;

  services.printing.enable = true;
  services.avahi = {
    enable = true;
    nssmdns4 = true;
    openFirewall = true;
  };

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
      sansSerif = [
        "Inter"
        "Noto Sans"
      ];
      serif = [ "Noto Serif" ];
      monospace = [ "JetBrainsMono Nerd Font" ];
      emoji = [ "Noto Color Emoji" ];
    };
  };

  # ---------------------------------------------------------------------------
  # Home layer: the same feature, user side. Merged into the home-manager
  # config that hosts/deep-thought/configuration.nix also contributes to.
  # ---------------------------------------------------------------------------

  home-manager.users.${user} = { pkgs, ... }: {
    xdg.configFile."niri" = {
      source = ./niri;
      recursive = true;
    };

    programs.alacritty.enable = true;
    programs.fuzzel.enable = true;

    programs.swaylock = {
      enable = true;
      package = pkgs.swaylock-effects;
      settings = {
        ignore-empty-password = true;

        clock = true;
        timestr = "%R";
        datestr = "%a, %e of %B";

        screenshots = true;

        effect-blur = "50x2";
        effect-scale = 0.3;

        indicator = true;
        indicator-radius = 240;
        indicator-thickness = 20;
        indicator-caps-lock = true;

      };
    };

    programs.ashell = {
      enable = true;
      settings = {
        appearance = {
          style = "Solid";
        };
        modules = {
          left = [ "Workspaces" ];
          center = [ "Tempo" ];
          right = [
            "Tray"
            "Settings"
          ];
        };
        tempo = {
          timezones = [
            "Europe/Copenhagen"
            "Australia/Sydney"
          ];
          clock_format = "%H:%M:%S";
          weather_location = {
            City = "Copenhagen";
          };
          wind_speed_unit = "Kmh";
        };

        workspaces = {
          visibility_mode = "MonitorSpecific";
        };
      };
    };

    services.mako = {
      enable = true;
      settings = {
        icons = 1;
        default-timeout = 5000;
        padding = 16;
        width = 450;
        border-size = 2;
        border-radius = 4;
        anchor = "top-center";
      };
    };

    home.packages = [
      pkgs.alacritty
      pkgs.fuzzel
      pkgs.playerctl
      pkgs.brightnessctl
      pkgs.wl-clipboard
      pkgs.swaylock-effects
      pkgs.xwayland-satellite
      pkgs.libnotify
    ];
  };
}
