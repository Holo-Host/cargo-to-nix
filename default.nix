{ lib, fetchurl, runCommand, writeText, python3, remarshal }:

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
    {
      url = head urlAndQuery;
      ref = last queryParams;
      rev = last urlAndRevision;
    };

  resolveSubPackage = name: source:
    let
      cargo = importTOML "${source}/Cargo.toml";

      subPackageName = path:
        (importTOML "${source}/${path}/Cargo.toml").package.name;

      subPackageMatch =
        head (filter (path: subPackageName path == name) cargo.workspace.members);
    in
    if cargo ? "workspace"
      then "${source}/${subPackageMatch}"
      else source;

  fetchGitCrate = name: url:
    let
      source = fetchGit (parseGitURL url);
    in
    resolveSubPackage name source;

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

  cargoConfigSnippet = gitCoord: ''
    [source."${gitCoord.url}"]
    "branch" = "${gitCoord.ref}"
    "git" = "${gitCoord.url}"
    "replace-with" = "vendored-sources"
  '';

  cargoConfig = gitCoords: writeText "cargo-config.toml" ''
    [source."crates-io"]
    "replace-with" = "vendored-sources"

    ${concatStringsSep "\n" (map cargoConfigSnippet gitCoords)}

    [source."vendored-sources"]
    "directory" = "@vendor@"
  '';

  parseMeta = meta:
    let
      metaList = splitString " " meta;
    in
    {
      name = elemAt metaList 1;
      version = elemAt metaList 2;
    };

  fetchCrate = packages: meta: hash:
    let
      inherit (parseMeta meta) name version;

      source = if hash == "<none>"
        then fetchGitCrate name packages."${name}"."${version}".source
        else unpack (fetchurl {
          url = "https://crates.io/api/v1/crates/${name}/${version}/download";
          name = "${name}-${version}.tar.gz";
          sha256 = hash;
        });

      prefix = name + optionalString (!isNewestVersion version (attrNames packages."${name}")) "-${version}";
    in
    mkCrate hash prefix source;

  buildRustPackage = rustPlatform: { cargoDir ? ".", cargoSha256 ? null, cargoVendorDir ? null, ... } @ args:
    if cargoSha256 == null && cargoVendorDir == null
    then (rustPlatform.buildRustPackage (args // { cargoVendorDir = "vendor"; })).overrideAttrs (super: {
      preConfigure = (super.preConfigure or "") + ''
        cp -Lr ${cargoToNix super.src} ${super.cargoVendorDir}
        chmod -R +w ${super.cargoVendorDir}

        mkdir -p .cargo
        substitute vendor/.cargo/config .cargo/config \
          --replace @vendor@ ${super.cargoVendorDir}

        pushd ${super.cargoDir}
      '';

      preInstall = (super.preInstall or "") + ''
        popd
      '';
    })
    else rustPlatform.buildRustPackage args;

  cargoToNix = path:
    let
     lock = importTOML "${path}/Cargo.lock";

     packages = mapAttrs
       (_: package: mapAttrs (const head) (groupBy (getAttr "version") package))
       (groupBy (getAttr "name") lock.package);

     gitPackages = filter (package: hasAttr "source" package && hasPrefix "git+https" package.source) lock.package;
     gitCoords = unique (map (package: parseGitURL package.source) gitPackages);

     crates = mapAttrsToList (fetchCrate packages) lock.metadata;
   in
   runCommand "vendor" {} ''
     mkdir -p $out/.cargo

     ln -s ${cargoConfig gitCoords} $out/.cargo/config

     for f in ${concatStringsSep " " crates}; do
       cp -r $f/* $out
     done
   '';
in

{ inherit buildRustPackage cargoToNix; }
