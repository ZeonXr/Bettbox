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
if ($quickjsContent -notmatch 'static JSValue js_math_min\(JSContext \*ctx, JSValueConst this_val,') {
  $quickjsMathWrappers = @'

static JSValue js_math_min(JSContext *ctx, JSValueConst this_val,
                           int argc, JSValueConst *argv)
{
    return js_math_min_max(ctx, this_val, argc, argv, 0);
}

static JSValue js_math_max(JSContext *ctx, JSValueConst this_val,
                           int argc, JSValueConst *argv)
{
    return js_math_min_max(ctx, this_val, argc, argv, 1);
}
'@
  $quickjsContent = $quickjsContent -replace '(?s)(static JSValue js_math_min_max\(JSContext \*ctx, JSValueConst this_val,\r?\n\s+int argc, JSValueConst \*argv, int magic\)\r?\n\{.*?\r?\n\})(\r?\n\r?\nstatic double js_math_sign)', "`$1$quickjsMathWrappers`$2"
}
$quickjsContent = $quickjsContent -replace 'JS_CFUNC_MAGIC_DEF\("min", 2, js_math_min_max, 0 \)', 'JS_CFUNC_DEF("min", 2, js_math_min )'
$quickjsContent = $quickjsContent -replace 'JS_CFUNC_MAGIC_DEF\("max", 2, js_math_min_max, 1 \)', 'JS_CFUNC_DEF("max", 2, js_math_max )'
if ($quickjsContent -notmatch 'static JSValue js_math_min\(JSContext \*ctx, JSValueConst this_val,' -or
    $quickjsContent -notmatch 'JS_CFUNC_DEF\("min", 2, js_math_min \)' -or
    $quickjsContent -notmatch 'JS_CFUNC_DEF\("max", 2, js_math_max \)') {
  throw 'Failed to patch QuickJS Math.min/Math.max for MSVC.'
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

$hadCc = Test-Path Env:CC
$hadCxx = Test-Path Env:CXX
$previousCc = $env:CC
$previousCxx = $env:CXX
if (Test-Path Env:CC) {
  Remove-Item Env:CC
}
if (Test-Path Env:CXX) {
  Remove-Item Env:CXX
}

$cmakeConfigureArgs = @(
  '-S', (Join-Path $sourceRoot 'windows'),
  '-B', $buildRoot,
  '-G', 'Visual Studio 17 2022',
  '-A', 'ARM64'
)
try {
  Invoke-NativeCommand $cmakeExe $cmakeConfigureArgs
  Invoke-NativeCommand $cmakeExe @('--build', $buildRoot, '--config', 'Release')
}
finally {
  if ($hadCc) {
    $env:CC = $previousCc
  }
  else {
    Remove-Item Env:CC -ErrorAction SilentlyContinue
  }
  if ($hadCxx) {
    $env:CXX = $previousCxx
  }
  else {
    Remove-Item Env:CXX -ErrorAction SilentlyContinue
  }
}

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

$dumpbinCommand = Get-Command dumpbin.exe -ErrorAction SilentlyContinue
if ($dumpbinCommand) {
  & $dumpbinCommand.Source /headers $OutputDll | Select-String -Pattern 'machine'
}
