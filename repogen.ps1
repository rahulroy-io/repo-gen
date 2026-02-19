#!/usr/bin/env pwsh
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$ToolVersion = '0.1.0'

function Exit-WithError {
    param(
        [string]$Message,
        [int]$Code = 2,
        [string]$Format = 'text'
    )
    if ($Format -eq 'json') {
        $obj = @{ error = $Message; exitCode = $Code }
        [Console]::Error.WriteLine(($obj | ConvertTo-Json -Depth 10 -Compress))
    }
    else {
        [Console]::Error.WriteLine("ERROR: $Message")
    }
    exit $Code
}

function Get-Usage {
@"
repogen - spec-driven repository scaffolder (safe by default)

Usage:
  pwsh ./repogen.ps1 [command] --spec <file> --output <dir> [options]
  pwsh ./repogen.ps1 --help

Commands:
  validate   Validate a spec file only
  plan       Build and print a generation plan (default command)
  apply      Execute generation plan (requires --yes)
  help       Show this help

Options (GNU style; aliases in parentheses):
  --help (-h)                    Show help
  --spec <file> (-s)             Path to JSON spec
  --output <dir> (-o)            Output root (required for plan/apply)
  --format <text|json> (-v)      Output format (default: text)
  --on-conflict <policy>         fail|skip|overwrite|prompt (default: fail)
  --allow-path <glob>            Allowlist glob (repeatable; relative to output)
  --plan-out <file>              Write plan JSON to file
  --yes (-y)                     Confirm apply intent (required for apply)
  --force (-f)                   Required together with --on-conflict overwrite
  --allow-existing-root          Allow apply into an existing output root
  --strict                       Strict validation mode
  --schema <value>               Accepted but ignored for now

Examples:
  pwsh ./repogen.ps1 --spec ./examples/spec.example.json --output ./out
  pwsh ./repogen.ps1 plan --spec ./examples/spec.example.json --output ./out --format json
  pwsh ./repogen.ps1 validate --spec ./examples/spec.example.json --strict
  pwsh ./repogen.ps1 apply --spec ./examples/spec.example.json --output ./out --yes --allow-existing-root
"@
}

function Parse-Args {
    param([string[]]$Args)

    $opts = [ordered]@{
        Command = 'plan'
        Help = $false
        Spec = $null
        Output = $null
        Format = 'text'
        OnConflict = 'fail'
        AllowPath = @()
        PlanOut = $null
        Yes = $false
        Force = $false
        AllowExistingRoot = $false
        Strict = $false
        Schema = $null
    }

    $i = 0
    if ($Args.Length -gt 0 -and @('validate','plan','apply','help') -contains $Args[0]) {
        $opts.Command = $Args[0]
        $i = 1
    }

    while ($i -lt $Args.Length) {
        $arg = $Args[$i]
        switch ($arg) {
            '--help' { $opts.Help = $true; $i++; continue }
            '-h' { $opts.Help = $true; $i++; continue }
            '--yes' { $opts.Yes = $true; $i++; continue }
            '-y' { $opts.Yes = $true; $i++; continue }
            '--force' { $opts.Force = $true; $i++; continue }
            '-f' { $opts.Force = $true; $i++; continue }
            '--allow-existing-root' { $opts.AllowExistingRoot = $true; $i++; continue }
            '--strict' { $opts.Strict = $true; $i++; continue }
            '--spec' { $i++; if ($i -ge $Args.Length) { Exit-WithError '--spec requires a value.' 2 $opts.Format }; $opts.Spec = $Args[$i]; $i++; continue }
            '-s' { $i++; if ($i -ge $Args.Length) { Exit-WithError '-s requires a value.' 2 $opts.Format }; $opts.Spec = $Args[$i]; $i++; continue }
            '--output' { $i++; if ($i -ge $Args.Length) { Exit-WithError '--output requires a value.' 2 $opts.Format }; $opts.Output = $Args[$i]; $i++; continue }
            '-o' { $i++; if ($i -ge $Args.Length) { Exit-WithError '-o requires a value.' 2 $opts.Format }; $opts.Output = $Args[$i]; $i++; continue }
            '--format' { $i++; if ($i -ge $Args.Length) { Exit-WithError '--format requires a value.' 2 $opts.Format }; $opts.Format = $Args[$i]; $i++; continue }
            '-v' { $i++; if ($i -ge $Args.Length) { Exit-WithError '-v requires a value.' 2 $opts.Format }; $opts.Format = $Args[$i]; $i++; continue }
            '--on-conflict' { $i++; if ($i -ge $Args.Length) { Exit-WithError '--on-conflict requires a value.' 2 $opts.Format }; $opts.OnConflict = $Args[$i]; $i++; continue }
            '--allow-path' { $i++; if ($i -ge $Args.Length) { Exit-WithError '--allow-path requires a value.' 2 $opts.Format }; $opts.AllowPath += $Args[$i]; $i++; continue }
            '--plan-out' { $i++; if ($i -ge $Args.Length) { Exit-WithError '--plan-out requires a value.' 2 $opts.Format }; $opts.PlanOut = $Args[$i]; $i++; continue }
            '--schema' { $i++; if ($i -ge $Args.Length) { Exit-WithError '--schema requires a value.' 2 $opts.Format }; $opts.Schema = $Args[$i]; $i++; continue }
            default { Exit-WithError "Unknown argument: $arg" 2 $opts.Format }
        }
    }

    return [pscustomobject]$opts
}

