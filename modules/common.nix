{ pkgs, ... }: {
  nix.settings.experimental-features = [ "nix-command" "flakes" ];
  time.timeZone = "Europe/Copenhagen";

  users.users.joseph = {
    isNormalUser = true;
    extraGroups = [ "wheel" "networkmanager" ];
    shell = pkgs.fish;
  };
  programs.fish.enable = true;

  environment.systemPackages = with pkgs; [ git tmux ];
}
