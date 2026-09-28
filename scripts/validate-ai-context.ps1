#requires -Version 5.1

[CmdletBinding(PositionalBinding = $false)]
param(
    [Parameter(Mandatory = $false)]
    [string]$TargetPath
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$toolVersion = 'ai_context_validate v0.2.0'
$schemaVersion = '1'
$utf8Strict = New-Object System.Text.UTF8Encoding($false, $true)
$fixedFiles = @(
    [pscustomobject]@{
        RelativePath = 'AGENTS.md'
        Role = 'stable_project_rules'
        Marker = 'AGENTS_RULES'
        RequiredPatterns = @('ProjectName\uFF1A', 'Goal\uFF1A', 'TechStack\uFF1A', '\u672A\u6267\u884C\u6D4B\u8BD5', '\u65E0\u6CD5\u786E\u8BA4')
    },
    [pscustomobject]@{
        RelativePath = 'docs\ai-context\CURRENT_STATE.md'
        Role = 'current_project_state'
        Marker = 'CURRENT_STATE'
        RequiredPatterns = @('ProjectName\uFF1A', 'Goal\uFF1A', 'TechStack\uFF1A', '\u72B6\u6001\uFF1A', '\u9879\u76EE\u6784\u5EFA\uFF1A', '\u9879\u76EE\u6D4B\u8BD5\uFF1A', '\u7528\u6237\u9A8C\u6536\uFF1A')
    },
    [pscustomobject]@{
        RelativePath = 'docs\ai-context\DEV_LOG.md'
        Role = 'append_only_development_log'
        Marker = 'DEV_LOG'
        RequiredPatterns = @('\u9879\u76EE\u6784\u5EFA\uFF1A', '\u9879\u76EE\u6D4B\u8BD5\uFF1A', '\u7528\u6237\u9A8C\u6536\uFF1A')
    },
    [pscustomobject]@{
        RelativePath = 'docs\ai-context\DECISIONS.md'
        Role = 'append_only_decisions'
        Marker = 'DECISIONS'
        RequiredPatterns = @()
    },
    [pscustomobject]@{
        RelativePath = 'docs\ai-context\HANDOFF_PROMPT.md'
        Role = 'conversation_handoff'
        Marker = 'HANDOFF'
        RequiredPatterns = @('\u4EE5\u4E0B\u987A\u5E8F', 'CURRENT_STATE.md')
    }
)

$allowedStatuses = @('planned', 'in_progress', 'completed', 'verified', 'accepted', 'blocked', 'to_confirm', 'not_tested')
$passed = @()
$warnings = @()
$errors = @()
$texts = @{}

function Add-AuditResult {
    param(
        [ValidateSet('Passed', 'Warning', 'Error')]
        [string]$Severity,
        [string]$File,
        [string]$Rule,
        [string]$Reason,
        [string]$Suggestion
    )

    $item = [pscustomobject]@{
        File = $File
        Rule = $Rule
        Reason = $Reason
        Suggestion = $Suggestion
    }

    switch ($Severity) {
        'Passed' { $script:passed += $item }
        'Warning' { $script:warnings += $item }
        'Error' { $script:errors += $item }
    }
}

function Write-AuditResults {
    param(
        [string]$ResolvedPath,
        [int]$ExitCode
    )

    Write-Output ''
    Write-Output 'AI Context audit result'
    Write-Output ('ToolVersion: {0}' -f $toolVersion)
    Write-Output ('SchemaVersion: {0}' -f $schemaVersion)
    Write-Output ('TargetPath: {0}' -f $ResolvedPath)

    foreach ($item in $script:passed) {
        Write-Output ('Passed | {0} | {1} | {2} | {3}' -f $item.File, $item.Rule, $item.Reason, $item.Suggestion)
    }
    foreach ($item in $script:warnings) {
        Write-Output ('Warnings | {0} | {1} | {2} | {3}' -f $item.File, $item.Rule, $item.Reason, $item.Suggestion)
    }
    foreach ($item in $script:errors) {
        Write-Output ('Errors | {0} | {1} | {2} | {3}' -f $item.File, $item.Rule, $item.Reason, $item.Suggestion)
    }

    Write-Output ('PassedCount: {0}' -f $script:passed.Count)
    Write-Output ('WarningsCount: {0}' -f $script:warnings.Count)
    Write-Output ('ErrorsCount: {0}' -f $script:errors.Count)
    Write-Output ('ExitCode: {0}' -f $ExitCode)
}

function Get-SingleFieldValue {
    param(
        [string]$Text,
        [string]$Label
    )

    $pattern = '(?m)^\s*(?:-\s*)?' + [regex]::Escape($Label) + ':\s*(?<value>[^\r\n]+)\s*$'
    $matches = [regex]::Matches($Text, $pattern)
    if ($matches.Count -eq 1) {
        return $matches[0].Groups['value'].Value.Trim()
    }
    return $null
}

if (-not $PSBoundParameters.ContainsKey('TargetPath') -or [string]::IsNullOrWhiteSpace($TargetPath)) {
    Write-Error -ErrorAction Continue -Message 'The required -TargetPath parameter was not provided.'
    exit 1
}

try {
    $resolvedTargetPath = [System.IO.Path]::GetFullPath($TargetPath)
} catch {
    Write-Error -ErrorAction Continue -Message ('TargetPath could not be normalized: {0}' -f $_.Exception.Message)
    exit 2
}

if (-not [System.IO.Directory]::Exists($resolvedTargetPath)) {
    Write-Error -ErrorAction Continue -Message 'TargetPath does not exist or is not a directory.'
    exit 2
}

foreach ($entry in $fixedFiles) {
    $path = [System.IO.Path]::GetFullPath((Join-Path -Path $resolvedTargetPath -ChildPath $entry.RelativePath))
    if (-not [System.IO.File]::Exists($path)) {
        Add-AuditResult -Severity Error -File $entry.RelativePath -Rule 'FR-VAL-01' -Reason 'Required target file is missing.' -Suggestion 'Run the v0.1.0 initializer or restore the file, then audit again.'
        continue
    }

    try {
        $bytes = [System.IO.File]::ReadAllBytes($path)
    } catch {
        Write-Error -ErrorAction Continue -Message ('Could not read target file {0}: {1}' -f $entry.RelativePath, $_.Exception.Message)
        exit 4
    }

    if ($bytes.Length -eq 0) {
        Add-AuditResult -Severity Error -File $entry.RelativePath -Rule 'FR-VAL-01' -Reason 'Target file is empty.' -Suggestion 'Restore non-empty content, then audit again.'
        continue
    }

    if ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) {
        Add-AuditResult -Severity Warning -File $entry.RelativePath -Rule 'Encoding' -Reason 'File contains a UTF-8 BOM.' -Suggestion 'Consider rewriting as UTF-8 without BOM.'
    }

    try {
        $text = $utf8Strict.GetString($bytes)
    } catch {
        Add-AuditResult -Severity Error -File $entry.RelativePath -Rule 'Encoding' -Reason 'File cannot be decoded as UTF-8.' -Suggestion 'Rewrite the file as valid UTF-8, then audit again.'
        continue
    }
    $texts[$entry.RelativePath] = $text
    Add-AuditResult -Severity Passed -File $entry.RelativePath -Rule 'FR-VAL-01' -Reason 'File exists and is non-empty.' -Suggestion 'No action required.'

    $schema = Get-SingleFieldValue -Text $text -Label 'Context Schema Version'
    if ($null -eq $schema) {
        Add-AuditResult -Severity Error -File $entry.RelativePath -Rule 'FR-VAL-02' -Reason 'Context Schema Version is missing or duplicated.' -Suggestion 'Restore one exact Schema Version field with value 1.'
    } elseif ($schema -ne $schemaVersion) {
        Add-AuditResult -Severity Error -File $entry.RelativePath -Rule 'FR-VAL-02' -Reason ('Context Schema Version is {0}, expected {1}.' -f $schema, $schemaVersion) -Suggestion 'Use a compatible Schema Version or stop for migration review.'
    } else {
        Add-AuditResult -Severity Passed -File $entry.RelativePath -Rule 'FR-VAL-02' -Reason 'Context Schema Version is 1.' -Suggestion 'No action required.'
    }

    foreach ($field in @('Generated By', 'Project Name', 'File Role', 'Last Updated', 'Update Mode')) {
        $value = Get-SingleFieldValue -Text $text -Label $field
        if ([string]::IsNullOrWhiteSpace($value)) {
            Add-AuditResult -Severity Error -File $entry.RelativePath -Rule 'FR-VAL-02' -Reason ("{0} is missing, empty, or duplicated." -f $field) -Suggestion 'Restore the required metadata field without adding a second copy.'
        } elseif ($field -eq 'Generated By' -and $value -ne 'ai_context_init v0.1.0') {
            Add-AuditResult -Severity Error -File $entry.RelativePath -Rule 'FR-VAL-02' -Reason ('Generated By is {0}, expected ai_context_init v0.1.0.' -f $value) -Suggestion 'Use the v0.1.0 generator marker defined by the compatibility baseline.'
        } elseif ($field -eq 'Last Updated' -and $value -notmatch '^\d{4}-\d{2}-\d{2}$') {
            Add-AuditResult -Severity Error -File $entry.RelativePath -Rule 'FR-VAL-02' -Reason ('Last Updated is not an ISO date: {0}.' -f $value) -Suggestion 'Use a YYYY-MM-DD date.'
        } elseif ($field -eq 'File Role' -and $value -ne $entry.Role) {
            Add-AuditResult -Severity Error -File $entry.RelativePath -Rule 'FR-VAL-02' -Reason ('File Role is {0}, expected {1}.' -f $value, $entry.Role) -Suggestion 'Restore the role defined by the Schema 1 template.'
        } elseif ($field -eq 'Update Mode' -and $value -notin @('static', 'replace', 'append')) {
            Add-AuditResult -Severity Error -File $entry.RelativePath -Rule 'FR-VAL-02' -Reason ('Update Mode {0} is not allowed.' -f $value) -Suggestion 'Use static, replace, or append as defined by the template.'
        } else {
            Add-AuditResult -Severity Passed -File $entry.RelativePath -Rule 'FR-VAL-02' -Reason ("{0} is present." -f $field) -Suggestion 'No action required.'
        }
    }

    foreach ($requiredPattern in $entry.RequiredPatterns) {
        if (-not [regex]::IsMatch($text, $requiredPattern)) {
            Add-AuditResult -Severity Error -File $entry.RelativePath -Rule 'FR-VAL-02' -Reason ('Required field or rule text is missing: {0}.' -f $requiredPattern) -Suggestion 'Restore the field required by the corresponding v0.1.0 template.'
        } else {
            Add-AuditResult -Severity Passed -File $entry.RelativePath -Rule 'FR-VAL-02' -Reason ('Required field or rule text is present: {0}.' -f $requiredPattern) -Suggestion 'No action required.'
        }
    }

    $startMarker = '<!-- AI_CONTEXT:{0}:START -->' -f $entry.Marker
    $endMarker = '<!-- AI_CONTEXT:{0}:END -->' -f $entry.Marker
    $startCount = ([regex]::Matches($text, [regex]::Escape($startMarker))).Count
    $endCount = ([regex]::Matches($text, [regex]::Escape($endMarker))).Count
    if ($startCount -ne 1 -or $endCount -ne 1) {
        Add-AuditResult -Severity Error -File $entry.RelativePath -Rule 'FR-VAL-03' -Reason ('Expected one START and one END marker; found START={0}, END={1}.' -f $startCount, $endCount) -Suggestion 'Restore one matching marker pair without reordering or nesting it.'
    } elseif ($text.IndexOf($startMarker, [System.StringComparison]::Ordinal) -gt $text.IndexOf($endMarker, [System.StringComparison]::Ordinal)) {
        Add-AuditResult -Severity Error -File $entry.RelativePath -Rule 'FR-VAL-03' -Reason 'START marker occurs after END marker.' -Suggestion 'Restore the marker order from the template.'
    } else {
        Add-AuditResult -Severity Passed -File $entry.RelativePath -Rule 'FR-VAL-03' -Reason 'START/END marker pair is present, unique, and ordered.' -Suggestion 'No action required.'
    }

    $placeholders = [regex]::Matches($text, '\{\{[^{}\r\n]*\}\}')
    if ($placeholders.Count -gt 0) {
        Add-AuditResult -Severity Error -File $entry.RelativePath -Rule 'FR-VAL-04' -Reason ('Found {0} residual placeholder(s).' -f $placeholders.Count) -Suggestion 'Replace or remove unresolved placeholders before relying on the document.'
    } else {
        Add-AuditResult -Severity Passed -File $entry.RelativePath -Rule 'FR-VAL-04' -Reason 'No residual {{...}} placeholders found.' -Suggestion 'No action required.'
    }

    if ($entry.RelativePath -eq 'CURRENT_STATE.md' -or $entry.RelativePath -eq 'docs\ai-context\CURRENT_STATE.md' -or $entry.RelativePath -eq 'docs/ai-context/CURRENT_STATE.md') {
        $nonWhitespace = ([regex]::Replace($text, '\s', '')).Length
        if ($nonWhitespace -gt 1500) {
            Add-AuditResult -Severity Warning -File $entry.RelativePath -Rule 'FR-VAL-04' -Reason ('CURRENT_STATE contains {0} non-whitespace characters, over the 1500 maintenance threshold.' -f $nonWhitespace) -Suggestion 'Consider manually condensing stale detail; this does not invalidate the file.'
        } else {
            Add-AuditResult -Severity Passed -File $entry.RelativePath -Rule 'FR-VAL-04' -Reason ('CURRENT_STATE length is {0} non-whitespace characters.' -f $nonWhitespace) -Suggestion 'No action required.'
        }
    }

    if ($entry.RelativePath -eq 'CURRENT_STATE.md' -or $entry.RelativePath -eq 'docs\ai-context\CURRENT_STATE.md') {
        $statusMatches = [regex]::Matches($text, '(?m)^\s*[-*]?\s*(?:\u72B6\u6001|\u9879\u76EE\u6784\u5EFA|\u9879\u76EE\u6D4B\u8BD5|\u7528\u6237\u9A8C\u6536)\uFF1A\s*`(?<status>[^`]+)`')
        foreach ($statusMatch in $statusMatches) {
            $status = $statusMatch.Groups['status'].Value
            if ($status -notin $allowedStatuses) {
                Add-AuditResult -Severity Error -File $entry.RelativePath -Rule 'FR-VAL-04' -Reason ('Illegal status word: {0}.' -f $status) -Suggestion ('Use one of: {0}.' -f ($allowedStatuses -join ', '))
            }
        }
        if ($statusMatches.Count -gt 0 -and @($statusMatches | Where-Object { $_.Groups['status'].Value -notin $allowedStatuses }).Count -eq 0) {
            Add-AuditResult -Severity Passed -File $entry.RelativePath -Rule 'FR-VAL-04' -Reason 'Defined CURRENT_STATE status fields use allowed status words.' -Suggestion 'No action required.'
        }
    }

    if ($entry.RelativePath -eq 'docs\ai-context\HANDOFF_PROMPT.md') {
        if ($text -match '(?m)^\s*(?:[-*# ]*)?(\u5F53\u524D\u9636\u6BB5|\u8FDB\u884C\u4E2D|\u4E0B\u4E00\u6B65|\u5DF2\u77E5\u95EE\u9898|\u72B6\u6001)\uFF1A') {
            Add-AuditResult -Severity Warning -File $entry.RelativePath -Rule 'FR-VAL-04' -Reason 'HANDOFF appears to contain copied CURRENT_STATE dynamic status content.' -Suggestion 'Review manually; fixed reading and handoff instructions are allowed.'
        } else {
            Add-AuditResult -Severity Passed -File $entry.RelativePath -Rule 'FR-VAL-04' -Reason 'No explicit copied CURRENT_STATE status section detected.' -Suggestion 'No action required.'
        }
    }
}

if ($script:errors.Count -gt 0) {
    Write-AuditResults -ResolvedPath $resolvedTargetPath -ExitCode 3
    exit 3
}

Write-AuditResults -ResolvedPath $resolvedTargetPath -ExitCode 0
exit 0