function Get-PropValue {
    param([object]$Obj, [string]$Prop)
    if ($null -eq $Obj) { return $null }
    $propInfo = $Obj.PSObject.Properties[$Prop]
    if ($null -eq $propInfo) { return $null }
    return $propInfo.Value
}

function Get-ValueByPath {
    param([hashtable]$Context, [string]$Path)
    $parts = $Path -split '\.'
    $current = $Context
    foreach ($part in $parts) {
        if ($current -is [hashtable]) {
            if (-not $current.ContainsKey($part)) { return $null }
            $current = $current[$part]
        }
        elseif ($current -is [System.Collections.IDictionary]) {
            if (-not $current.Contains($part)) { return $null }
            $current = $current[$part]
        }
        else {
            $current = Get-PropValue -Obj $current -Prop $part
            if ($null -eq $current) { return $null }
        }
    }
    return $current
}

function Convert-ToPackageName {
    param([string]$Name)
    $tmp = $Name.ToLowerInvariant() -replace '[^a-z0-9]+', '_' -replace '_+', '_'
    return $tmp.Trim('_')
}

function Get-SpecHash {
    param([string]$Path)
    $bytes = [IO.File]::ReadAllBytes($Path)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        return (($sha.ComputeHash($bytes) | ForEach-Object { $_.ToString('x2') }) -join '')
    }
    finally { $sha.Dispose() }
}

function Test-IsWindows {
    return [System.Runtime.InteropServices.RuntimeInformation]::IsOSPlatform([System.Runtime.InteropServices.OSPlatform]::Windows)
}

function Test-IsSubPath {
    param([string]$Root, [string]$Candidate)
    $comparison = if (Test-IsWindows) { [System.StringComparison]::OrdinalIgnoreCase } else { [System.StringComparison]::Ordinal }
    $normalizedRoot = [IO.Path]::GetFullPath($Root)
    if (-not $normalizedRoot.EndsWith([IO.Path]::DirectorySeparatorChar)) {
        $normalizedRoot += [IO.Path]::DirectorySeparatorChar
    }
    $normalizedCandidate = [IO.Path]::GetFullPath($Candidate)
    return $normalizedCandidate.StartsWith($normalizedRoot, $comparison)
}

function Convert-ToPosixRelative {
    param([string]$Root, [string]$Path)
    $rel = [IO.Path]::GetRelativePath([IO.Path]::GetFullPath($Root), [IO.Path]::GetFullPath($Path))
    return ($rel -replace '\\', '/')
}

