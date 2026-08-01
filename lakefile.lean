import Lake
open System Lake DSL

/-! ## Platform-specific BLAS / LAPACK linkage. -/

/--
Linker arguments for the BLAS / LAPACK runtime CSDP requires.

* macOS: link Apple's `Accelerate` framework. Lake passes `--sysroot`
  pointing at the Lean toolchain directory (which has no system frameworks),
  so we override with a later `-isysroot` pointing at a real macOS SDK. We
  hard-code the Command Line Tools SDK path because (a) it is the most
  universally available across user machines and CI runners and (b) `Lake`'s
  configuration phase has no clean way to call `xcrun` at load time.
* Linux: reference BLAS + LAPACK packages plus the gfortran runtime
  (LAPACK is Fortran code).
* Windows (MSYS2 / mingw-w64): the OpenBLAS package, which bundles BLAS,
  LAPACK, and the Fortran runtime.
-/
def macSdkPath : String :=
  "/Library/Developer/CommandLineTools/SDKs/MacOSX.sdk"

def linuxLibDirs : Array FilePath := #[
  "/usr/lib/x86_64-linux-gnu",
  "/usr/lib/aarch64-linux-gnu",
  "/usr/lib64",
  "/usr/lib"
]

def windowsLibDirs (pkgDir : FilePath) : Array FilePath := #[
  pkgDir / "vendor" / "mingw-libs",
  "C:/msys64/mingw64/lib"
]

/-- Optional search paths for non-standard installations, notably Nix. The
value uses the platform's ordinary search-path separator. -/
private def configuredLibDirs : IO (Array FilePath) := do
  let some value ← IO.getEnv "CSDP_NATIVE_LIB_DIRS"
    | return #[]
  return (System.SearchPath.parse value).toArray

private def linkSearchArgs (dirs : Array FilePath) : Array String :=
  dirs.map fun dir => s!"-L{dir}"

private def blasLapackLinkArgs (pkgDir : FilePath) : IO (Array String) := do
  let configured ← configuredLibDirs
  if System.Platform.isOSX then
    -- Pass the SDK path as a linker flag so it overrides Lake's earlier
    -- `--sysroot` pointing at the Lean toolchain.
    return #[s!"-Wl,-syslibroot,{macSdkPath}", "-framework", "Accelerate"]
  else if System.Platform.isWindows then
    -- The MSYS2 mingw64 install dir varies (default `C:\msys64`, GitHub
    -- runner setup-msys2 places it under `RUNNER_TEMP`). CI stages import
    -- libraries under the package root; standard local installs are also
    -- searched.
    return linkSearchArgs (configured ++ windowsLibDirs pkgDir) ++
      #["-lopenblas", "-lgfortran", "-lquadmath", "-lm"]
  else
    -- We use `-l:libgfortran.so.5` (the SONAME of the runtime library) so
    -- linking does not depend on the gfortran-dev package leaving an
    -- unversioned `libgfortran.so` symlink behind.
    return linkSearchArgs (configured ++ linuxLibDirs) ++
      #["-llapack", "-lblas", "-l:libgfortran.so.5", "-lm"]

private def windowsOpenblasDll (pkgDir : FilePath) : IO FilePath := do
  let configured ← configuredLibDirs
  let libDirs := configured ++ windowsLibDirs pkgDir
  let siblingBins := libDirs.filterMap fun dir =>
    dir.parent.map (· / "bin")
  let mut dirs := configured ++ siblingBins
  let mingwRoot? ← IO.getEnv "MINGW_PREFIX"
  if let some mingwRoot := mingwRoot? then
    dirs := dirs.push ((mingwRoot : FilePath) / "bin")
  dirs := dirs.push "C:/msys64/mingw64/bin"
  for dir in dirs do
    let path := dir / "libopenblas.dll"
    if ← path.pathExists then
      return path
  throw <| IO.userError s!"csdp-ffi: could not find libopenblas.dll in:
    {dirs.toList}"

private def dirContainsPrefix (dir : FilePath) (prefixes : Array String) :
    IO Bool := do
  let entries ← try
    dir.readDir
  catch _ =>
    return false
  return entries.any fun entry =>
    let name := entry.fileName
    prefixes.any fun p => name.startsWith p

private def someDirContainsPrefix (dirs : Array FilePath)
    (prefixes : Array String) : IO Bool := do
  dirs.anyM fun dir => dirContainsPrefix dir prefixes

private def someDirContainsExact (dirs : Array FilePath) (name : String) :
    IO Bool :=
  dirs.anyM fun dir => (dir / name).pathExists

