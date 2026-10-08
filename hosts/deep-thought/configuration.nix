{ ... }: {
  imports = [ ./hardware-configuration.nix ../../modules/common.nix ];

  networking.hostName = "deep-thought";
  networking.networkmanager.enable = true;
  services.openssh.enable = true;
  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;

  system.stateVersion = "26.05";
}