function Test-GlobMatch {
    param([string]$Text, [string]$Glob)
    $escaped = [Regex]::Escape($Glob)
    $escaped = $escaped -replace '\\\*\*', '___DOUBLESTAR___'
    $escaped = $escaped -replace '\\\*', '[^/]*'
    $escaped = $escaped -replace '___DOUBLESTAR___', '.*'
    $escaped = $escaped -replace '\\\?', '.'
    return $Text -match "^$escaped$"
}

function Get-PlaceholdersFromTemplate {
    param([string]$TemplateText)
    return ([regex]::Matches($TemplateText, '\$\{([a-zA-Z0-9_.-]+)\}') | ForEach-Object { $_.Groups[1].Value })
}

function Render-Template {
    param([string]$TemplateText, [hashtable]$Context)
    return [regex]::Replace($TemplateText, '\$\{([a-zA-Z0-9_.-]+)\}', {
        param($m)
        $path = $m.Groups[1].Value
        $value = Get-ValueByPath -Context $Context -Path $path
        if ($null -eq $value) {
            throw "Unresolved placeholder: ${path}"
        }
        if ($value -is [string] -or $value -is [ValueType]) {
            return [string]$value
        }
        return ($value | ConvertTo-Json -Compress -Depth 20)
    })
}

function Validate-Spec {
    param([pscustomobject]$Spec, [bool]$Strict)

    if ($Spec.specVersion -ne '1.0') { throw 'specVersion must be "1.0".' }

    if (-not (Get-PropValue $Spec 'repo')) { throw 'repo is required.' }
    if ([string]::IsNullOrWhiteSpace([string](Get-PropValue $Spec.repo 'name'))) { throw 'repo.name is required and must be non-empty.' }

    if (-not (Get-PropValue $Spec 'archetype')) { throw 'archetype is required.' }
    if ([string]::IsNullOrWhiteSpace([string](Get-PropValue $Spec.archetype 'type'))) { throw 'archetype.type is required and must be non-empty.' }

    $components = Get-PropValue $Spec.archetype 'components'
    if ($null -eq $components -or -not ($components -is [System.Collections.IEnumerable])) { throw 'archetype.components is required and must be an array of non-empty strings.' }
    foreach ($comp in $components) {
        if ([string]::IsNullOrWhiteSpace([string]$comp)) { throw 'archetype.components must contain only non-empty strings.' }
    }

    $paramsVal = Get-PropValue $Spec 'params'
    if ($null -ne $paramsVal -and -not ($paramsVal -is [System.Collections.IDictionary] -or $paramsVal -is [pscustomobject])) {
        throw 'params must be an object when provided.'
    }

    if ($Strict) {
        $topAllowed = @('specVersion','repo','archetype','params')
        foreach ($prop in $Spec.PSObject.Properties.Name) { if ($topAllowed -notcontains $prop) { throw "Unknown top-level key in strict mode: $prop" } }

        $repoAllowed = @('name')
        foreach ($prop in $Spec.repo.PSObject.Properties.Name) { if ($repoAllowed -notcontains $prop) { throw "Unknown repo key in strict mode: $prop" } }

        $archAllowed = @('type','variant','components','features')
        foreach ($prop in $Spec.archetype.PSObject.Properties.Name) { if ($archAllowed -notcontains $prop) { throw "Unknown archetype key in strict mode: $prop" } }
    }
}

function Get-TemplateFiles {
    param([string]$ScriptRoot, [pscustomobject]$Spec)
    $templateRoot = Join-Path $ScriptRoot 'templates'
    $selected = @()

    foreach ($component in $Spec.archetype.components) {
        $componentRoot = Join-Path $templateRoot $component
        if (-not (Test-Path -LiteralPath $componentRoot -PathType Container)) {
            Exit-WithError "Template component directory missing: templates/$component" 4
        }
        $files = Get-ChildItem -LiteralPath $componentRoot -Recurse -File | Where-Object { $_.Name.EndsWith('.tmpl') }
        foreach ($f in $files) {
            $selected += [pscustomobject]@{ File = $f; Root = $componentRoot; TemplateRel = "templates/$component/" + (Convert-ToPosixRelative $componentRoot $f.FullName) }
        }
    }

    $variant = Get-PropValue $Spec.archetype 'variant'
    if (-not [string]::IsNullOrWhiteSpace([string]$variant)) {
        $archRoot = Join-Path (Join-Path $templateRoot $Spec.archetype.type) $variant
        if (Test-Path -LiteralPath $archRoot -PathType Container) {
            $files = Get-ChildItem -LiteralPath $archRoot -Recurse -File | Where-Object { $_.Name.EndsWith('.tmpl') }
            foreach ($f in $files) {
                $selected += [pscustomobject]@{ File = $f; Root = $archRoot; TemplateRel = "templates/$($Spec.archetype.type)/$variant/" + (Convert-ToPosixRelative $archRoot $f.FullName) }
            }
        }
    }
    return $selected
}

