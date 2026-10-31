## Pterodactyl Wings, packaged.
##
## Its own file rather than a let-binding inside modules/wings.nix so
## the flake can expose it as packages.<system>.wings. That matters for
## testing: `nix flake check` only *evaluates*, so a wrong `hash` below
## would sail through it and fail on the host mid-deploy. As a package
## output, `task nix:check` can actually build it and prove the hash.
##
## nixpkgs ships no pterodactyl-wings (verified: not in
## pkgs/by-name/pt/, no services.pterodactyl.* in module-list.nix on
## 25.05 or unstable), so this is ours to carry.
##
## To bump: change `version`, then get the new hash with
##   nix store prefetch-file --hash-type sha256 \
##     https://github.com/pterodactyl/wings/releases/download/v<ver>/wings_linux_amd64
{ lib, stdenv, fetchurl }:

stdenv.mkDerivation rec {
  pname = "pterodactyl-wings";
  version = "1.13.3";

  src = fetchurl {
    url = "https://github.com/pterodactyl/wings/releases/download/v${version}/wings_linux_amd64";
    hash = "sha256-AQ2JSolf5PkU4/HB51+y/aTr5QzCSefkVoh+pbQiyPo=";
  };

  # A release artifact, not a tarball: there's nothing to unpack and
  # nothing to build. Upstream ships a statically linked Go binary
  # (verified on 1.13.3: no PT_INTERP, "statically linked" per file(1)),
  # so it needs no patchelf and no interpreter from the store.
  #
  # If a future release ever ships a CGO build, it will install fine and
  # then fail at runtime with a confusing "no such file or directory" —
  # that's the dynamic loader missing, not the config. The fix is
  # nativeBuildInputs = [ autoPatchelfHook ] and buildInputs =
  # [ stdenv.cc.cc.lib ], not debugging the systemd unit.
  dontUnpack = true;
  dontBuild = true;
  dontStrip = true;

  installPhase = ''
    runHook preInstall
    install -Dm755 $src $out/bin/wings
    runHook postInstall
  '';

  meta = with lib; {
    description = "Pterodactyl's game server control plane daemon";
    homepage = "https://pterodactyl.io";
    license = licenses.mit;
    platforms = [ "x86_64-linux" ];
    mainProgram = "wings";
  };
}
