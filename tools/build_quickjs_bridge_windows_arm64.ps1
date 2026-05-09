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

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
if (-not $OutputDll) {
  $OutputDll = Join-Path $repoRoot 'windows\third_party\flutter_js\arm64\quickjs_c_bridge.dll'
}

if (-not $env:CLANGARM64_BIN) {
  $env:CLANGARM64_BIN = 'C:\clangarm64\bin'
}

$clangExe = Join-Path $env:CLANGARM64_BIN 'clang.exe'
$clangxxExe = Join-Path $env:CLANGARM64_BIN 'clang++.exe'
if (-not (Test-Path $clangExe)) {
  throw "clang.exe not found at $clangExe"
}
if (-not (Test-Path $clangxxExe)) {
  throw "clang++.exe not found at $clangxxExe"
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

$nmakeCommand = Get-Command nmake.exe -ErrorAction SilentlyContinue
$nmakeExe = if ($nmakeCommand) { $nmakeCommand.Source } else { $null }
if (-not $nmakeExe) {
  $visualStudioRoots = @(
    'C:\Program Files\Microsoft Visual Studio',
    'C:\Program Files (x86)\Microsoft Visual Studio'
  ) | Where-Object { Test-Path $_ }

  $nmakeExe = Get-ChildItem $visualStudioRoots -Recurse -Filter 'nmake.exe' |
    Where-Object { $_.FullName -match '\\Host(arm64|x64)\\arm64\\nmake\.exe$' } |
    Select-Object -First 1 -ExpandProperty FullName
}
if (-not $nmakeExe) {
  throw 'nmake.exe for ARM64 was not found in PATH or Visual Studio tools'
}
$env:PATH = "$(Split-Path -Parent $nmakeExe);$env:PATH"

$rcExe = Get-ChildItem 'C:\Program Files (x86)\Windows Kits\10\bin' -Recurse -Filter 'rc.exe' |
  Where-Object { $_.FullName -match '\\arm64\\rc\.exe$' } |
  Select-Object -First 1 -ExpandProperty FullName
if (-not $rcExe) {
  throw 'rc.exe not found in Windows Kits 10'
}

$clangExeForCmake = $clangExe -replace '\\', '/'
$clangxxExeForCmake = $clangxxExe -replace '\\', '/'
$nmakeExeForCmake = $nmakeExe -replace '\\', '/'
$rcExeForCmake = $rcExe -replace '\\', '/'

$cmakeExe = 'C:\Program Files\CMake\bin\cmake.exe'
if (-not (Test-Path $cmakeExe)) {
  $cmakeExe = 'cmake'
}

$cmakeConfigureArgs = @(
  '-S', (Join-Path $sourceRoot 'windows'),
  '-B', $buildRoot,
  '-G', 'NMake Makefiles',
  '-DCMAKE_BUILD_TYPE=Release',
  "-DCMAKE_C_COMPILER=$clangExeForCmake",
  "-DCMAKE_CXX_COMPILER=$clangxxExeForCmake",
  "-DCMAKE_RC_COMPILER=$rcExeForCmake",
  "-DCMAKE_MAKE_PROGRAM=$nmakeExeForCmake"
)
Invoke-NativeCommand $cmakeExe $cmakeConfigureArgs

Invoke-NativeCommand $cmakeExe @('--build', $buildRoot)

$outputDirectory = Split-Path -Parent $OutputDll
New-Item -ItemType Directory -Force -Path $outputDirectory | Out-Null
Copy-Item (Join-Path $buildRoot 'quickjs_c_bridge.dll') $OutputDll -Force

$dumpbinCommand = Get-Command dumpbin.exe -ErrorAction SilentlyContinue
if ($dumpbinCommand) {
  & $dumpbinCommand.Source /headers $OutputDll | Select-String -Pattern 'machine'
}
