#requires -Version 5.1

[CmdletBinding(PositionalBinding = $false)]
param(
    # 显式检查是否传入，避免 Mandatory 参数在交互式主机中提示并等待输入。
    [Parameter(Mandatory = $false)]
    [string]$TargetPath
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$toolVersion = 'ai_context_init v0.1.0'
$schemaVersion = '1'
$allowedPlaceholders = @(
    '{{PROJECT_NAME}}',
    '{{GENERATED_DATE}}'
)

function Write-ResultList {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Label,

        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [object[]]$Items
    )

    Write-Output ('{0} ({1}):' -f $Label, $Items.Count)
    if ($Items.Count -eq 0) {
        Write-Output '  (none)'
        return
    }

    foreach ($item in $Items) {
        Write-Output ('  - {0}' -f [string]$item)
    }
}

function Stop-Initialization {
    param(
        [Parameter(Mandatory = $true)]
        [int]$ExitCode,

        [Parameter(Mandatory = $true)]
        [string]$Message,

        [string]$ResolvedTargetPath = '',
        [string]$ResolvedProjectName = '',
        [object[]]$CreatedItems = @(),
        [object[]]$SkippedItems = @(),
        [object[]]$WarningItems = @(),
        [object[]]$FailedItems = @()
    )

    Write-Error -Message $Message -ErrorAction Continue
    Write-Output ''
    Write-Output 'AI Context Init result'
    Write-Output ('ToolVersion: {0}' -f $toolVersion)
    Write-Output ('SchemaVersion: {0}' -f $schemaVersion)

    if (-not [string]::IsNullOrWhiteSpace($ResolvedTargetPath)) {
        Write-Output ('TargetPath: {0}' -f $ResolvedTargetPath)
    }

    if (-not [string]::IsNullOrWhiteSpace($ResolvedProjectName)) {
        Write-Output ('ProjectName: {0}' -f $ResolvedProjectName)
    }

    Write-ResultList -Label 'Created' -Items $CreatedItems
    Write-ResultList -Label 'Skipped' -Items $SkippedItems
    Write-ResultList -Label 'Warnings' -Items $WarningItems

    $reportedFailures = @($FailedItems)
    if ($reportedFailures.Count -eq 0) {
        $reportedFailures = @($Message)
    }

    Write-ResultList -Label 'Failed' -Items $reportedFailures
    Write-Output 'FinalResult: Failed'
    Write-Output ('ExitCode: {0}' -f $ExitCode)
    exit $ExitCode
}

function Test-PathWithinRoot {
    param(
        [Parameter(Mandatory = $true)]
        [string]$RootPath,

        [Parameter(Mandatory = $true)]
        [string]$CandidatePath
    )

    $normalizedRoot = [System.IO.Path]::GetFullPath($RootPath)
    $normalizedCandidate = [System.IO.Path]::GetFullPath($CandidatePath)
    $rootWithSeparator = $normalizedRoot.TrimEnd(
        [System.IO.Path]::DirectorySeparatorChar,
        [System.IO.Path]::AltDirectorySeparatorChar
    ) + [System.IO.Path]::DirectorySeparatorChar

    return $normalizedCandidate.StartsWith(
        $rootWithSeparator,
        [System.StringComparison]::OrdinalIgnoreCase
    )
}

