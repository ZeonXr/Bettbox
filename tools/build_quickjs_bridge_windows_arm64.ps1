param(
  [string]$OutputDll
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Invoke-NativeCommand {
  param(
    [Parameter(Mandatory = $true)]
    [string]$FilePath,
    [string[]]$Arguments = @()
  )

  & $FilePath @Arguments
  if ($LASTEXITCODE -ne 0) {
    throw "$FilePath failed with exit code $LASTEXITCODE"
  }
}

function Resolve-NinjaPath {
  $ninjaCommand = Get-Command ninja.exe -ErrorAction SilentlyContinue
  if ($ninjaCommand) {
    return $ninjaCommand.Source
  }

  $knownNinjaPaths = @(
    (Join-Path $env:ProgramFiles 'CMake\bin\ninja.exe'),
    (Join-Path $env:ProgramFiles 'Microsoft Visual Studio\2022\Enterprise\Common7\IDE\CommonExtensions\Microsoft\CMake\Ninja\ninja.exe'),
    (Join-Path $env:ProgramFiles 'Microsoft Visual Studio\2022\Professional\Common7\IDE\CommonExtensions\Microsoft\CMake\Ninja\ninja.exe'),
    (Join-Path $env:ProgramFiles 'Microsoft Visual Studio\2022\Community\Common7\IDE\CommonExtensions\Microsoft\CMake\Ninja\ninja.exe'),
    (Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\2022\BuildTools\Common7\IDE\CommonExtensions\Microsoft\CMake\Ninja\ninja.exe')
  )
  foreach ($knownNinjaPath in $knownNinjaPaths) {
    if ($knownNinjaPath -and (Test-Path $knownNinjaPath)) {
      return $knownNinjaPath
    }
  }

  throw 'ninja.exe was not found. Install Ninja or make it available on PATH.'
}

function Resolve-ClangArm64Bin {
  if ($env:CLANGARM64_BIN -and (Test-Path $env:CLANGARM64_BIN)) {
    return (Resolve-Path $env:CLANGARM64_BIN).Path
  }
  if ($env:CLANGARM64_ROOT) {
    $binPath = Join-Path $env:CLANGARM64_ROOT 'bin'
    if (Test-Path $binPath) {
      return (Resolve-Path $binPath).Path
    }
  }
  if ($env:CC -and (Test-Path $env:CC)) {
    return (Split-Path -Parent (Resolve-Path $env:CC).Path)
  }
  if (Test-Path 'C:\clangarm64\bin') {
    return (Resolve-Path 'C:\clangarm64\bin').Path
  }

  throw 'llvm-mingw ARM64 toolchain was not found. Expected CLANGARM64_BIN, CLANGARM64_ROOT, CC, or C:\clangarm64\bin.'
}

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
if (-not $OutputDll) {
  $OutputDll = Join-Path $repoRoot 'windows\third_party\flutter_js\arm64\quickjs_c_bridge.dll'
}

$workingRoot = Join-Path $env:RUNNER_TEMP 'bettbox-quickjs-arm64'
$sourceRoot = Join-Path $workingRoot 'quickjs-c-bridge'
$buildRoot = Join-Path $workingRoot 'build'

if (Test-Path $workingRoot) {
  Remove-Item -Recurse -Force $workingRoot
}
New-Item -ItemType Directory -Force -Path $workingRoot | Out-Null

Invoke-NativeCommand git @('clone', '--depth', '1', 'https://github.com/abner/quickjs-c-bridge', $sourceRoot)

$quickjsPath = Join-Path $sourceRoot 'cxx\quickjs\quickjs.c'
$libregexpPath = Join-Path $sourceRoot 'cxx\quickjs\libregexp.c'

$quickjsContent = Get-Content $quickjsPath -Raw
if ($quickjsContent -notmatch 'return \(uintptr_t\)_AddressOfReturnAddress\(\);') {
  $quickjsContent = $quickjsContent -replace 'return _AddressOfReturnAddress\(\);', 'return (uintptr_t)_AddressOfReturnAddress();'
}
if ($quickjsContent -notmatch 'return \(uintptr_t\)__builtin_frame_address\(0\);') {
  $quickjsContent = $quickjsContent -replace 'return __builtin_frame_address\(0\);', 'return (uintptr_t)__builtin_frame_address(0);'
}
if ($quickjsContent -notmatch 'JSClassID JS_GetClassID\(JSValueConst obj\)\r?\n\{\r?\n    JSObject \*p;\r?\n    if \(JS_VALUE_GET_TAG\(obj\) != JS_TAG_OBJECT\)\r?\n        return 0;') {
  $quickjsContent = $quickjsContent -replace '(JSClassID JS_GetClassID\(JSValueConst obj\)\r?\n\{\r?\n    JSObject \*p;\r?\n    if \(JS_VALUE_GET_TAG\(obj\) != JS_TAG_OBJECT\)\r?\n        )return NULL;', '${1}return 0;'
}
if ($quickjsContent -notmatch '#include <WinSock2.h>\r?\n#include <malloc.h>') {
  $quickjsContent = $quickjsContent -replace '#include <WinSock2.h>\r?\n', "#include <WinSock2.h>`r`n#include <malloc.h>`r`n"
}
Set-Content -Path $quickjsPath -Value $quickjsContent -NoNewline

$libregexpContent = Get-Content $libregexpPath -Raw
if ($libregexpContent -notmatch '#ifdef _MSC_VER\r?\n#include <malloc.h>\r?\n#endif') {
  $libregexpContent = $libregexpContent -replace '#include <assert.h>\r?\n', "#include <assert.h>`r`n`r`n#ifdef _MSC_VER`r`n#include <malloc.h>`r`n#endif`r`n"
}
Set-Content -Path $libregexpPath -Value $libregexpContent -NoNewline

$cmakeExe = 'C:\Program Files\CMake\bin\cmake.exe'
if (-not (Test-Path $cmakeExe)) {
  $cmakeExe = 'cmake'
}

$clangArm64Bin = Resolve-ClangArm64Bin
$clangExe = Join-Path $clangArm64Bin 'clang.exe'
$clangxxExe = Join-Path $clangArm64Bin 'clang++.exe'
if (-not (Test-Path $clangExe)) {
  throw "clang.exe was not found at $clangExe"
}
if (-not (Test-Path $clangxxExe)) {
  throw "clang++.exe was not found at $clangxxExe"
}
$ninjaExe = Resolve-NinjaPath

$cmakeConfigureArgs = @(
  '-S', (Join-Path $sourceRoot 'windows'),
  '-B', $buildRoot,
  '-G', 'Ninja',
  '-DCMAKE_BUILD_TYPE=Release',
  "-DCMAKE_C_COMPILER=$clangExe",
  "-DCMAKE_CXX_COMPILER=$clangxxExe",
  "-DCMAKE_MAKE_PROGRAM=$ninjaExe"
)
Invoke-NativeCommand $cmakeExe $cmakeConfigureArgs
Invoke-NativeCommand $cmakeExe @('--build', $buildRoot)

$outputDirectory = Split-Path -Parent $OutputDll
New-Item -ItemType Directory -Force -Path $outputDirectory | Out-Null
$builtDll = @(
  Get-ChildItem $buildRoot -Filter 'quickjs_c_bridge.dll' -Recurse -ErrorAction SilentlyContinue
  Get-ChildItem $buildRoot -Filter 'libquickjs_c_bridge.dll' -Recurse -ErrorAction SilentlyContinue
) | Select-Object -First 1
if (-not $builtDll) {
  $availableDlls = Get-ChildItem $buildRoot -Filter '*.dll' -Recurse -ErrorAction SilentlyContinue |
    Select-Object -ExpandProperty FullName
  throw "quickjs_c_bridge.dll was not found in $buildRoot. Available DLLs: $($availableDlls -join ', ')"
}
Copy-Item $builtDll.FullName $OutputDll -Force

$quickJsDll = Get-ChildItem $buildRoot -Filter 'quickjs.dll' -Recurse -ErrorAction SilentlyContinue |
  Select-Object -First 1
if ($quickJsDll) {
  Copy-Item $quickJsDll.FullName (Join-Path $outputDirectory 'quickjs.dll') -Force
}

$runtimeDllNames = @(
  'libc++.dll',
  'libc++abi.dll',
  'libunwind.dll',
  'libwinpthread-1.dll',
  'libgcc_s_seh-1.dll',
  'libssp-0.dll'
)
foreach ($runtimeDllName in $runtimeDllNames) {
  $runtimeDll = Join-Path $clangArm64Bin $runtimeDllName
  if (Test-Path $runtimeDll) {
    Copy-Item $runtimeDll (Join-Path $outputDirectory $runtimeDllName) -Force
  }
}

$llvmObjdump = Join-Path $clangArm64Bin 'llvm-objdump.exe'
if (Test-Path $llvmObjdump) {
  $dependencyNames = & $llvmObjdump -p $OutputDll |
    ForEach-Object {
      if ($_ -match 'DLL Name:\s*(.+\.dll)') {
        $Matches[1]
      }
    }
  foreach ($dependencyName in $dependencyNames) {
    $dependencyDll = Join-Path $clangArm64Bin $dependencyName
    if (Test-Path $dependencyDll) {
      Copy-Item $dependencyDll (Join-Path $outputDirectory $dependencyName) -Force
    }
  }
}

$dumpbinCommand = Get-Command dumpbin.exe -ErrorAction SilentlyContinue
if ($dumpbinCommand) {
  & $dumpbinCommand.Source /headers $OutputDll | Select-String -Pattern 'machine'
}
