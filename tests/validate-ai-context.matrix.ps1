#requires -Version 5.1

[CmdletBinding()]
param(
    [switch]$KeepArtifacts
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$repositoryRoot = [System.IO.Path]::GetFullPath((Join-Path -Path $PSScriptRoot -ChildPath '..'))
$initializerPath = Join-Path -Path $repositoryRoot -ChildPath 'scripts\init-ai-context.ps1'
$validatorPath = Join-Path -Path $repositoryRoot -ChildPath 'scripts\validate-ai-context.ps1'
$fixedRelativePaths = @(
    'AGENTS.md',
    'docs\ai-context\CURRENT_STATE.md',
    'docs\ai-context\DEV_LOG.md',
    'docs\ai-context\DECISIONS.md',
    'docs\ai-context\HANDOFF_PROMPT.md'
)
$results = New-Object 'System.Collections.Generic.List[object]'
$aclDiagnostics = $null
$createdTestRoot = $false
$cleanupSucceeded = $false

if (-not (Test-Path -LiteralPath $initializerPath -PathType Leaf)) {
    throw "Initializer not found: $initializerPath"
}
if (-not (Test-Path -LiteralPath $validatorPath -PathType Leaf)) {
    throw "Validator not found: $validatorPath"
}

$hostExecutable = if ($PSVersionTable.PSEdition -eq 'Core') {
    (Get-Process -Id $PID).Path
} else {
    Join-Path -Path $PSHOME -ChildPath 'powershell.exe'
}

function Invoke-PowerShellFile {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ScriptPath,

        [Parameter(Mandatory = $false)]
        [AllowNull()]
        [string]$TargetPath
    )

    $startInfo = New-Object System.Diagnostics.ProcessStartInfo
    $startInfo.FileName = $script:hostExecutable
    $startInfo.Arguments = '-NoProfile -ExecutionPolicy Bypass -File "{0}"' -f $ScriptPath
    if ($PSBoundParameters.ContainsKey('TargetPath')) {
        $startInfo.Arguments += ' -TargetPath "{0}"' -f $TargetPath
    }
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true

    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = $startInfo
    [void]$process.Start()
    $stdout = $process.StandardOutput.ReadToEnd()
    $stderr = $process.StandardError.ReadToEnd()
    $process.WaitForExit()

    return [pscustomobject]@{
        ExitCode = $process.ExitCode
        Stdout = $stdout
        Stderr = $stderr
    }
}

function Get-FileState {
    param(
        [Parameter(Mandatory = $true)]
        [string[]]$Paths
    )

    $state = @{}
    foreach ($path in $Paths) {
        $fullPath = [System.IO.Path]::GetFullPath($path)
        if ([System.IO.File]::Exists($fullPath)) {
            $item = Get-Item -LiteralPath $fullPath -Force
            $state[$fullPath] = '{0}|{1}|{2}' -f (
                (Get-FileHash -LiteralPath $fullPath -Algorithm SHA256).Hash
            ), $item.Length, $item.LastWriteTimeUtc.Ticks
        } else {
            $state[$fullPath] = '<missing>'
        }
    }
    return $state
}

function Test-FileStateEquivalent {
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$Before,

        [Parameter(Mandatory = $true)]
        [hashtable]$After
    )

    if ($Before.Count -ne $After.Count) {
        return $false
    }
    foreach ($key in $Before.Keys) {
        if (-not $After.ContainsKey($key) -or $Before[$key] -cne $After[$key]) {
            return $false
        }
    }
    return $true
}

function Get-FixedPaths {
    param(
        [Parameter(Mandatory = $true)]
        [string]$TargetPath
    )

    return @($script:fixedRelativePaths | ForEach-Object {
        Join-Path -Path $TargetPath -ChildPath $_
    })
}

function New-ValidFixture {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name
    )

    $targetPath = Join-Path -Path $script:testRoot -ChildPath $Name
    if (Test-Path -LiteralPath $targetPath) {
        throw "Fixture path unexpectedly exists: $targetPath"
    }
    [void](New-Item -ItemType Directory -Path $targetPath)
    $initialization = Invoke-PowerShellFile -ScriptPath $script:initializerPath -TargetPath $targetPath
    if ($initialization.ExitCode -ne 0) {
        throw ('Fixture initialization failed with exit {0}: {1}' -f $initialization.ExitCode, $initialization.Stderr.Trim())
    }
    foreach ($path in (Get-FixedPaths -TargetPath $targetPath)) {
        if (-not [System.IO.File]::Exists($path)) {
            throw "Initializer did not create required fixture file: $path"
        }
    }
    return $targetPath
}

