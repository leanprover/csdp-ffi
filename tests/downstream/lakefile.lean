import Lake
open Lake DSL

package downstream where
  /- This models a cache-producing consumer such as Mathlib. Its Lean module
  traces remain platform-independent while Lake still fetches CSDP's native
  artifact and writes the current platform's path into module setup data. -/
  platformIndependent := true

require CSDP from "../.."

lean_lib DownstreamPlain

lean_lib DownstreamPrecompiled where
  precompileModules := true

@[test_driver]
lean_lib DownstreamTest

lean_exe downstream where
  root := `Main
