{ inputs, ... }: {
  imports = [
    ./hardware-configuration.nix
    ../../modules/common.nix
    ../../modules/desktop.nix
    inputs.home-manager.nixosModules.home-manager
  ];

  home-manager.useGlobalPkgs = true;
  home-manager.useUserPackages = true;
  home-manager.users.joseph = import ../../home/joseph.nix;

  networking.hostName = "deep-thought";
  networking.networkmanager.enable = true;

  services.openssh.enable = true;

  virtualisation.docker.enable = true;
  users.users.joseph.extraGroups = [ "docker" ];

  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;

  system.stateVersion = "26.05";
}