private def missingNativeDepsMessage (pkgDir : FilePath) : IO (Option String) := do
  if System.Platform.isOSX then
    let sdkOk ← (macSdkPath : FilePath).isDir
    let accelOk ← ((macSdkPath : FilePath) / "System" / "Library" / "Frameworks" /
      "Accelerate.framework")
      |>.isDir
    if sdkOk && accelOk then
      return none
    return some s!"csdp-ffi: missing macOS native dependency for CSDP.\n\n\
      Expected the Command Line Tools SDK at:\n\
        {macSdkPath}\n\n\
      Install it with:\n\
        xcode-select --install\n\n\
      If Xcode is installed but the CLT SDK path is absent, create the SDK \
      link used by this lakefile:\n\
        sudo mkdir -p /Library/Developer/CommandLineTools/SDKs\n\
        sudo ln -sfn $(xcrun --show-sdk-path) {macSdkPath}"
  else if System.Platform.isWindows then
    let dirs := (← configuredLibDirs) ++ windowsLibDirs pkgDir
    let openblasOk ← someDirContainsPrefix dirs #["libopenblas", "openblas"]
    let gfortranOk ← someDirContainsPrefix dirs #["libgfortran", "gfortran"]
    let quadmathOk ← someDirContainsPrefix dirs #["libquadmath", "quadmath"]
    if openblasOk && gfortranOk && quadmathOk then
      return none
    return some s!"csdp-ffi: missing Windows native dependencies for CSDP.\n\n\
      Expected OpenBLAS/gfortran/quadmath import libraries in one of:\n\
        {pkgDir / "vendor" / "mingw-libs"}\n\
        C:/msys64/mingw64/lib\n\n\
      In an MSYS2 MINGW64 shell, install them with:\n\
        pacman -S mingw-w64-x86_64-openblas mingw-w64-x86_64-gcc-fortran\n\n\
      If MSYS2 is not installed at C:/msys64, copy the relevant \
      libopenblas*, libgfortran*, and libquadmath* files from \
      $MINGW_PREFIX/lib into vendor/mingw-libs/ before running lake build."
  else
    let dirs := (← configuredLibDirs) ++ linuxLibDirs
    let lapackOk ← someDirContainsPrefix dirs #["liblapack.so", "liblapack.a"]
    let blasOk ← someDirContainsPrefix dirs #["libblas.so", "libblas.a"]
    -- The link arg is `-l:libgfortran.so.5`, which requires that exact
    -- filename; matching the prefix would falsely pass when only a
    -- versioned file like `libgfortran.so.5.0.0` is present without the
    -- SONAME symlink.
    let gfortranOk ← someDirContainsExact dirs "libgfortran.so.5"
    if lapackOk && blasOk && gfortranOk then
      return none
    return some "csdp-ffi: missing Linux native dependencies for CSDP.\n\n\
      Expected BLAS, LAPACK, and the gfortran runtime in a standard system \
      library directory.\n\n\
      On Debian/Ubuntu, install:\n\
        sudo apt-get install liblapack-dev libblas-dev gfortran\n\n\
      On Fedora/RHEL, install:\n\
        sudo dnf install lapack-devel blas-devel gcc-gfortran\n\n\
      The lakefile links with -llapack -lblas -l:libgfortran.so.5, so the \
      corresponding development/runtime packages must be visible to the \
      system linker. For a non-standard installation, set \
      CSDP_NATIVE_LIB_DIRS to a platform search-path list of library \
      directories."

private def checkNativeDepsJob (pkg : Package) : FetchM (Job Unit) :=
  Job.async (caption := "csdp-ffi native dependency check") do
    addPlatformTrace
    if let some msg ← missingNativeDepsMessage pkg.dir then
      error msg

package CSDP

/-! ## CSDP object compilation. -/

def csdpSrcs : Array String := #[
  "Fnorm.c", "add_mat.c", "addscaledmat.c", "allocmat.c",
  "calc_dobj.c", "calc_pobj.c", "chol.c", "copy_mat.c",
  "easysdp.c", "freeprob.c", "initparams.c", "initsoln.c",
  "linesearch.c", "make_i.c", "makefill.c", "mat_mult.c",
  "mat_multsp.c", "matvec.c", "norms.c", "op_a.c", "op_at.c",
  "op_o.c", "packed.c", "psd_feas.c", "qreig.c", "readprob.c",
  "readsol.c", "sdp.c", "solvesys.c", "sortentries.c",
  "sym_mat.c", "trace_prod.c", "tweakgap.c", "user_exit.c",
  "writeprob.c", "writesol.c", "zero_mat.c"
]

