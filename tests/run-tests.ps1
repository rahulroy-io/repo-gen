Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'TestHelpers.ps1')

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$spec = Join-Path $repoRoot 'examples/spec.example.json'
$shoppingSpec = Join-Path $repoRoot 'examples/spec.shopping-agent.json'

# 1) plan mode creates no files; returns 0 when no conflicts
$t1 = New-TestDir
$out1 = Join-Path $t1 'out'
$r1 = Invoke-Repogen @('--spec', $spec, '--output', $out1)
Assert-Equal $r1.ExitCode 0 'plan mode exits 0'
Assert-True (-not (Test-Path -LiteralPath $out1)) 'plan mode does not create output root'

# 2) apply without --yes returns exit 2
$t2 = New-TestDir
$out2 = Join-Path $t2 'out'
$r2 = Invoke-Repogen @('apply', '--spec', $spec, '--output', $out2)
Assert-Equal $r2.ExitCode 2 'apply without --yes exits 2'

# 3) apply creates expected files and directories
$t3 = New-TestDir
$out3 = Join-Path $t3 'out'
$r3 = Invoke-Repogen @('apply', '--spec', $spec, '--output', $out3, '--yes')
Assert-Equal $r3.ExitCode 0 'apply exits 0'
Assert-True (Test-Path -LiteralPath (Join-Path $out3 'README.md') -PathType Leaf) 'README generated'
Assert-True (Test-Path -LiteralPath (Join-Path $out3 '.github/workflows/ci.yml') -PathType Leaf) 'workflow generated'
Assert-True (Test-Path -LiteralPath (Join-Path $out3 'src/app.py') -PathType Leaf) 'app generated'
Assert-True (Test-Path -LiteralPath (Join-Path $out3 '.repogen/manifest.json') -PathType Leaf) 'manifest generated'

# 4) conflict default fail returns exit 3
$t4 = New-TestDir
$out4 = Join-Path $t4 'out'
New-Item -ItemType Directory -Path $out4 | Out-Null
New-Item -ItemType File -Path (Join-Path $out4 'README.md') | Out-Null
$r4 = Invoke-Repogen @('plan', '--spec', $spec, '--output', $out4)
Assert-Equal $r4.ExitCode 3 'plan conflicts default fail exits 3'

# 5) output root exists without --allow-existing-root returns 2
$t5 = New-TestDir
$out5 = Join-Path $t5 'out'
New-Item -ItemType Directory -Path $out5 | Out-Null
$r5 = Invoke-Repogen @('apply', '--spec', $spec, '--output', $out5, '--yes')
Assert-Equal $r5.ExitCode 2 'apply existing root without allow flag exits 2'

# 6) allow-path blocks writes outside allowed globs
$t6 = New-TestDir
$out6 = Join-Path $t6 'out'
$r6 = Invoke-Repogen @('plan', '--spec', $spec, '--output', $out6, '--allow-path', 'src/**')
Assert-Equal $r6.ExitCode 2 'allow-path violation exits 2'

# 7) overwrite requires --force
$t7 = New-TestDir
$out7 = Join-Path $t7 'out'
New-Item -ItemType Directory -Path $out7 | Out-Null
Set-Content -Path (Join-Path $out7 'README.md') -Value 'existing'
$r7 = Invoke-Repogen @('apply', '--spec', $spec, '--output', $out7, '--yes', '--allow-existing-root', '--on-conflict', 'overwrite')
Assert-Equal $r7.ExitCode 2 'overwrite without force exits 2'

# 8) shopping-agent archetype generates expected layout
$t8 = New-TestDir
$out8 = Join-Path $t8 'shopping-agent'
$r8 = Invoke-Repogen @('apply', '--spec', $shoppingSpec, '--output', $out8, '--yes')
Assert-Equal $r8.ExitCode 0 'shopping-agent apply exits 0'
Assert-True (Test-Path -LiteralPath (Join-Path $out8 'README.md') -PathType Leaf) 'shopping-agent README generated'
Assert-True (Test-Path -LiteralPath (Join-Path $out8 'pyproject.toml') -PathType Leaf) 'shopping-agent pyproject generated'
Assert-True (Test-Path -LiteralPath (Join-Path $out8 '.gitignore') -PathType Leaf) 'shopping-agent gitignore generated'
Assert-True (Test-Path -LiteralPath (Join-Path $out8 '.env.example') -PathType Leaf) 'shopping-agent env example generated'
Assert-True (Test-Path -LiteralPath (Join-Path $out8 'src/agent_app/__init__.py') -PathType Leaf) 'shopping-agent __init__ generated'
Assert-True (Test-Path -LiteralPath (Join-Path $out8 'src/agent_app/cli.py') -PathType Leaf) 'shopping-agent cli generated'
Assert-True (Test-Path -LiteralPath (Join-Path $out8 'src/agent_app/core.py') -PathType Leaf) 'shopping-agent core generated'
Assert-True (Test-Path -LiteralPath (Join-Path $out8 'tests/test_smoke.py') -PathType Leaf) 'shopping-agent smoke test generated'

Complete-Tests