function Build-Context {
    param([pscustomobject]$Spec)
    $params = Get-PropValue $Spec 'params'
    if ($null -eq $params) { $params = @{} }
    if ($params -isnot [hashtable]) {
        $hash = @{}
        foreach ($p in $params.PSObject.Properties) { $hash[$p.Name] = $p.Value }
        $params = $hash
    }
    return @{
        repo = $Spec.repo
        archetype = $Spec.archetype
        params = $params
        derived = @{ package_name = Convert-ToPackageName $Spec.repo.name }
    }
}

function Build-Plan {
    param([string]$OutputRoot, [pscustomobject]$Spec, [string[]]$AllowPathGlobs, [bool]$Strict, [string]$ScriptRoot)

    $context = Build-Context -Spec $Spec
    $templates = Get-TemplateFiles -ScriptRoot $ScriptRoot -Spec $Spec

    $mkdirSet = [System.Collections.Generic.HashSet[string]]::new()
    $writeOps = New-Object System.Collections.Generic.List[object]
    $conflicts = New-Object System.Collections.Generic.List[string]
    $allPlaceholders = New-Object System.Collections.Generic.HashSet[string]

    $fullOutputRoot = [IO.Path]::GetFullPath($OutputRoot)

    foreach ($entry in $templates) {
        $destRel = (Convert-ToPosixRelative $entry.Root $entry.File.FullName)
        if (-not $destRel.EndsWith('.tmpl')) { continue }
        $destRel = $destRel.Substring(0, $destRel.Length - 5)
        $destRel = $destRel -replace '\\', '/'

        $destFull = [IO.Path]::GetFullPath((Join-Path $fullOutputRoot ($destRel -replace '/', [IO.Path]::DirectorySeparatorChar)))
        if (-not (Test-IsSubPath -Root $fullOutputRoot -Candidate $destFull)) {
            Exit-WithError "Illegal destination path outside output root: $destRel" 2
        }

        if ($AllowPathGlobs.Count -gt 0) {
            $matched = $false
            foreach ($glob in $AllowPathGlobs) {
                if (Test-GlobMatch -Text $destRel -Glob $glob) { $matched = $true; break }
            }
            if (-not $matched) {
                Exit-WithError "Destination path '$destRel' is not allowed by --allow-path." 2
            }
        }

        $dirRel = [IO.Path]::GetDirectoryName($destRel -replace '/', [IO.Path]::DirectorySeparatorChar)
        if (-not [string]::IsNullOrWhiteSpace($dirRel)) {
            $mkdirSet.Add(($dirRel -replace '\\', '/')) | Out-Null
        }

        $templateText = [IO.File]::ReadAllText($entry.File.FullName)
        $placeholders = Get-PlaceholdersFromTemplate -TemplateText $templateText
        foreach ($ph in $placeholders) { $allPlaceholders.Add($ph) | Out-Null }

        if ($Strict) {
            foreach ($ph in $placeholders) {
                $resolved = Get-ValueByPath -Context $context -Path $ph
                if ($null -eq $resolved) {
                    throw "Strict mode unresolved placeholder '$ph' in $($entry.TemplateRel)"
                }
            }
        }

        if (Test-Path -LiteralPath $destFull -PathType Leaf) {
            $conflicts.Add($destRel)
        }

        $writeOps.Add([pscustomobject]@{ path = $destRel; template = $entry.TemplateRel; destFull = $destFull; templateFull = $entry.File.FullName })
    }

    if ($Strict -and $context.params.Count -gt 0) {
        foreach ($k in $context.params.Keys) {
            if (-not $allPlaceholders.Contains("params.$k")) {
                throw "Strict mode unused param: params.$k"
            }
        }
    }

    $mkdir = @($mkdirSet.ToArray() | Sort-Object)
    $writePlan = @($writeOps | ForEach-Object { [pscustomobject]@{ path = $_.path; template = $_.template } })

    return [pscustomobject]@{
        mkdir = $mkdir
        writeFile = $writePlan
        conflicts = @($conflicts)
        summary = [pscustomobject]@{
            mkdirCount = $mkdir.Count
            writeFileCount = $writePlan.Count
            conflictCount = $conflicts.Count
        }
        _internalWriteOps = $writeOps
        _resolvedComponents = @($Spec.archetype.components)
    }
}

