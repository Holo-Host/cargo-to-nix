{ pkgs ? import <nixpkgs> {} }:

with pkgs;
with lib;

let
  fake-cargo-checksum = runCommand "fake-cargo-checksum" { nativeBuildInputs = [ python3 ]; } ''
    install -D ${./fake-cargo-checksum.py} $out/bin/fake-cargo-checksum
    patchShebangs $out
  '';

  tomlToJSON = path: runCommand "toml.json" {} ''
    ${remarshal}/bin/toml2json < ${path} > $out
  '';

  importTOML = path: importJSON (tomlToJSON path);

  parseGitURL = url:
    let
      urlNormalized = replaceStrings [ "git+https://" ] [ "https://" ] url;
      urlAndRevision = splitString "#" urlNormalized;
      urlAndQuery = splitString "?" (head urlAndRevision);
      queryParams = splitString "=" (last urlAndQuery);
    in
    fetchGit {
      url = head urlAndQuery;
      ref = last queryParams;
      rev = last urlAndRevision;
    };

  mkCrate = hash: prefix: path: runCommand prefix {} ''
    mkdir $out
    cp -rs --no-preserve=mode ${path} $out/${prefix}
    cd $out/${prefix}
    rm -f Cargo.toml.orig
    find . -name .\* ! -name . -exec rm -rf -- {} +
    ${fake-cargo-checksum}/bin/fake-cargo-checksum ${hash}
  '';

  unpack = path: runCommand "source" {} ''
    mkdir $out
    tar -xaf ${path} -C $out --strip-components=1
  '';

  isNewestVersion = version: versions:
    version == last (sort versionOlder versions);

  metadataToCrate = packages: meta: hash:
    let
      splitMeta = splitString " " meta;
      name = elemAt splitMeta 1;
      version = elemAt splitMeta 2;

      source = if hash == "<none>"
        then parseGitURL packages."${name}"."${version}".source
        else unpack (fetchurl {
          url = "https://crates.io/api/v1/crates/${name}/${version}/download";
          name = "${name}-${version}.tar.gz";
          sha256 = hash;
        });

      prefix = name + optionalString (!isNewestVersion version (attrNames packages."${name}")) "-${version}";
    in
    mkCrate hash prefix source;
in

rec {
  cargoToNix = path:
    let
     lock = importTOML "${path}/Cargo.lock";

     packages = mapAttrs
       (const (groupBy (getAttr "version")))
       (groupBy (getAttr "name") lock.package);

     crates = mapAttrsToList (metadataToCrate packages) lock.metadata;
   in
   runCommand "vendor" {} ''
     mkdir $out

     for f in ${concatStringsSep " " crates}; do
       cp -rs $f/* $out
     done
   '';
}
