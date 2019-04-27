{ pkgs ? import <nixpkgs> {}
, purs ? "v0.12.3" 
}:
let
  compiler = (import ./purs.nix { inherit pkgs; }).${purs};

  getExtension = path: with builtins;
    let parts = pkgs.lib.splitString "." path;
    in elemAt parts (length parts - 1);

  isPurs = path: getExtension path == "purs";
  isJs   = path: getExtension path == "js";

  walkFiles = root: with builtins;
    concatLists (attrValues (mapAttrs (key: value:
      if value == "regular"
      then [(root + "/${key}")]
      else walkFiles (root + "/${key}")) (readDir root)));

  walkFilesRel = root: with builtins;
    map (path: substring (stringLength (toString root))
                         (stringLength (toString path))
                         (toString path))
        (walkFiles root);

  tsortDeps = package-set: deps:
    (pkgs.lib.toposort (a: b: builtins.elem a package-set.${b}.dependencies) deps).result;

  flattenDeps = package-set: with pkgs.lib;
    foldl' (accum: dep: unique (accum ++ [dep] ++ flattenDeps package-set package-set.${dep}.dependencies)) [];

  flattenCompiledDeps  = deps: builtins.attrValues (flattenCompiledDeps' deps);
  flattenCompiledDeps' = with pkgs.lib;
    foldl' (accum: dep: accum // { ${dep._args.name} = dep; } // flattenCompiledDeps' dep._args.dependencies) {};

  compilePackage =
    { name
    , src
    , dependencies
    , sources        # list of relative (stringy) paths
    , foreigns       # list of relative (stringy) paths
    } @ args :
    let
      deps = flattenCompiledDeps dependencies;
      depInputs = map (dep: map (f: "${dep.src}/${f}") dep._args.sources) deps;
      srcInputs = map (f: "${src}/${f}") sources;
      pursInputs = depInputs ++ srcInputs;
    in
    pkgs.stdenv.mkDerivation {
      name = "purescript-" + name;
      inherit src;
      buildInputs = [ compiler ];
      buildCommand = with builtins; ''
        mkdir -p $out

        ${if length deps == 0 then "" else ''
        for outdir in ${toString (map (dep: "${dep}/*") deps)}; do
          if [ ! -e "$out/$(basename $outdir)" ]; then
            ln -s $outdir $out
          fi
        done
        ''}

        purs compile --output $out ${toString pursInputs}
      '';

    } // {
      _args = args; # Need to hang on to these

      env = pkgs.mkShell {
        PURS_FILES = toString depInputs;
        buildInputs = [
          compiler
        ];
      };
    };

  compileDependencies = package-set: deps:
    builtins.attrValues (
      builtins.foldl'
        (accum: name: let info = package-set.${name}; in accum // {
          ${name} = compilePackage {
            inherit name;
            src = pkgs.fetchgit {
              url = info.repo;
              rev = info.version;
              sha256 = info.sha256;
            };
            # deps is topologically sorted, so listed dependencies should
            # already be in accum
            dependencies = builtins.map (dep: accum.${dep}) info.dependencies;
            sources = builtins.attrValues info.sources;
            foreigns = info.foreigns;
          };
        })
        {}
        (tsortDeps package-set (flattenDeps package-set deps))
    );
in
{
  compile = { name, src, srcDirs, dependencies, package-set }:
    let
      inputs =
        builtins.concatMap
          (dir: map (f: dir + f) (walkFilesRel (src + "/${dir}")))
          srcDirs;
    in
    compilePackage {
        name = name;
        inherit src;
        dependencies = compileDependencies package-set dependencies;
        sources = builtins.filter isPurs inputs;
        foreigns = builtins.filter isJs inputs;
    };

  package-sets = with pkgs.lib;
    attrsets.mapAttrs'
      (name: value:
      attrsets.nameValuePair
        (strings.removeSuffix ".json" name)
        (builtins.fromJSON (builtins.readFile (./package-sets + "/${name}"))))
      (attrsets.filterAttrs
        (name: value: value != "directory" && strings.hasSuffix ".json" name)
        (builtins.readDir ./package-sets));

  elaborator = import ./elaborator { inherit pkgs; returnShellEnv = false; };
}