function Test-ExistingPathAncestors {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    $currentItem = Get-Item -LiteralPath ([System.IO.Path]::GetFullPath($Path)) -Force

    while ($null -ne $currentItem) {
        if (($currentItem.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
            return [pscustomobject]@{
                IsSafe = $false
                Message = ('TargetPath contains a reparse-point component: {0}' -f $currentItem.FullName)
            }
        }

        $currentItem = $currentItem.Parent
    }

    return [pscustomobject]@{
        IsSafe = $true
        Message = ''
    }
}

function Test-SafeDirectoryChain {
    param(
        [Parameter(Mandatory = $true)]
        [string]$RootPath,

        [Parameter(Mandatory = $true)]
        [string]$CandidateDirectory
    )

    $normalizedRoot = [System.IO.Path]::GetFullPath($RootPath)
    $normalizedCandidate = [System.IO.Path]::GetFullPath($CandidateDirectory)

    if (
        $normalizedCandidate -ine $normalizedRoot -and
        -not (Test-PathWithinRoot -RootPath $normalizedRoot -CandidatePath $normalizedCandidate)
    ) {
        return [pscustomobject]@{
            IsSafe = $false
            Message = 'The required directory resolved outside TargetPath.'
        }
    }

    $rootSafety = Test-ExistingPathAncestors -Path $normalizedRoot
    if (-not $rootSafety.IsSafe) {
        return $rootSafety
    }

    if ($normalizedCandidate -ieq $normalizedRoot) {
        return [pscustomobject]@{
            IsSafe = $true
            Message = ''
        }
    }

    $rootWithSeparator = $normalizedRoot.TrimEnd(
        [System.IO.Path]::DirectorySeparatorChar,
        [System.IO.Path]::AltDirectorySeparatorChar
    ) + [System.IO.Path]::DirectorySeparatorChar
    $relativeDirectory = $normalizedCandidate.Substring($rootWithSeparator.Length)
    $segments = @(
        $relativeDirectory.Split(
            @(
                [System.IO.Path]::DirectorySeparatorChar,
                [System.IO.Path]::AltDirectorySeparatorChar
            ),
            [System.StringSplitOptions]::RemoveEmptyEntries
        )
    )
    $currentPath = $normalizedRoot

    foreach ($segment in $segments) {
        $currentPath = [System.IO.Path]::Combine($currentPath, $segment)

        if ([System.IO.File]::Exists($currentPath)) {
            return [pscustomobject]@{
                IsSafe = $false
                Message = ('A required directory path is occupied by a file: {0}' -f $currentPath)
            }
        }

        if (-not [System.IO.Directory]::Exists($currentPath)) {
            break
        }

        $directoryItem = Get-Item -LiteralPath $currentPath -Force
        if (($directoryItem.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
            return [pscustomobject]@{
                IsSafe = $false
                Message = ('A required directory is a reparse point: {0}' -f $currentPath)
            }
        }
    }

    return [pscustomobject]@{
        IsSafe = $true
        Message = ''
    }
}

function Write-AtomicNewUtf8File {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,

        [Parameter(Mandatory = $true)]
        [string]$Content,

        [Parameter(Mandatory = $true)]
        [System.Text.Encoding]$Encoding,

        [Parameter(Mandatory = $true)]
        [System.Text.Encoding]$StrictEncoding,

        [Parameter(Mandatory = $true)]
        [string]$PlaceholderPattern
    )

    $stream = $null
    $writer = $null
    $temporaryPath = ''
    $phase = 'Prepare'
    $status = 'Failed'
    $message = ''

    try {
        $parentDirectory = [System.IO.Path]::GetDirectoryName($Path)
        $temporaryName = '.ai-context-init.{0}.{1}.tmp' -f (
            [System.IO.Path]::GetFileName($Path)
        ), ([System.Guid]::NewGuid().ToString('N'))
        $temporaryPath = [System.IO.Path]::Combine($parentDirectory, $temporaryName)

        $phase = 'WriteTemporary'
        $stream = [System.IO.FileStream]::new(
            $temporaryPath,
            [System.IO.FileMode]::CreateNew,
            [System.IO.FileAccess]::Write,
            [System.IO.FileShare]::None
        )
        $writer = [System.IO.StreamWriter]::new($stream, $Encoding)
        $writer.Write($Content)
        $writer.Flush()
        $stream.Flush($true)
        $writer.Dispose()
        $writer = $null
        $stream = $null

        $phase = 'ValidateTemporary'
        $temporaryBytes = [System.IO.File]::ReadAllBytes($temporaryPath)
        if ($temporaryBytes.Length -eq 0) {
            throw [System.IO.InvalidDataException]::new('The temporary file is empty.')
        }

        if (
            $temporaryBytes.Length -ge 3 -and
            $temporaryBytes[0] -eq 0xEF -and
            $temporaryBytes[1] -eq 0xBB -and
            $temporaryBytes[2] -eq 0xBF
        ) {
            throw [System.IO.InvalidDataException]::new('The temporary file contains a UTF-8 BOM.')
        }

        $temporaryText = $StrictEncoding.GetString($temporaryBytes)
        if ([regex]::IsMatch($temporaryText, $PlaceholderPattern)) {
            throw [System.IO.InvalidDataException]::new('The temporary file contains an unresolved placeholder.')
        }

        if ($temporaryText -cne $Content) {
            throw [System.IO.InvalidDataException]::new('The temporary file differs from the rendered template content.')
        }

        $phase = 'Promote'
        [System.IO.File]::Move($temporaryPath, $Path)
        $status = 'Created'
    }
    catch {
        $message = $_.Exception.Message

        if ($phase -eq 'Promote' -and [System.IO.File]::Exists($Path)) {
            $status = 'Skipped'
            $message = 'The target file was created by another process and was not overwritten.'
        }
        elseif ($phase -eq 'ValidateTemporary') {
            $status = 'ValidationFailed'
        }
        else {
            $status = 'Failed'
        }
    }
    finally {
        if ($null -ne $writer) {
            $writer.Dispose()
            $writer = $null
            $stream = $null
        }
        elseif ($null -ne $stream) {
            $stream.Dispose()
            $stream = $null
        }

        if (-not [string]::IsNullOrWhiteSpace($temporaryPath)) {
            try {
                if ([System.IO.File]::Exists($temporaryPath)) {
                    [System.IO.File]::Delete($temporaryPath)
                }
            }
            catch {
                $status = 'Failed'
                if ([string]::IsNullOrWhiteSpace($message)) {
                    $message = $_.Exception.Message
                }
                else {
                    $message = '{0} Temporary-file cleanup also failed: {1}' -f $message, $_.Exception.Message
                }
            }
        }
    }

    return [pscustomobject]@{
        Status = $status
        Message = $message
        TemporaryPath = $temporaryPath
    }
}

if (
    -not $PSBoundParameters.ContainsKey('TargetPath') -or
    [string]::IsNullOrWhiteSpace($TargetPath)
) {
    Stop-Initialization -ExitCode 1 -Message 'The required -TargetPath parameter was not provided.'
}

$resolvedTargetPath = ''
$projectName = ''

try {
    $resolvedTargetPath = [System.IO.Path]::GetFullPath($TargetPath)
}
catch {
    Stop-Initialization -ExitCode 2 -Message (
        'TargetPath could not be normalized: {0}' -f $_.Exception.Message
    )
}

if (-not [System.IO.Directory]::Exists($resolvedTargetPath)) {
    if ([System.IO.File]::Exists($resolvedTargetPath)) {
        Stop-Initialization -ExitCode 2 -Message 'TargetPath exists but is not a directory.' `
            -ResolvedTargetPath $resolvedTargetPath
    }

    Stop-Initialization -ExitCode 2 -Message 'TargetPath does not exist.' `
        -ResolvedTargetPath $resolvedTargetPath
}

try {
    $targetDirectory = Get-Item -LiteralPath $resolvedTargetPath
    if (-not $targetDirectory.PSIsContainer) {
        Stop-Initialization -ExitCode 2 -Message 'TargetPath is not a directory.' `
            -ResolvedTargetPath $resolvedTargetPath
    }

    $resolvedTargetPath = $targetDirectory.FullName
    $projectName = $targetDirectory.Name

    $targetRootSafety = Test-SafeDirectoryChain `
        -RootPath $resolvedTargetPath `
        -CandidateDirectory $resolvedTargetPath
    if (-not $targetRootSafety.IsSafe) {
        Stop-Initialization -ExitCode 2 -Message $targetRootSafety.Message `
            -ResolvedTargetPath $resolvedTargetPath
    }
}
catch {
    Stop-Initialization -ExitCode 2 -Message (
        'TargetPath could not be inspected: {0}' -f $_.Exception.Message
    ) -ResolvedTargetPath $resolvedTargetPath
}

if ([string]::IsNullOrWhiteSpace($projectName)) {
    Stop-Initialization -ExitCode 2 -Message (
        'ProjectName could not be derived from the TargetPath folder name.'
    ) -ResolvedTargetPath $resolvedTargetPath
}

$scriptDirectory = $PSScriptRoot
if ([string]::IsNullOrWhiteSpace($scriptDirectory)) {
    Stop-Initialization -ExitCode 3 -Message 'The script directory could not be determined.' `
        -ResolvedTargetPath $resolvedTargetPath `
        -ResolvedProjectName $projectName
}

try {
    $projectRoot = [System.IO.Path]::GetFullPath(
        (Join-Path -Path $scriptDirectory -ChildPath '..')
    )
}
catch {
    Stop-Initialization -ExitCode 3 -Message (
        'The AI Context Init project root could not be determined: {0}' -f $_.Exception.Message
    ) -ResolvedTargetPath $resolvedTargetPath `
        -ResolvedProjectName $projectName
}

$manifest = @(
    [pscustomobject]@{
        TemplateRelativePath = 'templates\AGENTS.md.template'
        TargetRelativePath = 'AGENTS.md'
    },
    [pscustomobject]@{
        TemplateRelativePath = 'templates\docs\ai-context\CURRENT_STATE.md.template'
        TargetRelativePath = 'docs\ai-context\CURRENT_STATE.md'
    },
    [pscustomobject]@{
        TemplateRelativePath = 'templates\docs\ai-context\DEV_LOG.md.template'
        TargetRelativePath = 'docs\ai-context\DEV_LOG.md'
    },
    [pscustomobject]@{
        TemplateRelativePath = 'templates\docs\ai-context\DECISIONS.md.template'
        TargetRelativePath = 'docs\ai-context\DECISIONS.md'
    },
    [pscustomobject]@{
        TemplateRelativePath = 'templates\docs\ai-context\HANDOFF_PROMPT.md.template'
        TargetRelativePath = 'docs\ai-context\HANDOFF_PROMPT.md'
    }
)

$utf8NoBom = [System.Text.UTF8Encoding]::new($false)
$utf8Strict = [System.Text.UTF8Encoding]::new($false, $true)
$generatedDate = [System.DateTime]::Now.ToString(
    'yyyy-MM-dd',
    [System.Globalization.CultureInfo]::InvariantCulture
)
$placeholderPattern = '\{\{[^{}\r\n]+\}\}'
$renderedContent = @{}
$resolvedEntries = @()

foreach ($entry in $manifest) {
    $templatePath = [System.IO.Path]::GetFullPath(
        (Join-Path -Path $projectRoot -ChildPath $entry.TemplateRelativePath)
    )
    $targetFilePath = [System.IO.Path]::GetFullPath(
        (Join-Path -Path $resolvedTargetPath -ChildPath $entry.TargetRelativePath)
    )

    if (-not (Test-PathWithinRoot -RootPath $resolvedTargetPath -CandidatePath $targetFilePath)) {
        Stop-Initialization -ExitCode 2 -Message (
            'A target path resolved outside TargetPath: {0}' -f $entry.TargetRelativePath
        ) -ResolvedTargetPath $resolvedTargetPath `
            -ResolvedProjectName $projectName
    }

    $targetParentDirectory = [System.IO.Path]::GetDirectoryName($targetFilePath)
    try {
        $directorySafety = Test-SafeDirectoryChain `
            -RootPath $resolvedTargetPath `
            -CandidateDirectory $targetParentDirectory
    }
    catch {
        Stop-Initialization -ExitCode 2 -Message (
            'A required target directory could not be safely inspected: {0}. {1}' -f
            $targetParentDirectory,
            $_.Exception.Message
        ) -ResolvedTargetPath $resolvedTargetPath `
            -ResolvedProjectName $projectName
    }

    if (-not $directorySafety.IsSafe) {
        Stop-Initialization -ExitCode 2 -Message $directorySafety.Message `
            -ResolvedTargetPath $resolvedTargetPath `
            -ResolvedProjectName $projectName
    }

    if (-not [System.IO.File]::Exists($templatePath)) {
        Stop-Initialization -ExitCode 3 -Message (
            'A required template is missing or is not a file: {0}' -f $templatePath
        ) -ResolvedTargetPath $resolvedTargetPath `
            -ResolvedProjectName $projectName
    }

    try {
        $templateBytes = [System.IO.File]::ReadAllBytes($templatePath)
        if (
            $templateBytes.Length -ge 3 -and
            $templateBytes[0] -eq 0xEF -and
            $templateBytes[1] -eq 0xBB -and
            $templateBytes[2] -eq 0xBF
        ) {
            Stop-Initialization -ExitCode 3 -Message (
                'A template contains a UTF-8 BOM and was rejected: {0}' -f $templatePath
            ) -ResolvedTargetPath $resolvedTargetPath `
                -ResolvedProjectName $projectName
        }

        $templateText = $utf8Strict.GetString($templateBytes)
    }
    catch {
        Stop-Initialization -ExitCode 3 -Message (
            'A template could not be read as UTF-8: {0}. {1}' -f
            $templatePath,
            $_.Exception.Message
        ) -ResolvedTargetPath $resolvedTargetPath `
            -ResolvedProjectName $projectName
    }

    if ([string]::IsNullOrWhiteSpace($templateText)) {
        Stop-Initialization -ExitCode 3 -Message (
            'A required template is empty: {0}' -f $templatePath
        ) -ResolvedTargetPath $resolvedTargetPath `
            -ResolvedProjectName $projectName
    }

    if (
        ([regex]::Matches($templateText, 'Context Schema Version: 1')).Count -ne 1 -or
        ([regex]::Matches($templateText, 'Generated By: ai_context_init v0\.1\.0')).Count -ne 1
    ) {
        Stop-Initialization -ExitCode 3 -Message (
            'A template has an invalid or ambiguous Schema/Generated By marker: {0}' -f
            $templatePath
        ) -ResolvedTargetPath $resolvedTargetPath `
            -ResolvedProjectName $projectName
    }

    $sourcePlaceholders = @(
        [regex]::Matches($templateText, $placeholderPattern) |
            ForEach-Object { $_.Value } |
            Sort-Object -Unique
    )

    foreach ($sourcePlaceholder in $sourcePlaceholders) {
        if ($allowedPlaceholders -notcontains $sourcePlaceholder) {
            Stop-Initialization -ExitCode 3 -Message (
                'A template contains an unsupported placeholder: {0} in {1}' -f
                $sourcePlaceholder,
                $templatePath
            ) -ResolvedTargetPath $resolvedTargetPath `
                -ResolvedProjectName $projectName
        }
    }

    foreach ($requiredPlaceholder in $allowedPlaceholders) {
        if ($templateText.IndexOf($requiredPlaceholder, [System.StringComparison]::Ordinal) -lt 0) {
            Stop-Initialization -ExitCode 3 -Message (
                'A template is missing the required placeholder {0}: {1}' -f
                $requiredPlaceholder,
                $templatePath
            ) -ResolvedTargetPath $resolvedTargetPath `
                -ResolvedProjectName $projectName
        }
    }

    $candidateContent = $templateText.Replace('{{PROJECT_NAME}}', $projectName)
    $candidateContent = $candidateContent.Replace('{{GENERATED_DATE}}', $generatedDate)

    if (
        [string]::IsNullOrWhiteSpace($candidateContent) -or
        [regex]::IsMatch($candidateContent, $placeholderPattern)
    ) {
        Stop-Initialization -ExitCode 5 -Message (
            'Rendered content is empty or contains an unresolved placeholder: {0}' -f
            $entry.TargetRelativePath
        ) -ResolvedTargetPath $resolvedTargetPath `
            -ResolvedProjectName $projectName
    }

    $renderedContent[$entry.TargetRelativePath] = $candidateContent
    $resolvedEntries += [pscustomobject]@{
        TargetRelativePath = $entry.TargetRelativePath
        TargetFilePath = $targetFilePath
        TargetParentDirectory = $targetParentDirectory
    }
}

$created = @()
$skipped = @()
$warnings = @()
$failed = @()
$toCreate = @()
$temporaryArtifacts = @()

foreach ($entry in $resolvedEntries) {
    if ([System.IO.File]::Exists($entry.TargetFilePath)) {
        $skipped += $entry.TargetRelativePath
        continue
    }

    if ([System.IO.Directory]::Exists($entry.TargetFilePath)) {
        $failed += (
            '{0}: the target file path is occupied by a directory.' -f
            $entry.TargetRelativePath
        )
        continue
    }

    $toCreate += $entry
}

Write-Output 'AI Context Init preflight'
Write-Output ('ToolVersion: {0}' -f $toolVersion)
Write-Output ('SchemaVersion: {0}' -f $schemaVersion)
Write-Output ('TargetPath: {0}' -f $resolvedTargetPath)
Write-Output ('ProjectName: {0}' -f $projectName)
Write-ResultList -Label 'WillCreate' -Items @(
    $toCreate | ForEach-Object { $_.TargetRelativePath }
)
Write-ResultList -Label 'WillSkip' -Items $skipped

if ($failed.Count -gt 0) {
    Stop-Initialization -ExitCode 4 -Message (
        'One or more target file paths are not writable file locations.'
    ) -ResolvedTargetPath $resolvedTargetPath `
        -ResolvedProjectName $projectName `
        -CreatedItems $created `
        -SkippedItems $skipped `
        -WarningItems $warnings `
        -FailedItems $failed
}

if ($skipped.Count -gt 0) {
    $skipWarning = 'Skipped means the existing file was not overwritten; it does not mean the file passed Schema validation.'
    $warnings += $skipWarning
    Write-Warning $skipWarning
}

foreach ($entry in $toCreate) {
    $parentDirectory = $entry.TargetParentDirectory

    try {
        if (-not [System.IO.Directory]::Exists($parentDirectory)) {
            [void][System.IO.Directory]::CreateDirectory($parentDirectory)
        }

        $directorySafety = Test-SafeDirectoryChain `
            -RootPath $resolvedTargetPath `
            -CandidateDirectory $parentDirectory
        if (-not $directorySafety.IsSafe) {
            throw [System.IO.IOException]::new($directorySafety.Message)
        }
    }
    catch {
        $failed += (
            '{0}: required directory creation failed: {1}' -f
            $entry.TargetRelativePath,
            $_.Exception.Message
        )

        Stop-Initialization -ExitCode 4 -Message 'A required target directory could not be created.' `
            -ResolvedTargetPath $resolvedTargetPath `
            -ResolvedProjectName $projectName `
            -CreatedItems $created `
            -SkippedItems $skipped `
            -WarningItems $warnings `
            -FailedItems $failed
    }

    $writeResult = Write-AtomicNewUtf8File `
        -Path $entry.TargetFilePath `
        -Content $renderedContent[$entry.TargetRelativePath] `
        -Encoding $utf8NoBom `
        -StrictEncoding $utf8Strict `
        -PlaceholderPattern $placeholderPattern

    if (-not [string]::IsNullOrWhiteSpace($writeResult.TemporaryPath)) {
        $temporaryArtifacts += $writeResult.TemporaryPath
    }

    if ($writeResult.Status -eq 'Created') {
        $created += $entry.TargetRelativePath
        continue
    }

    if ($writeResult.Status -eq 'Skipped') {
        $skipped += $entry.TargetRelativePath
        $concurrentWarning = (
            '{0} was created concurrently and was not overwritten.' -f
            $entry.TargetRelativePath
        )
        $warnings += $concurrentWarning
        Write-Warning $concurrentWarning
        continue
    }

    if ($writeResult.Status -eq 'ValidationFailed') {
        $failed += (
            '{0}: temporary-file validation failed: {1}' -f
            $entry.TargetRelativePath,
            $writeResult.Message
        )
        Stop-Initialization -ExitCode 5 -Message 'Generated file validation failed before atomic promotion.' `
            -ResolvedTargetPath $resolvedTargetPath `
            -ResolvedProjectName $projectName `
            -CreatedItems $created `
            -SkippedItems $skipped `
            -WarningItems $warnings `
            -FailedItems $failed
    }

    $failed += (
        '{0}: {1}' -f $entry.TargetRelativePath, $writeResult.Message
    )
    Stop-Initialization -ExitCode 4 -Message 'A target file could not be written.' `
        -ResolvedTargetPath $resolvedTargetPath `
        -ResolvedProjectName $projectName `
        -CreatedItems $created `
        -SkippedItems $skipped `
        -WarningItems $warnings `
        -FailedItems $failed
}

$validationFailures = @()
$allowedTargetPaths = @{}

foreach ($entry in $resolvedEntries) {
    $allowedTargetPaths[$entry.TargetFilePath] = $entry.TargetRelativePath
}

foreach ($entry in $resolvedEntries) {
    if ($created -notcontains $entry.TargetRelativePath) {
        continue
    }

    try {
        $normalizedOutputPath = [System.IO.Path]::GetFullPath($entry.TargetFilePath)
        if (-not (Test-PathWithinRoot -RootPath $resolvedTargetPath -CandidatePath $normalizedOutputPath)) {
            $validationFailures += (
                '{0}: generated path resolved outside TargetPath.' -f
                $entry.TargetRelativePath
            )
            continue
        }

        if (-not $allowedTargetPaths.ContainsKey($normalizedOutputPath)) {
            $validationFailures += (
                '{0}: generated path is not in the fixed target manifest.' -f
                $entry.TargetRelativePath
            )
            continue
        }

        if (-not [System.IO.File]::Exists($normalizedOutputPath)) {
            $validationFailures += (
                '{0}: generated file does not exist.' -f $entry.TargetRelativePath
            )
            continue
        }

        $outputItem = Get-Item -LiteralPath $normalizedOutputPath -Force
        if (($outputItem.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
            $validationFailures += (
                '{0}: generated file is a reparse point.' -f $entry.TargetRelativePath
            )
            continue
        }

        $directorySafety = Test-SafeDirectoryChain `
            -RootPath $resolvedTargetPath `
            -CandidateDirectory $entry.TargetParentDirectory
        if (-not $directorySafety.IsSafe) {
            $validationFailures += (
                '{0}: generated file parent directory is unsafe: {1}' -f
                $entry.TargetRelativePath,
                $directorySafety.Message
            )
            continue
        }

        $outputBytes = [System.IO.File]::ReadAllBytes($entry.TargetFilePath)
        if ($outputBytes.Length -eq 0) {
            $validationFailures += (
                '{0}: generated file is empty.' -f $entry.TargetRelativePath
            )
            continue
        }

        if (
            $outputBytes.Length -ge 3 -and
            $outputBytes[0] -eq 0xEF -and
            $outputBytes[1] -eq 0xBB -and
            $outputBytes[2] -eq 0xBF
        ) {
            $validationFailures += (
                '{0}: generated file contains a UTF-8 BOM.' -f
                $entry.TargetRelativePath
            )
            continue
        }

        $outputText = $utf8Strict.GetString($outputBytes)
        if ([regex]::IsMatch($outputText, $placeholderPattern)) {
            $validationFailures += (
                '{0}: generated file contains an unresolved placeholder.' -f
                $entry.TargetRelativePath
            )
            continue
        }

        if ($outputText -cne $renderedContent[$entry.TargetRelativePath]) {
            $validationFailures += (
                '{0}: generated content differs from rendered template content.' -f
                $entry.TargetRelativePath
            )
        }
    }
    catch {
        $validationFailures += (
            '{0}: generated file validation failed: {1}' -f
            $entry.TargetRelativePath,
            $_.Exception.Message
        )
    }
}

foreach ($temporaryArtifact in $temporaryArtifacts) {
    try {
        $normalizedTemporaryPath = [System.IO.Path]::GetFullPath($temporaryArtifact)
        if (-not (Test-PathWithinRoot -RootPath $resolvedTargetPath -CandidatePath $normalizedTemporaryPath)) {
            $validationFailures += (
                'A temporary artifact path resolved outside TargetPath: {0}' -f
                $normalizedTemporaryPath
            )
            continue
        }

        if (
            [System.IO.File]::Exists($normalizedTemporaryPath) -or
            [System.IO.Directory]::Exists($normalizedTemporaryPath)
        ) {
            $validationFailures += (
                'A temporary artifact remained after writing: {0}' -f
                $normalizedTemporaryPath
            )
        }
    }
    catch {
        $validationFailures += (
            'A temporary artifact path could not be validated: {0}. {1}' -f
            $temporaryArtifact,
            $_.Exception.Message
        )
    }
}

if ($validationFailures.Count -gt 0) {
    Stop-Initialization -ExitCode 5 -Message 'Generated file validation failed.' `
        -ResolvedTargetPath $resolvedTargetPath `
        -ResolvedProjectName $projectName `
        -CreatedItems $created `
        -SkippedItems $skipped `
        -WarningItems $warnings `
        -FailedItems $validationFailures
}

Write-Output ''
Write-Output 'AI Context Init result'
Write-Output ('ToolVersion: {0}' -f $toolVersion)
Write-Output ('SchemaVersion: {0}' -f $schemaVersion)
Write-Output ('TargetPath: {0}' -f $resolvedTargetPath)
Write-Output ('ProjectName: {0}' -f $projectName)
Write-ResultList -Label 'Created' -Items $created
Write-ResultList -Label 'Skipped' -Items $skipped
Write-ResultList -Label 'Warnings' -Items $warnings
Write-ResultList -Label 'Failed' -Items @()

if ($created.Count -eq 0 -and $skipped.Count -eq $manifest.Count) {
    Write-Output 'FinalResult: Success (all target files already existed and were skipped)'
}
elseif ($created.Count -gt 0 -and $skipped.Count -gt 0) {
    Write-Output 'FinalResult: Success (missing files created; existing files skipped)'
}
else {
    Write-Output 'FinalResult: Success'
}

Write-Output 'ExitCode: 0'
exit 0