function Write-PlanOutput {
    param([pscustomobject]$Plan, [string]$Format, [string]$PlanOut)
    $publicPlan = [pscustomobject]@{
        mkdir = $Plan.mkdir
        writeFile = $Plan.writeFile
        conflicts = $Plan.conflicts
        summary = $Plan.summary
    }

    $planJson = $publicPlan | ConvertTo-Json -Depth 20
    if ($PlanOut) {
        $planPath = [IO.Path]::GetFullPath($PlanOut)
        $parent = Split-Path -Parent $planPath
        if ($parent -and -not (Test-Path -LiteralPath $parent)) {
            New-Item -ItemType Directory -Path $parent -Force | Out-Null
        }
        [IO.File]::WriteAllText($planPath, $planJson)
    }

    if ($Format -eq 'json') {
        Write-Output $planJson
    }
    else {
        Write-Output "Plan:"
        Write-Output "  mkdir ($($Plan.summary.mkdirCount))"
        foreach ($d in $Plan.mkdir) { Write-Output "    - $d" }
        Write-Output "  writeFile ($($Plan.summary.writeFileCount))"
        foreach ($w in $Plan.writeFile) { Write-Output "    - $($w.path) <= $($w.template)" }
        if ($Plan.summary.conflictCount -gt 0) {
            Write-Output "  conflicts ($($Plan.summary.conflictCount))"
            foreach ($c in $Plan.conflicts) { Write-Output "    - $c" }
        }
    }
}

function Apply-Plan {
    param([pscustomobject]$Plan, [string]$OutputRoot, [string]$OnConflict, [bool]$Force, [pscustomobject]$Spec, [string]$SpecPath)

    if ($OnConflict -eq 'overwrite' -and -not $Force) {
        Exit-WithError 'Overwrite conflict policy requires --force.' 2
    }

    $fullOutputRoot = [IO.Path]::GetFullPath($OutputRoot)
    if (-not (Test-Path -LiteralPath $fullOutputRoot)) {
        New-Item -ItemType Directory -Path $fullOutputRoot -Force | Out-Null
    }

    foreach ($d in $Plan.mkdir) {
        $dirPath = Join-Path $fullOutputRoot ($d -replace '/', [IO.Path]::DirectorySeparatorChar)
        New-Item -ItemType Directory -Path $dirPath -Force | Out-Null
    }

    $generated = New-Object System.Collections.Generic.List[object]

    foreach ($op in $Plan._internalWriteOps) {
        $dir = Split-Path -Parent $op.destFull
        if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }

        $exists = Test-Path -LiteralPath $op.destFull -PathType Leaf
        if ($exists) {
            switch ($OnConflict) {
                'fail' { Exit-WithError "Conflict on existing file: $($op.path)" 3 }
                'skip' { continue }
                'overwrite' { }
                'prompt' {
                    if (-not [Console]::IsInputRedirected) {
                        $resp = Read-Host "Overwrite $($op.path)? [y/N]"
                        if ($resp -notin @('y','Y','yes','YES')) { continue }
                    }
                    else {
                        Exit-WithError "Conflict on existing file: $($op.path) (prompt is non-interactive)" 3
                    }
                }
                default { Exit-WithError "Invalid --on-conflict policy: $OnConflict" 2 }
            }
        }

        $templateText = [IO.File]::ReadAllText($op.templateFull)
        $content = Render-Template -TemplateText $templateText -Context (Build-Context -Spec $Spec)
        [IO.File]::WriteAllText($op.destFull, $content)

        $fileHash = Get-SpecHash -Path $op.destFull
        $generated.Add([pscustomobject]@{ path = $op.path; sha256 = $fileHash })
    }

    $manifestDir = Join-Path $fullOutputRoot '.repogen'
    New-Item -ItemType Directory -Path $manifestDir -Force | Out-Null

    $manifest = [pscustomobject]@{
        specHash = Get-SpecHash -Path $SpecPath
        toolVersion = $ToolVersion
        generatedFiles = @($generated)
        timestamp = [DateTimeOffset]::UtcNow.ToString('o')
        resolvedComponents = $Plan._resolvedComponents
        archetype = [pscustomobject]@{
            type = $Spec.archetype.type
            variant = (Get-PropValue $Spec.archetype 'variant')
        }
    }
    [IO.File]::WriteAllText((Join-Path $manifestDir 'manifest.json'), ($manifest | ConvertTo-Json -Depth 20))
}