function Add-Result {
    param(
        [string]$Case,
        [int]$ExpectedExit,
        [AllowNull()]
        [object]$ActualExit,
        [AllowNull()]
        [object]$ZeroWrite,
        [bool]$PreparationSucceeded,
        [bool]$OutputMatched = $true,
        [string]$Details = ''
    )

    $passed = $PreparationSucceeded -and
        $null -ne $ActualExit -and
        ([int]$ActualExit -eq $ExpectedExit) -and
        ($ZeroWrite -eq $true) -and
        $OutputMatched

    [void]$script:results.Add([pscustomobject]@{
        Case = $Case
        ExpectedExit = $ExpectedExit
        ActualExit = $ActualExit
        ZeroWrite = $ZeroWrite
        PreparationSucceeded = $PreparationSucceeded
        OutputMatched = $OutputMatched
        Result = if ($passed) { 'Passed' } else { 'Failed' }
        Details = $Details
    })
}

function Invoke-DirectoryCase {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Case,

        [Parameter(Mandatory = $true)]
        [string]$FixtureName,

        [Parameter(Mandatory = $true)]
        [int]$ExpectedExit,

        [scriptblock]$Mutation,

        [string[]]$AdditionalTrackedPaths = @(),

        [string]$ExpectedStdoutPattern = ''
    )

    $actualExit = $null
    $zeroWrite = 'NotVerified'
    try {
        $targetPath = New-ValidFixture -Name $FixtureName
        if ($null -ne $Mutation) {
            & $Mutation $targetPath
        }
        $trackedPaths = @((Get-FixedPaths -TargetPath $targetPath) + $AdditionalTrackedPaths)
        $before = Get-FileState -Paths $trackedPaths
        $validation = Invoke-PowerShellFile -ScriptPath $script:validatorPath -TargetPath $targetPath
        $actualExit = $validation.ExitCode
        $after = Get-FileState -Paths $trackedPaths
        $zeroWrite = Test-FileStateEquivalent -Before $before -After $after
        $outputMatched = [string]::IsNullOrWhiteSpace($ExpectedStdoutPattern) -or $validation.Stdout -match $ExpectedStdoutPattern
        $details = if ($outputMatched) { '' } else { "Expected stdout pattern not found: $ExpectedStdoutPattern" }
        Add-Result -Case $Case -ExpectedExit $ExpectedExit -ActualExit $actualExit -ZeroWrite $zeroWrite -PreparationSucceeded $true -OutputMatched $outputMatched -Details $details
    } catch {
        Add-Result -Case $Case -ExpectedExit $ExpectedExit -ActualExit $actualExit -ZeroWrite $zeroWrite -PreparationSucceeded $false -Details $_.Exception.Message
    }
}

function Get-NormalizedAclState {
    param(
        [Parameter(Mandatory = $true)]
        [System.Security.AccessControl.FileSecurity]$Acl
    )

    $owner = $Acl.GetOwner([System.Security.Principal.SecurityIdentifier]).Value
    $rules = @($Acl.GetAccessRules($true, $true, [System.Security.Principal.SecurityIdentifier]) | ForEach-Object {
        '{0}|{1}|{2}|{3}|{4}|{5}' -f $_.IdentityReference.Value,
            $_.AccessControlType,
            ([int64]$_.FileSystemRights),
            $_.IsInherited,
            $_.InheritanceFlags,
            $_.PropagationFlags
    } | Sort-Object)

    return [pscustomobject]@{
        Owner = $owner
        AreAccessRulesProtected = $Acl.AreAccessRulesProtected
        Rules = $rules
    }
}

function Test-StringArrayEquivalent {
    param(
        [string[]]$Left,
        [string[]]$Right
    )

    if ($Left.Count -ne $Right.Count) {
        return $false
    }
    for ($index = 0; $index -lt $Left.Count; $index++) {
        if ($Left[$index] -cne $Right[$index]) {
            return $false
        }
    }
    return $true
}

