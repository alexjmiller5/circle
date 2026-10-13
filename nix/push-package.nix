{ lib, swiftPackages, swift, swiftpm }:
swiftPackages.stdenv.mkDerivation {
  pname = "circle-push";
  version = "0.1.0";
  src = lib.fileset.toSource {
    root = ../.;
    fileset = lib.fileset.unions [ ../Package.swift ../nudge/nudge/Graph ../GraphTests ../push ];
  };
  nativeBuildInputs = [ swift swiftpm ];
  buildPhase = ''
    runHook preBuild
    export HOME="$TMPDIR"
    swift build -c release --product circle-push --disable-sandbox
    runHook postBuild
  '';
  installPhase = ''
    runHook preInstall
    install -Dm755 "$(swift build -c release --show-bin-path)/circle-push" "$out/bin/circle-push"
    runHook postInstall
  '';
  meta = {
    description = "Circle's nearby-alert push service";
    platforms = lib.platforms.darwin;
    mainProgram = "circle-push";
  };
}
