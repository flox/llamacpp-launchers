{ rustPlatform, lib }:
rustPlatform.buildRustPackage {
  pname = "llamacpp-proxy";
  version = "0.1.0";
  src = /home/daedalus/dev/llamacpp-proxy;
  cargoLock.lockFile = /home/daedalus/dev/llamacpp-proxy/Cargo.lock;
  meta = {
    description = "Unified API translation proxy for llama-server coding-agent harness compatibility";
    license = with lib.licenses; [ mit asl20 ];
  };
}
