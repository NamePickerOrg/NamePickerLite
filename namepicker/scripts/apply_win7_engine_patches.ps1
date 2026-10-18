# Applies the Windows 7 compatibility patches to the Dart SDK checkout that
# Flutter builds its engine with.
#
# The original rustdesk patches target an older Dart revision. Since then:
#   * ToWinAPIFilePath was renamed to ToWinAPIPath.
#   * ToWinAPIPath learned to call PathAllocCanonicalize, another Windows 8+
#     API, which the original file_win.cc patch does not remove.
#   * Call sites in dart.cc and the unwinding record guards moved.
# scripts/win7-engine-patches contains the rebased equivalents.
#
# Usage:
#   pwsh scripts/apply_win7_engine_patches.ps1
#   pwsh scripts/apply_win7_engine_patches.ps1 -CheckOnly
#   pwsh scripts/apply_win7_engine_patches.ps1 -DartDir D:\flutter\engine\src\flutter\third_party\dart
param(
  [string]$DartDir = "",
  [switch]$CheckOnly
)

$ErrorActionPreference = 'Stop'

if (-not $DartDir) {
  $flutter = (Get-Command flutter -ErrorAction Stop).Source
  $flutterRoot = Split-Path (Split-Path $flutter -Parent) -Parent
  $DartDir = Join-Path $flutterRoot 'engine/src/flutter/third_party/dart'
}

if (-not (Test-Path (Join-Path $DartDir 'runtime/bin/platform_win.cc'))) {
  throw "Dart sources not found at $DartDir. Run 'gclient sync' in the Flutter checkout first."
}

$revision = (git -C $DartDir rev-parse HEAD).Trim()
$expected = '04bcd1036cdc799ac6564988f159ee454d42c822'
if ($revision -ne $expected) {
  Write-Warning "Dart revision is $revision, expected $expected for Flutter 3.47.7. Patches may need rebasing."
}

$patchDir = Join-Path $PSScriptRoot 'win7-engine-patches'
$patches = Get-ChildItem -Path $patchDir -Filter '*.patch' | Sort-Object Name
if ($patches.Count -eq 0) {
  throw "No patches found in $patchDir."
}

foreach ($patch in $patches) {
  git -C $DartDir apply --reverse --check $patch.FullName 2>$null | Out-Null
  if ($LASTEXITCODE -eq 0) {
    Write-Host "Already applied: $($patch.Name)"
    continue
  }

  git -C $DartDir apply --check $patch.FullName
  if ($LASTEXITCODE -ne 0) {
    throw "Patch does not apply: $($patch.Name)"
  }

  if ($CheckOnly) {
    Write-Host "Would apply: $($patch.Name)"
  } else {
    git -C $DartDir apply $patch.FullName
    if ($LASTEXITCODE -ne 0) {
      throw "Failed to apply: $($patch.Name)"
    }
    Write-Host "Applied: $($patch.Name)"
  }
}
