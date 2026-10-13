{ inputs, ... }: {
  imports = [
    ./hardware-configuration.nix
    ../../modules/common.nix
    ../../features/desktop.nix
    inputs.home-manager.nixosModules.home-manager
  ];

  home-manager.backupFileExtension = "hm-bak";
  home-manager.useGlobalPkgs = true;
  home-manager.useUserPackages = true;
  home-manager.users.joseph = import ../../home/joseph.nix;

  networking.hostName = "deep-thought";
  networking.networkmanager.enable = true;

  services.openssh = {
    enable = true;
    settings = {
      PasswordAuthentication = false;
      KbdInteractiveAuthentication = false;
    };
  };

  users.users.joseph.openssh.authorizedKeys.keys = [
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIFqrQRK3iAKhEui3VEz6C1TqI+FAm1FYDPXdcc9TbA26 joseph@joseph-thinkpad"
  ];

  virtualisation.docker.enable = true;
  virtualisation.docker.autoPrune.enable = true;
  users.users.joseph.extraGroups = [ "docker" ];

  boot.loader.systemd-boot.enable = true;
  boot.loader.systemd-boot.configurationLimit = 10;
  boot.loader.efi.canTouchEfiVariables = true;

  system.stateVersion = "26.05";
}