try {
    $opts = Parse-Args -Args $args

    if ($opts.Help -or $opts.Command -eq 'help') {
        Write-Output (Get-Usage)
        exit 0
    }

    if ($opts.Format -notin @('text','json')) { Exit-WithError '--format must be text or json.' 2 $opts.Format }
    if ($opts.OnConflict -notin @('fail','skip','overwrite','prompt')) { Exit-WithError '--on-conflict must be fail|skip|overwrite|prompt.' 2 $opts.Format }

    if (-not $opts.Spec) { Exit-WithError '--spec is required.' 2 $opts.Format }
    if (-not (Test-Path -LiteralPath $opts.Spec -PathType Leaf)) { Exit-WithError "Spec file not found: $($opts.Spec)" 2 $opts.Format }

    if ($opts.Command -in @('plan','apply') -and -not $opts.Output) { Exit-WithError '--output is required for plan/apply.' 2 $opts.Format }
    if ($opts.Command -eq 'apply' -and -not $opts.Yes) { Exit-WithError 'apply requires --yes.' 2 $opts.Format }

    $specText = [IO.File]::ReadAllText($opts.Spec)
    $spec = $specText | ConvertFrom-Json
    Validate-Spec -Spec $spec -Strict $opts.Strict

    if ($opts.Command -eq 'validate') {
        if ($opts.Format -eq 'json') { Write-Output (@{ valid = $true } | ConvertTo-Json -Compress) }
        else { Write-Output 'Spec is valid.' }
        exit 0
    }

    $scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
    $outputFull = [IO.Path]::GetFullPath($opts.Output)
    $outputExists = Test-Path -LiteralPath $outputFull -PathType Container

    if ($opts.Command -eq 'apply' -and $outputExists -and -not $opts.AllowExistingRoot) {
        Exit-WithError 'Output root already exists; rerun with --allow-existing-root to proceed.' 2 $opts.Format
    }

    $plan = Build-Plan -OutputRoot $outputFull -Spec $spec -AllowPathGlobs $opts.AllowPath -Strict $opts.Strict -ScriptRoot $scriptRoot

    Write-PlanOutput -Plan $plan -Format $opts.Format -PlanOut $opts.PlanOut

    if ($plan.summary.conflictCount -gt 0 -and $opts.OnConflict -eq 'fail') {
        Exit-WithError "Conflicts detected: $($plan.summary.conflictCount)" 3 $opts.Format
    }

    if ($opts.Command -eq 'apply') {
        Apply-Plan -Plan $plan -OutputRoot $outputFull -OnConflict $opts.OnConflict -Force $opts.Force -Spec $spec -SpecPath $opts.Spec
        if ($opts.Format -eq 'json') { Write-Output (@{ applied = $true } | ConvertTo-Json -Compress) }
        else { Write-Output 'Apply completed successfully.' }
    }

    exit 0
}
catch {
    Exit-WithError $_.Exception.Message 5
}
