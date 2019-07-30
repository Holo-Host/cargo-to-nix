{ pkgs ? import <nixpkgs> {} }:

with pkgs;
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

  mkPrefix = prefix: path: runCommand prefix {} ''
    mkdir $out
    ln -s ${path} $out/${prefix}
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
    mkPrefix prefix source;
in

rec {
  cargoToNix = path:
    let
     lock = importTOML path;

     packages = mapAttrs
       (const (groupBy (getAttr "version")))
       (groupBy (getAttr "name") lock.package);
   in
   buildEnv {
     name = "vendor";
     paths = mapAttrsToList (metadataToCrate packages) lock.metadata;
   };
}