def csdpCFlags (pkg : Package) : Array String :=
  let inc := pkg.dir / "vendored" / "csdp" / "include"
  -- CSDP's source uses K&R-style definitions and unprototyped declarations
  -- (`int foo()` meaning "any args"). Modern C compilers default to C23,
  -- where `()` means `(void)` and the K&R bodies are reported as
  -- prototype mismatches. Force gnu89 so the legacy semantics apply, and
  -- silence the residual -W warnings.
  #[ "-O2", "-DBIT64", "-DNOSHORTS", "-fPIC", "-std=gnu89",
     "-Wno-implicit-function-declaration",
     "-Wno-deprecated-non-prototype",
     "-Wno-old-style-definition",
     "-I", inc.toString ]

private def csdpOTarget (pkg : Package) (nativeDeps : Job Unit) (src : String) :
    FetchM (Job FilePath) := do
  let stem := src.dropEnd 2
  let oFile := pkg.dir / defaultBuildDir / "csdp" / s!"{stem}.o"
  let srcTarget ← inputTextFile <| pkg.dir / "vendored" / "csdp" / "lib" / src
  buildFileAfterDep oFile (srcTarget.add nativeDeps) fun srcFile => do
    compileO oFile srcFile (csdpCFlags pkg)

/-! ## Lean ↔ CSDP bridge. -/

def bridgeSrcs : Array String := #["lean_csdp.c", "lean_csdp_bridge.c"]

private def bridgeOTarget (pkg : Package) (src : String) :
    FetchM (Job FilePath) := do
  let stem := src.dropEnd 2
  let oFile := pkg.dir / defaultBuildDir / "ffi" / s!"{stem}.o"
  let srcTarget ← inputTextFile <| pkg.dir / "ffi" / src
  buildFileAfterDep oFile srcTarget fun srcFile => do
    let leanInc := (← getLeanIncludeDir).toString
    let csdpInc := (pkg.dir / "vendored" / "csdp" / "include").toString
    let ffiInc  := (pkg.dir / "ffi").toString
    compileO oFile srcFile #[
      "-O2", "-DBIT64", "-fPIC",
      "-I", leanInc,
      "-I", csdpInc,
      "-I", ffiInc
    ]

/-- Private archive containing the CSDP solver.

This is deliberately a custom target rather than an `extern_lib`: registering
the unresolved archive as an `extern_lib` would make Lake add it to every
downstream executable without also propagating its BLAS/LAPACK link arguments.
Only the fully resolved shared artifact below is part of CSDP's exported link
interface. -/
target csdpStatic (pkg) : FilePath := do
  let name := nameToStaticLib "csdp"
  let nativeDeps ← checkNativeDepsJob pkg
  let csdpOs ← csdpSrcs.mapM (csdpOTarget pkg nativeDeps)
  buildStaticLib (pkg.staticLibDir / name) csdpOs

/-- macOS/Linux shared library that owns the CSDP solver and resolves its
BLAS/LAPACK/Fortran (or Accelerate) dependencies at the provider boundary.
Windows uses the combined bridge archive and OpenBLAS artifact below to avoid
cross-runtime allocation. -/
target csdpDynlib pkg : Dynlib := do
  let staticJob ← csdpStatic.fetch
  let linkArgs ← blasLapackLinkArgs pkg.dir
  staticJob.mapM fun staticLib => do
    addPureTrace linkArgs "native link arguments"
    addPlatformTrace
    let path := pkg.staticLibDir / nameToSharedLib "csdp"
    let artifact ← buildArtifactUnlessUpToDate path (ext := sharedLibExt)
        (restore := true) do
      let wholeArchiveArgs :=
        if System.Platform.isOSX then
          #[s!"-Wl,-force_load,{staticLib}"]
        else
          #["-Wl,--whole-archive", staticLib.toString,
            "-Wl,--no-whole-archive"]
      compileSharedLib path (wholeArchiveArgs ++ linkArgs) "cc"
    return {path := artifact.path, name := "csdp"}

/-- The Windows OpenBLAS DLL as an exported link artifact. CSDP and
the Lean bridge remain in one native archive on Windows so allocations never
cross the MinGW/Lean C-runtime boundary; this artifact supplies their external
BLAS/LAPACK symbols without leaking raw flags to consumers. -/
target windowsOpenblas pkg : Dynlib := do
  let path ← windowsOpenblasDll pkg.dir
  let input ← inputFile path false
  return input.map fun path => ({path, name := "openblas"} : Dynlib)

/-- Lean ↔ C bridge archive used both to construct the shared bridge and to
provide native executables with bridge code bound directly to their runtime. -/
target csdpBridgeStatic (pkg) : FilePath := do
  -- Give the Windows archive a link-only basename distinct from the
  -- interpreter DLL. This makes `-lcsdp_bridge_link` unambiguously static.
  let name := nameToStaticLib <|
    if System.Platform.isWindows then "csdp_bridge_link" else "csdp_bridge"
  let bridgeOs ← bridgeSrcs.mapM (bridgeOTarget pkg)
  if System.Platform.isWindows then
    let nativeDeps ← checkNativeDepsJob pkg
    let csdpOs ← csdpSrcs.mapM (csdpOTarget pkg nativeDeps)
    buildStaticLib (pkg.staticLibDir / name) (csdpOs ++ bridgeOs)
  else
    buildStaticLib (pkg.staticLibDir / name) bridgeOs

