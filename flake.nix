{
  description = "Flash balenaOS to iot-gate-imx8plus";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";

  outputs =
    { nixpkgs, ... }:
    let
      systems = [
        "aarch64-darwin"
        "x86_64-darwin"
      ];
      forAllSystems = f: nixpkgs.lib.genAttrs systems (system: f nixpkgs.legacyPackages.${system});
    in
    {
      devShells = forAllSystems (pkgs: {
        default = pkgs.mkShell {
          # hdiutil, system_profiler and sudo come from macOS itself
          packages = with pkgs; [
            bash
            uuu
            gzip
            unzip
          ];
        };
      });
    };
}
