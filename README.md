# Bootstrap

From the NixOS installer, after partitioning and mounting at /mnt:

    nix-shell -p git
    git clone <this repo> /mnt/etc/nixos
    nixos-generate-config --root /mnt --show-hardware-config > /mnt/etc/nixos/hosts/deep-thought/hardware-configuration.nix
    nixos-install --flake /mnt/etc/nixos#deep-thought
    reboot

Afterwards: `sudo nixos-rebuild switch --flake /etc/nixos#deep-thought`