function Invoke-AclCase {
    $caseName = 'read_denied'
    $expectedExit = 4
    $actualExit = $null
    $zeroWrite = 'NotVerified'
    $preparationSucceeded = $false
    $denyRuleSet = $false
    $validatorRan = $false
    $aclRestored = $false
    $remainingDeny = $null
    $readableHash = $null
    $verifyExit = $null
    $ownerEquivalent = $false
    $protectedEquivalent = $false
    $rulesEquivalent = $false
    $details = New-Object 'System.Collections.Generic.List[string]'
    $originalAcl = $null
    $targetFile = $null
    $before = $null
    $targetPath = $null

    try {
        $targetPath = New-ValidFixture -Name 'case_read_denied'
        $targetFile = Join-Path -Path $targetPath -ChildPath 'AGENTS.md'
        $trackedPaths = Get-FixedPaths -TargetPath $targetPath
        $before = Get-FileState -Paths $trackedPaths
        $originalAcl = Get-Acl -LiteralPath $targetFile
        $originalState = Get-NormalizedAclState -Acl $originalAcl
        $currentSid = [System.Security.Principal.WindowsIdentity]::GetCurrent().User
        $denyRule = New-Object System.Security.AccessControl.FileSystemAccessRule(
            $currentSid,
            [System.Security.AccessControl.FileSystemRights]::Read,
            [System.Security.AccessControl.AccessControlType]::Deny
        )
        $testAcl = Get-Acl -LiteralPath $targetFile
        $testAcl.AddAccessRule($denyRule)
        Set-Acl -LiteralPath $targetFile -AclObject $testAcl
        $denyRuleSet = $true
        $preparationSucceeded = $true

        $validation = Invoke-PowerShellFile -ScriptPath $script:validatorPath -TargetPath $targetPath
        $validatorRan = $true
        $actualExit = $validation.ExitCode
    } catch {
        [void]$details.Add($_.Exception.Message)
    } finally {
        if ($null -ne $originalAcl -and $null -ne $targetFile) {
            try {
                Set-Acl -LiteralPath $targetFile -AclObject $originalAcl
                $aclRestored = $true
            } catch {
                [void]$details.Add(('ACL restore failed for {0}: {1}' -f $targetFile, $_.Exception.Message))
            }
        }
    }

    if ($aclRestored) {
        try {
            $restoredAcl = Get-Acl -LiteralPath $targetFile
            $restoredState = Get-NormalizedAclState -Acl $restoredAcl
            $ownerEquivalent = $originalState.Owner -ceq $restoredState.Owner
            $protectedEquivalent = $originalState.AreAccessRulesProtected -eq $restoredState.AreAccessRulesProtected
            $rulesEquivalent = Test-StringArrayEquivalent -Left $originalState.Rules -Right $restoredState.Rules
            $remainingDeny = @($restoredAcl.GetAccessRules($true, $false, [System.Security.Principal.SecurityIdentifier]) | Where-Object {
                -not $_.IsInherited -and
                $_.IdentityReference.Value -eq $currentSid.Value -and
                $_.AccessControlType -eq [System.Security.AccessControl.AccessControlType]::Deny -and
                (([int64]$_.FileSystemRights -band [int64][System.Security.AccessControl.FileSystemRights]::Read) -ne 0)
            }).Count
            $readableHash = (Get-FileHash -LiteralPath $targetFile -Algorithm SHA256).Hash
            $verification = Invoke-PowerShellFile -ScriptPath $script:validatorPath -TargetPath $targetPath
            $verifyExit = $verification.ExitCode
            $after = Get-FileState -Paths (Get-FixedPaths -TargetPath $targetPath)
            $contentUnchanged = Test-FileStateEquivalent -Before $before -After $after
            $zeroWrite = $contentUnchanged -and
                ($remainingDeny -eq 0) -and
                ($verifyExit -eq 0) -and
                $ownerEquivalent -and
                $protectedEquivalent -and
                $rulesEquivalent
        } catch {
            [void]$details.Add(('ACL verification failed for {0}: {1}' -f $targetFile, $_.Exception.Message))
            $zeroWrite = 'NotVerified'
        }
    }

    $script:aclDiagnostics = [pscustomobject]@{
        DenyRuleSet = $denyRuleSet
        ValidatorRan = $validatorRan
        AclRestored = $aclRestored
        ValidatorExit = $actualExit
        OriginalHash = if ($null -ne $before -and $null -ne $targetFile) { ($before[[System.IO.Path]::GetFullPath($targetFile)] -split '\|')[0] } else { $null }
        ReadableHash = $readableHash
        RemainingExplicitDenyRead = $remainingDeny
        VerifyExit = $verifyExit
        OwnerEquivalent = $ownerEquivalent
        AccessRulesProtectedEquivalent = $protectedEquivalent
        AccessRulesEquivalent = $rulesEquivalent
    }

    Add-Result -Case $caseName -ExpectedExit $expectedExit -ActualExit $actualExit -ZeroWrite $zeroWrite -PreparationSucceeded $preparationSucceeded -Details ($details -join '; ')
}

