{ stdenv, lib }:
let
  root = ../../.;
in
stdenv.mkDerivation {
  pname = "llamacpp-launchers";
  version = "0.4.3";
  src = root;

  dontBuild = true;

  installPhase = ''
    # Install the library for sourcing in [profile]
    mkdir -p $out/share/llamacpp-launchers
    install -m 644 bin/llamacpp $out/share/llamacpp-launchers/llamacpp.sh
    install -m 644 README.md $out/share/llamacpp-launchers/README.md

    # Install an executable wrapper for non-interactive use
    # (flox activate -- llamacpp launch ...)
    mkdir -p $out/bin
    cat > $out/bin/llamacpp << 'WRAPPER'
    #!/usr/bin/env bash
    # Executable entry point: source the library then dispatch.
    _LLAMACPP_LIB="''${FLOX_ENV:-}/share/llamacpp-launchers/llamacpp.sh"
    if [ -f "$_LLAMACPP_LIB" ]; then
      source "$_LLAMACPP_LIB"
    elif [ -f "$(dirname "$(dirname "$(readlink -f "$0")")")/share/llamacpp-launchers/llamacpp.sh" ]; then
      source "$(dirname "$(dirname "$(readlink -f "$0")")")/share/llamacpp-launchers/llamacpp.sh"
    else
      echo "[llamacpp] Error: cannot find llamacpp.sh library" >&2
      exit 1
    fi
    llamacpp "$@"
    WRAPPER
    chmod +x $out/bin/llamacpp
  '';

  meta = {
    description = "Shell wrapper for managing llama-server, GGUF models, and coding agent harnesses";
    license = lib.licenses.mit;
  };
}
