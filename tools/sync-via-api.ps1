param(
    [string]$Repo = "88216424/timefloat",
    [string]$Branch = "main",
    [string[]]$Files,
    [string]$Message = "fix: 通过 GitHub API 提交（git 协议被网络阻断时的备用通道）"
)

# =============================================================================
#  当 github.com:443 被网络阻断（但 api.github.com 可达）时，
#  用 GitHub Contents API 把本地文件写进仓库。
#  用法： pwsh -File tools/sync-via-api.ps1 -Files a.swift,b.swift
# =============================================================================
$ErrorActionPreference = 'Stop'
$ProjRoot = Split-Path -Parent $PSScriptRoot

function Write-Json($obj, $path) {
    $json = $obj | ConvertTo-Json -Compress -Depth 6
    [IO.File]::WriteAllText($path, $json, [Text.UTF8Encoding]::new($false))
}

$tmp = Join-Path $env:TEMP "gh-api-sync"
New-Item -ItemType Directory -Force -Path $tmp | Out-Null

foreach ($f in $Files) {
    $rel = $f -replace '\\', '/'
    $local = Join-Path $ProjRoot ($rel -replace '/', '\')
    if (-not (Test-Path $local)) { Write-Host "跳过（本地不存在）: $rel"; continue }

    $sha = $null
    $cur = gh api "repos/$Repo/contents/$rel`?ref=$Branch" 2>$null
    if ($LASTEXITCODE -eq 0 -and $cur) {
        $sha = ($cur | ConvertFrom-Json).sha
    }

    $b64 = [Convert]::ToBase64String([IO.File]::ReadAllBytes($local))
    $body = @{ message = "$Message [$rel]"; content = $b64; branch = $Branch }
    if ($sha) { $body.sha = $sha }

    $payload = Join-Path $tmp "payload.json"
    Write-Json $body $payload

    $res = gh api --method PUT "repos/$Repo/contents/$rel" --input $payload 2>&1
    if ($LASTEXITCODE -eq 0) {
        $cm = ($res | ConvertFrom-Json).commit.sha
        Write-Host ("[OK]   {0}  →  commit {1}" -f $rel, $cm.Substring(0, 7))
    } else {
        Write-Host ("[FAIL] {0}`n        {1}" -f $rel, ($res | Select-Object -First 3))
    }
}

Write-Host ""
Write-Host "远端最新提交："
gh api "repos/$Repo/commits?per_page=3" --jq '.[] | "  \(.sha[0:7])  \(.commit.message | split("\n")[0])"' 2>&1
