{ pkgs ? import <nixpkgs> {}}:

pkgs.mkShell {
  packages = [
    pkgs.just
    pkgs.sops
  ];
}
