{ pkgs, lib, stdenv, fetchurl, zstd, patchelf, ... }:

let
  version = "0.17.5";
  baseUrl = "https://ollama.com/download";

  # Map Nix system strings to Ollama's architecture naming.
  archMap = {
    "x86_64-linux"  = "amd64";
    "aarch64-linux" = "arm64";
  };
  arch = archMap.${stdenv.hostPlatform.system}
    or (throw "nix-ollama: unsupported system ${stdenv.hostPlatform.system}");

  srcBase = fetchurl {
    url    = "${baseUrl}/ollama-linux-${arch}.tar.zst";
    sha256 = "18jfzjz4bw4lckvbk237c0kh5c5cqwjzb0qgi05bqqwg2nyp8amd";
  };

  srcRocm = fetchurl {
    url    = "${baseUrl}/ollama-linux-${arch}-rocm.tar.zst";
    sha256 = "0nx4f4x3lp6ddn2h0dz5l7d4j3bdddwqbhvajmns9sccfylm6cpr";
  };

in
stdenv.mkDerivation {
  pname   = "ollama-bin";
  inherit version;

  srcs       = [ srcBase srcRocm ];
  sourceRoot = ".";

  nativeBuildInputs = [ zstd patchelf stdenv.cc.cc.lib ];

  unpackPhase = ''
    mkdir -p extracted
    zstd -d < ${srcBase} | tar -x -C extracted
    zstd -d < ${srcRocm} | tar -x -C extracted
  '';

  installPhase = ''
    mkdir -p $out/bin $out/lib/ollama

    cp extracted/bin/ollama      $out/bin/ollama
    cp -r extracted/lib/ollama/. $out/lib/ollama/

    patchelf \
      --set-interpreter ${pkgs.stdenv.cc.bintools.dynamicLinker} \
      --set-rpath ${stdenv.cc.cc.lib}/lib:${pkgs.glibc}/lib \
      $out/bin/ollama
  '';

  meta = {
    description = "Local large language model runner (official binary release)";
    homepage    = "https://ollama.com";
    platforms   = [ "x86_64-linux" ];
    license     = lib.licenses.mit;
    maintainers = [];   # add your GitHub handle here
  };
}