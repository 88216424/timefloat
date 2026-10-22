param(
    [string]$Repo = "88216424/timefloat",
    [string]$Branch = "main",
    [string[]]$Files,
    [string]$Message = "chore: 批量提交"
)

# =============================================================================
#  原子批量提交（走 GitHub Git Data API）
#  为什么需要它：走 Contents API 是一个文件一个 commit，
#  而 workflow 的触发条件是 ios/** 变更 → 19 个文件就会触发 19 次 macOS 编译（浪费额度）。
#  这个脚本把 N 个文件合成 1 个 commit（blobs → tree → commit → 更新 ref），
#  只会触发 1 次 CI。
# =============================================================================
$ErrorActionPreference = 'Stop'
$ProjRoot = Split-Path -Parent $PSScriptRoot
$tmp = Join-Path $env:TEMP "gh-atomic"
New-Item -ItemType Directory -Force -Path $tmp | Out-Null

function WJson($obj, $path) {
    [IO.File]::WriteAllText($path, ($obj | ConvertTo-Json -Compress -Depth 8), [Text.UTF8Encoding]::new($false))
}

Write-Host "读取当前远端状态…"
$headSha = (gh api "repos/$Repo/git/ref/heads/$Branch" --jq '.object.sha').Trim()
$treeSha = (gh api "repos/$Repo/git/commits/$headSha" --jq '.tree.sha').Trim()
Write-Host "  HEAD  = $headSha"
Write-Host "  TREE  = $treeSha"

$entries = @()
Write-Host "上传 blobs（$($Files.Count) 个文件，不产生 commit）…"
foreach ($f in $Files) {
    $rel = $f -replace '\\', '/'
    $local = Join-Path $ProjRoot ($rel -replace '/', '\')
    if (-not (Test-Path $local)) { Write-Host "  跳过（不存在）: $rel"; continue }

    $b64 = [Convert]::ToBase64String([IO.File]::ReadAllBytes($local))
    $bf = Join-Path $tmp "blob.json"
    WJson @{ content = $b64; encoding = "base64" } $bf
    $sha = (gh api --method POST "repos/$Repo/git/blobs" --input $bf --jq '.sha').Trim()
    $entries += @{ path = $rel; mode = "100644"; type = "blob"; sha = $sha }
    Write-Host ("  [{0}] {1}" -f $sha.Substring(0, 7), $rel)
}

Write-Host "创建 tree…"
$tf = Join-Path $tmp "tree.json"
WJson @{ base_tree = $treeSha; tree = $entries } $tf
$newTree = (gh api --method POST "repos/$Repo/git/trees" --input $tf --jq '.sha').Trim()
Write-Host "  TREE' = $newTree"

Write-Host "创建 commit…"
$cf = Join-Path $tmp "commit.json"
WJson @{ message = $Message; tree = $newTree; parents = @($headSha) } $cf
$newCommit = (gh api --method POST "repos/$Repo/git/commits" --input $cf --jq '.sha').Trim()
Write-Host "  COMMIT = $newCommit"

Write-Host "更新分支引用（这一步才会触发 CI，仅一次）…"
$rf = Join-Path $tmp "ref.json"
WJson @{ sha = $newCommit; force = $false } $rf
gh api --method PATCH "repos/$Repo/git/refs/heads/$Branch" --input $rf | Out-Null

Write-Host ""
Write-Host "完成。远端最新提交："
gh api "repos/$Repo/commits?per_page=3" --jq '.[] | "  \(.sha[0:7])  \(.commit.message | split("\n")[0])"'