/-- Lean ↔ C bridge with an explicit dependency on the solver DLL. Module setup
loads `csdpDynlib` before this bridge on Windows. The shared object deliberately
leaves its Lean runtime references unresolved so they bind to the host editor,
interpreter, or executable rather than introducing a second Lean runtime. -/
target csdpBridgeDynlib pkg : Dynlib := do
  let bridgeJob ← csdpBridgeStatic.fetch
  if System.Platform.isWindows then
    let openblasJob ← windowsOpenblas.fetch
    let linkArgs ← blasLapackLinkArgs pkg.dir
    bridgeJob.bindM (sync := true) fun bridge => do
    openblasJob.mapM fun openblas => do
      addPureTrace linkArgs "native link arguments"
      addPlatformTrace
      let path := pkg.staticLibDir / nameToSharedLib "csdp_bridge"
      let artifact ← buildArtifactUnlessUpToDate path (ext := sharedLibExt)
          (restore := true) do
        let lean ← getLeanInstall
        let args :=
          #["-Wl,--whole-archive", bridge.toString,
            "-Wl,--no-whole-archive"] ++
          linkArgs ++ #["-L", lean.leanLibDir.toString] ++
          lean.ccLinkSharedFlags
        compileSharedLib path args lean.cc
      return {path := artifact.path, name := "csdp_bridge", deps := #[openblas]}
  else
    let csdpJob ← csdpDynlib.fetch
    csdpJob.bindM (sync := true) fun csdp => do
      let dir := csdp.dir?.getD pkg.staticLibDir
      let linkArgs :=
        #["-L", dir.toString, s!"-Wl,-rpath,{dir}", s!"-l{csdp.name}"]
      let sharedJob ← buildLeanSharedLibOfStatic bridgeJob #[] linkArgs
      sharedJob.mapM fun path =>
        return {path, name := "csdp_bridge", deps := #[csdp]}

/-- Windows link view of the bridge. Lake records the loadable
`csdp_bridge.dll` path in module setup, while `-lcsdp_bridge_link` can only
select the distinct combined static archive. -/
target windowsBridgeLink _pkg : Dynlib := do
  let bridgeJob ← csdpBridgeDynlib.fetch
  return bridgeJob.map fun bridge => {bridge with name := "csdp_bridge_link"}

/-- Check that the platform BLAS/LAPACK runtime expected by `lake build`
is visible before invoking the native linker. -/
script checkNativeDeps (_args) do
  let cwd ← IO.currentDir
  if let some msg ← missingNativeDepsMessage cwd then
    IO.eprintln msg
    return 1
  IO.println "csdp-ffi: native dependencies look available."
  return 0

/-! ## Lean library and executables.

On macOS and Linux, the CSDP Lean library exports the resolved solver and Lean
bridge as ordered `Dynlib`s. On Windows, the bridge archive also contains the
solver: keeping both sides of CSDP-owned allocations in the same binary avoids
cross-runtime heap corruption. Native targets link that archive and the
exported OpenBLAS DLL; editor and interpreter processes load its
combined DLL. Module precompilation remains enabled: that is the Lake
mechanism which makes an imported library's shared facet available to
downstream test drivers, `#eval`, and editor processes. It does not change the
native link inputs selected by `moreLinkObjs` and `moreLinkLibs`, so native
executables do not acquire the interpreter bridge's `libInit_shared.dll`
dependency.
-/

@[default_target]
lean_lib CSDP where
  precompileModules := true
  dynlibs :=
    if System.Platform.isWindows then
      #[`@/csdpBridgeDynlib]
    else
      #[`@/csdpDynlib, `@/csdpBridgeDynlib]
  moreLinkObjs :=
    if System.Platform.isWindows then #[] else #[`@/csdpBridgeStatic]
  moreLinkLibs :=
    if System.Platform.isWindows then
      -- The bridge targets build both `csdp_bridge_link.a` and
      -- `csdp_bridge.dll`. The distinct `csdp_bridge_link` name selects only
      -- the combined archive for module/executable links, while Lake records
      -- and loads the DLL path for interpreter setup.
      #[`@/windowsBridgeLink]
    else
      #[`@/csdpDynlib, `@/csdpBridgeDynlib]

lean_exe «csdp-example» where
  root := `Main
