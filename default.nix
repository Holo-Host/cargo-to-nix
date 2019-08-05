{ lib, fetchurl, runCommand, python3, remarshal }:

with lib;

let
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

  cargo-checksum = runCommand "cargo-checksum" { nativeBuildInputs = [ python3 ]; } ''
    install -D ${./cargo-checksum.py} $out/bin/cargo-checksum
    patchShebangs $out
  '';

  mkCrate = hash: prefix: path: runCommand prefix {} ''
    mkdir $out
    cp -rs --no-preserve=mode ${path} $out/${prefix}
    cd $out/${prefix}

    rm -f Cargo.toml.orig
    find . -name .\* ! -name . -exec rm -rf -- {} +

    ${cargo-checksum}/bin/cargo-checksum '${hash}'
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

{
  cargoToNix = path:
    let
     lock = importTOML "${path}/Cargo.lock";

     packages = mapAttrs
       (_: package: mapAttrs (const head) (groupBy (getAttr "version") package))
       (groupBy (getAttr "name") lock.package);

     crates = mapAttrsToList (metadataToCrate packages) lock.metadata;
   in
   runCommand "vendor" {} ''
     mkdir $out

     for f in ${concatStringsSep " " crates}; do
       cp -r $f/* $out
     done
   '';
}
