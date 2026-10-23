{ pkgs, ... }:
let
  user = "joseph";

  cliphistPicker = pkgs.writeShellApplication {
    name = "cliphist-picker";
    runtimeInputs = [
      pkgs.cliphist
      pkgs.fuzzel
      pkgs.wl-clipboard
      pkgs.wtype
      pkgs.gawk
    ];
    text = ''
      tmpdir=$(mktemp -d)
      trap 'rm -rf "$tmpdir"' EXIT

      build_menu() {
        while IFS= read -r line; do
          preview=''${line#*$'\t'}
          if [[ "$preview" == "[[ binary data"*"]]" ]]; then
            id=''${line%%$'\t'*}
            ext=$(awk '{print $5}' <<<"$preview")
            case "$ext" in
              png|jpg|jpeg|gif|bmp|webp) ;;
              *) ext=png ;;
            esac
            img="$tmpdir/$id.$ext"
            if cliphist decode <<<"$line" >"$img" 2>/dev/null && [[ -s "$img" ]]; then
              printf '%s\0icon\x1f%s\n' "$line" "$img"
              continue
            fi
          fi
          printf '%s\n' "$line"
        done
      }

      selection=$(cliphist list | build_menu | fuzzel --dmenu)
      [[ -z "$selection" ]] && exit 0

      cliphist decode <<<"$selection" | wl-copy
      wtype -M ctrl v -m ctrl
    '';
  };
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

  # swayosd draws the volume/brightness OSD. Volume it reads straight from
  # PulseAudio, but brightness means writing /sys/class/backlight/*/brightness,
  # which is root-only until the package's udev rules hand it to the "video"
  # group, so the rules and the group membership are both needed.
  services.udev.packages = [ pkgs.swayosd ];
  users.users.${user}.extraGroups = [ "video" ];

  hardware.bluetooth.enable = true;
  services.blueman.enable = true;

  services.printing.enable = true;
  services.avahi = {
    enable = true;
    nssmdns4 = true;
    openFirewall = true;
  };

  # TLP and power-profiles-daemon conflict; TLP goes further on battery
  # (CPU EPP, PCIe/USB runtime PM, Wi-Fi power save) and handles ThinkPad
  # charge thresholds.
  services.power-profiles-daemon.enable = false;
  services.tlp = {
    enable = true;
    settings = {
      START_CHARGE_THRESH_BAT0 = 75;
      STOP_CHARGE_THRESH_BAT0 = 80;
    };
  };

  # ashell reads battery state only over the org.freedesktop.UPower D-Bus
  # interface; power-profiles-daemon shares that namespace but exposes no
  # battery devices.
  services.upower.enable = true;

  # Nemo's sidebar is populated by the gvfs udisks2 volume monitor, not by
  # Nemo itself; udisks2 does the actual mounting, gvfs exposes it to the
  # session. Both are needed for removable drives to appear at all.
  services.udisks2.enable = true;
  services.gvfs.enable = true;

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

    home.pointerCursor = {
      enable = true;
      gtk.enable = true;
      name = "Adwaita";
      package = pkgs.adwaita-icon-theme;
      size = 24;
    };

    gtk = {
      enable = true;
      theme = {
        name = "Adwaita-dark";
        package = pkgs.gnome-themes-extra;
      };
      iconTheme = {
        name = "Papirus-Dark";
        package = pkgs.papirus-icon-theme;
      };
    };

    # GTK apps pick up the theme above from gtk-3.0/settings.ini, but Electron
    # and libadwaita apps instead ask the portal for the org.freedesktop.appearance
    # color-scheme preference, which mirrors this dconf key. gtk.theme does not
    # set it, so without this the portal answers "no preference" and they render
    # light no matter what Adwaita-dark is doing.
    dconf.settings."org/gnome/desktop/interface".color-scheme = "prefer-dark";

    qt = {
      enable = true;
      platformTheme = "gnome";
      style.name = "adwaita-dark";
    };

    programs.alacritty = {
      enable = true;
      theme = "monokai_pro";
      settings.window = {
        padding = {
          x = 8;
          y = 6;
        };
        dynamic_padding = true;
      };
    };
    programs.fuzzel = {
      enable = true;
      settings.main = {
        width = 60;
        horizontal-pad = 12;
        icon-theme = "Papirus-Dark";
      };
    };

    services.cliphist.enable = true;

    xdg.desktopEntries.qalculate = {
      name = "Calculator";
      genericName = "Calculator";
      comment = "Command-line calculator in a floating terminal";
      exec = "alacritty --class org.nixos.Qalculate -e qalc";
      icon = "accessories-calculator";
      terminal = false;
      categories = [
        "Utility"
        "Calculator"
      ];
    };

    programs.swaylock = {
      enable = true;
      package = pkgs.swaylock-effects;
      settings = {
        ignore-empty-password = true;
        font = "Inter";
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
          scale_factor = 1.2;
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

    services.swayosd = {
      enable = true;
      topMargin = 0.8;
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
      pkgs.fuzzel
      pkgs.playerctl
      pkgs.brightnessctl
      pkgs.wl-clipboard
      pkgs.wtype
      cliphistPicker
      pkgs.swaylock-effects
      pkgs.xwayland-satellite
      pkgs.libnotify
      pkgs.nemo
      pkgs.libqalculate
    ];
  };
}