$testRootName = 'ai_context_validate_stage4_{0}_{1}' -f (Get-Date -Format 'yyyyMMdd_HHmmss'), ([guid]::NewGuid().ToString('N'))
$testRoot = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath $testRootName
if (Test-Path -LiteralPath $testRoot) {
    throw "Unique test root unexpectedly exists; refusing to delete it: $testRoot"
}
[void](New-Item -ItemType Directory -Path $testRoot)
$createdTestRoot = $true

try {
    Invoke-DirectoryCase -Case 'complete_sample' -FixtureName 'case_complete' -ExpectedExit 0

    Invoke-DirectoryCase -Case 'invalid_file_role' -FixtureName 'case_invalid_role' -ExpectedExit 3 -Mutation {
        param($targetPath)
        $path = Join-Path -Path $targetPath -ChildPath 'AGENTS.md'
        $text = [System.IO.File]::ReadAllText($path)
        $expected = 'File Role: stable_project_rules'
        if (-not $text.Contains($expected)) { throw "Expected File Role text not found: $path" }
        [System.IO.File]::WriteAllText($path, $text.Replace($expected, 'File Role: invalid_role'), (New-Object System.Text.UTF8Encoding($false)))
    }

    Invoke-DirectoryCase -Case 'reversed_markers' -FixtureName 'case_reversed_markers' -ExpectedExit 3 -Mutation {
        param($targetPath)
        $path = Join-Path -Path $targetPath -ChildPath 'AGENTS.md'
        $text = [System.IO.File]::ReadAllText($path)
        $start = '<!-- AI_CONTEXT:AGENTS_RULES:START -->'
        $end = '<!-- AI_CONTEXT:AGENTS_RULES:END -->'
        if (-not $text.Contains($start) -or -not $text.Contains($end)) { throw "Expected markers not found: $path" }
        $changed = $text.Replace($start, '__TEST_MARKER__').Replace($end, $start).Replace('__TEST_MARKER__', $end)
        [System.IO.File]::WriteAllText($path, $changed, (New-Object System.Text.UTF8Encoding($false)))
    }

    Invoke-DirectoryCase -Case 'invalid_utf8' -FixtureName 'case_invalid_utf8' -ExpectedExit 3 -Mutation {
        param($targetPath)
        $path = Join-Path -Path $targetPath -ChildPath 'AGENTS.md'
        [System.IO.File]::WriteAllBytes($path, [byte[]](0xC3, 0x28))
    }

    try {
        $parameterSentinel = Join-Path -Path $testRoot -ChildPath 'case_missing_target_parameter.txt'
        [System.IO.File]::WriteAllText($parameterSentinel, 'parameter sentinel', (New-Object System.Text.UTF8Encoding($false)))
        $before = Get-FileState -Paths @($parameterSentinel)
        $validation = Invoke-PowerShellFile -ScriptPath $validatorPath
        $after = Get-FileState -Paths @($parameterSentinel)
        Add-Result -Case 'missing_target_parameter' -ExpectedExit 1 -ActualExit $validation.ExitCode -ZeroWrite (Test-FileStateEquivalent -Before $before -After $after) -PreparationSucceeded $true
    } catch {
        Add-Result -Case 'missing_target_parameter' -ExpectedExit 1 -ActualExit $null -ZeroWrite 'NotVerified' -PreparationSucceeded $false -Details $_.Exception.Message
    }

    try {
        $fileTarget = Join-Path -Path $testRoot -ChildPath 'case_target_is_file.txt'
        [System.IO.File]::WriteAllText($fileTarget, 'target file sentinel', (New-Object System.Text.UTF8Encoding($false)))
        $before = Get-FileState -Paths @($fileTarget)
        $validation = Invoke-PowerShellFile -ScriptPath $validatorPath -TargetPath $fileTarget
        $after = Get-FileState -Paths @($fileTarget)
        Add-Result -Case 'target_path_is_file' -ExpectedExit 2 -ActualExit $validation.ExitCode -ZeroWrite (Test-FileStateEquivalent -Before $before -After $after) -PreparationSucceeded $true
    } catch {
        Add-Result -Case 'target_path_is_file' -ExpectedExit 2 -ActualExit $null -ZeroWrite 'NotVerified' -PreparationSucceeded $false -Details $_.Exception.Message
    }

    try {
        $unlistedTarget = New-ValidFixture -Name 'case_unlisted_file'
        $unlistedPath = Join-Path -Path $unlistedTarget -ChildPath 'unlisted.txt'
        [System.IO.File]::WriteAllText($unlistedPath, 'unlisted sentinel', (New-Object System.Text.UTF8Encoding($false)))
        $trackedPaths = @((Get-FixedPaths -TargetPath $unlistedTarget) + $unlistedPath)
        $before = Get-FileState -Paths $trackedPaths
        $validation = Invoke-PowerShellFile -ScriptPath $validatorPath -TargetPath $unlistedTarget
        $after = Get-FileState -Paths $trackedPaths
        Add-Result -Case 'unlisted_file' -ExpectedExit 0 -ActualExit $validation.ExitCode -ZeroWrite (Test-FileStateEquivalent -Before $before -After $after) -PreparationSucceeded $true
    } catch {
        Add-Result -Case 'unlisted_file' -ExpectedExit 0 -ActualExit $null -ZeroWrite 'NotVerified' -PreparationSucceeded $false -Details $_.Exception.Message
    }

    Invoke-AclCase

    Invoke-DirectoryCase -Case 'missing_required_file' -FixtureName 'case_missing_file' -ExpectedExit 3 -Mutation {
        param($targetPath)
        $path = Join-Path -Path $targetPath -ChildPath 'docs\ai-context\HANDOFF_PROMPT.md'
        if (-not [System.IO.File]::Exists($path)) { throw "Expected file not found before mutation: $path" }
        Remove-Item -LiteralPath $path -Force
    }

    Invoke-DirectoryCase -Case 'empty_required_file' -FixtureName 'case_empty_file' -ExpectedExit 3 -Mutation {
        param($targetPath)
        $path = Join-Path -Path $targetPath -ChildPath 'docs\ai-context\DECISIONS.md'
        if (-not [System.IO.File]::Exists($path)) { throw "Expected file not found before mutation: $path" }
        [System.IO.File]::WriteAllBytes($path, [byte[]]@())
    }

    Invoke-DirectoryCase -Case 'missing_start_marker' -FixtureName 'case_missing_marker' -ExpectedExit 3 -Mutation {
        param($targetPath)
        $path = Join-Path -Path $targetPath -ChildPath 'AGENTS.md'
        $text = [System.IO.File]::ReadAllText($path)
        $start = '<!-- AI_CONTEXT:AGENTS_RULES:START -->'
        if (-not $text.Contains($start)) { throw "Expected START marker not found: $path" }
        [System.IO.File]::WriteAllText($path, $text.Replace($start, ''), (New-Object System.Text.UTF8Encoding($false)))
    }

    Invoke-DirectoryCase -Case 'residual_placeholder' -FixtureName 'case_placeholder' -ExpectedExit 3 -Mutation {
        param($targetPath)
        $path = Join-Path -Path $targetPath -ChildPath 'AGENTS.md'
        $text = [System.IO.File]::ReadAllText($path)
        if ($text -match '\{\{[^{}\r\n]*\}\}') { throw "Fixture already contains a placeholder: $path" }
        [System.IO.File]::WriteAllText($path, ($text + "`r`n{{UNRESOLVED_TEST}}`r`n"), (New-Object System.Text.UTF8Encoding($false)))
    }

    Invoke-DirectoryCase -Case 'schema_version_mismatch' -FixtureName 'case_schema_mismatch' -ExpectedExit 3 -Mutation {
        param($targetPath)
        $path = Join-Path -Path $targetPath -ChildPath 'AGENTS.md'
        $text = [System.IO.File]::ReadAllText($path)
        $expected = 'Context Schema Version: 1'
        if (-not $text.Contains($expected)) { throw "Expected Schema Version text not found: $path" }
        [System.IO.File]::WriteAllText($path, $text.Replace($expected, 'Context Schema Version: 2'), (New-Object System.Text.UTF8Encoding($false)))
    }

    Invoke-DirectoryCase -Case 'duplicate_start_marker' -FixtureName 'case_duplicate_marker' -ExpectedExit 3 -Mutation {
        param($targetPath)
        $path = Join-Path -Path $targetPath -ChildPath 'AGENTS.md'
        $text = [System.IO.File]::ReadAllText($path)
        $start = '<!-- AI_CONTEXT:AGENTS_RULES:START -->'
        if (-not $text.Contains($start)) { throw "Expected START marker not found: $path" }
        [System.IO.File]::WriteAllText($path, $text.Replace($start, ($start + "`r`n" + $start)), (New-Object System.Text.UTF8Encoding($false)))
    }

    Invoke-DirectoryCase -Case 'missing_required_field' -FixtureName 'case_missing_field' -ExpectedExit 3 -Mutation {
        param($targetPath)
        $path = Join-Path -Path $targetPath -ChildPath 'AGENTS.md'
        $text = [System.IO.File]::ReadAllText($path)
        $expected = '- Generated By: ai_context_init v0.1.0'
        if (-not $text.Contains($expected)) { throw "Expected required field not found: $path" }
        [System.IO.File]::WriteAllText($path, $text.Replace($expected, ''), (New-Object System.Text.UTF8Encoding($false)))
    }

    Invoke-DirectoryCase -Case 'illegal_status' -FixtureName 'case_illegal_status' -ExpectedExit 3 -Mutation {
        param($targetPath)
        $path = Join-Path -Path $targetPath -ChildPath 'docs\ai-context\CURRENT_STATE.md'
        $text = [System.IO.File]::ReadAllText($path)
        $statusLabel = ([string][char]0x72B6) + ([string][char]0x6001) + ([string][char]0xFF1A)
        $expected = '- ' + $statusLabel + '`to_confirm`'
        if (-not $text.Contains($expected)) { throw "Expected status field not found: $path" }
        $replacement = '- ' + $statusLabel + '`invalid_status`'
        [System.IO.File]::WriteAllText($path, $text.Replace($expected, $replacement), (New-Object System.Text.UTF8Encoding($false)))
    }

    Invoke-DirectoryCase -Case 'current_state_too_long_warning' -FixtureName 'case_long_current_state' -ExpectedExit 0 -ExpectedStdoutPattern 'WarningsCount:\s*1' -Mutation {
        param($targetPath)
        $path = Join-Path -Path $targetPath -ChildPath 'docs\ai-context\CURRENT_STATE.md'
        $text = [System.IO.File]::ReadAllText($path)
        if ($text.Length -eq 0) { throw "Expected non-empty CURRENT_STATE: $path" }
        [System.IO.File]::WriteAllText($path, ($text + "`r`n" + (([string][char]0x957F) * 1600)), (New-Object System.Text.UTF8Encoding($false)))
    }

    Invoke-DirectoryCase -Case 'handoff_duplicate_status_warning' -FixtureName 'case_handoff_status' -ExpectedExit 0 -ExpectedStdoutPattern 'WarningsCount:\s*1' -Mutation {
        param($targetPath)
        $path = Join-Path -Path $targetPath -ChildPath 'docs\ai-context\HANDOFF_PROMPT.md'
        $text = [System.IO.File]::ReadAllText($path)
        $statusLabel = ([string][char]0x72B6) + ([string][char]0x6001) + ([string][char]0xFF1A)
        if ($text -match ('(?m)^\s*' + [regex]::Escape($statusLabel))) { throw "Fixture already contains copied status text: $path" }
        [System.IO.File]::WriteAllText($path, ($text + "`r`n" + $statusLabel + '`accepted`' + "`r`n"), (New-Object System.Text.UTF8Encoding($false)))
    }

    Invoke-DirectoryCase -Case 'utf8_bom_warning' -FixtureName 'case_utf8_bom' -ExpectedExit 0 -ExpectedStdoutPattern 'WarningsCount:\s*1' -Mutation {
        param($targetPath)
        $path = Join-Path -Path $targetPath -ChildPath 'AGENTS.md'
        $bytes = [System.IO.File]::ReadAllBytes($path)
        if ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) {
            throw "Fixture already contains a UTF-8 BOM: $path"
        }
        $withBom = New-Object byte[] ($bytes.Length + 3)
        $withBom[0] = 0xEF
        $withBom[1] = 0xBB
        $withBom[2] = 0xBF
        [System.Array]::Copy($bytes, 0, $withBom, 3, $bytes.Length)
        [System.IO.File]::WriteAllBytes($path, $withBom)
    }
} finally {
    if ($createdTestRoot -and -not $KeepArtifacts) {
        try {
            $resolvedRoot = [System.IO.Path]::GetFullPath($testRoot)
            $resolvedTemp = [System.IO.Path]::GetFullPath([System.IO.Path]::GetTempPath()).TrimEnd('\') + '\'
            if (-not $resolvedRoot.StartsWith($resolvedTemp, [System.StringComparison]::OrdinalIgnoreCase) -or
                -not ([System.IO.Path]::GetFileName($resolvedRoot)).StartsWith('ai_context_validate_stage4_', [System.StringComparison]::Ordinal)) {
                throw "Cleanup target failed safety check: $resolvedRoot"
            }
            Remove-Item -LiteralPath $resolvedRoot -Recurse -Force
            $cleanupSucceeded = -not (Test-Path -LiteralPath $resolvedRoot)
        } catch {
            $cleanupSucceeded = $false
            Write-Output ('CleanupError={0}' -f $_.Exception.Message)
        }
    } elseif ($KeepArtifacts) {
        $cleanupSucceeded = $true
    }
}

Write-Output ('PowerShellVersion={0}' -f $PSVersionTable.PSVersion.ToString())
Write-Output ('PowerShellEdition={0}' -f $PSVersionTable.PSEdition)
Write-Output ('TestRoot={0}' -f $testRoot)
foreach ($result in $results) {
    Write-Output ('Case={0} ExpectedExit={1} ActualExit={2} ZeroWrite={3} PreparationSucceeded={4} OutputMatched={5} Result={6}' -f
        $result.Case, $result.ExpectedExit, $result.ActualExit, $result.ZeroWrite, $result.PreparationSucceeded, $result.OutputMatched, $result.Result)
    if (-not [string]::IsNullOrWhiteSpace($result.Details)) {
        Write-Output ('CaseDetails={0}: {1}' -f $result.Case, $result.Details)
    }
}

if ($null -ne $aclDiagnostics) {
    foreach ($property in @(
        'DenyRuleSet', 'ValidatorRan', 'AclRestored', 'ValidatorExit', 'OriginalHash', 'ReadableHash',
        'RemainingExplicitDenyRead', 'VerifyExit', 'OwnerEquivalent',
        'AccessRulesProtectedEquivalent', 'AccessRulesEquivalent'
    )) {
        Write-Output ('{0}={1}' -f $property, $aclDiagnostics.$property)
    }
}

$passedCount = @($results | Where-Object { $_.Result -eq 'Passed' }).Count
$failedCount = @($results | Where-Object { $_.Result -ne 'Passed' }).Count
Write-Output ('ResultCount={0}' -f $results.Count)
Write-Output ('PassedCount={0}' -f $passedCount)
Write-Output ('FailedCount={0}' -f $failedCount)
Write-Output ('CleanupResult={0}' -f $(if ($cleanupSucceeded) { 'Passed' } else { 'Failed' }))

if ($results.Count -ne 19 -or $failedCount -ne 0 -or -not $cleanupSucceeded) {
    exit 1
}
exit 0
