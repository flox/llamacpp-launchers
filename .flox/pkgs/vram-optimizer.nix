{ rustPlatform, lib }:
rustPlatform.buildRustPackage {
  pname = "vram-optimizer";
  version = "0.1.6";
  src = /home/daedalus/dev/vram-optimizer;
  cargoLock.lockFile = /home/daedalus/dev/vram-optimizer/Cargo.lock;
  meta = {
    description = "Recommend GPU memory parameters for llama.cpp and vLLM from model metadata";
    license = lib.licenses.mit;
  };
}
