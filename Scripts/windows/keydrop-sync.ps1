<#
.SYNOPSIS
  KeyDrop Windows 同步脚本:解密坚果云同步过来的账本快照,更新 Windows 侧工具配置。
  (账本由 macOS 端 KeyDrop 推送到 WebDAV,坚果云客户端自动同步到本机)

.DESCRIPTION
  前置要求:
  ① PowerShell 7+(pwsh):winget install Microsoft.PowerShell
     (AES-GCM 需要 .NET 8,Windows 自带的 5.1 不支持)
  ② 坚果云客户端已把 keydrop 文件夹同步到本机

  功能:
  - 解密账本快照(口令 = macOS 端导出时设置的加密口令)
  - 列出所有活跃条目
  - 更新 Claude Code 的 %USERPROFILE%\.claude\settings.json
    (选定的条目写入 ANTHROPIC_* 环境块,旧 settings 自动备份)

.EXAMPLE
  .\keydrop-sync.ps1 -Passphrase "你的口令"                    # 列出条目 + 更新 Claude Code(默认第一条)
  .\keydrop-sync.ps1 -Passphrase "你的口令" -EntryMatch "pmcat" # 指定激活条目
  .\keydrop-sync.ps1 -Passphrase "你的口令" -ListOnly           # 只列出条目不动配置
#>
param(
    [Parameter(Mandatory = $true)][string]$Passphrase,
    [string]$LedgerFile,
    [string]$EntryMatch,
    [switch]$ListOnly,
    [string]$ClaudeSettings = "$env:USERPROFILE\.claude\settings.json"
)
$ErrorActionPreference = "Stop"

# ── 1. 定位加密账本(坚果云客户端已同步到本机) ──
if (-not $LedgerFile) {
    $LedgerFile = Get-ChildItem -Path $env:USERPROFILE -Recurse -Filter "KeyDrop-ledger.keydrop" `
        -Depth 5 -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending | Select-Object -First 1 -ExpandProperty FullName
}
if (-not $LedgerFile -or -not (Test-Path $LedgerFile)) {
    Write-Host "✗ 未找到 KeyDrop-ledger.keydrop"; Write-Host "  坚果云同步文件夹里没有账本快照 —— 请先在 macOS 端推送"; exit 1
}
Write-Host "账本快照: $LedgerFile"

# ── 2. 解密(PBKDF2-SHA256 60 万轮派生 + AES-256-GCM,与 macOS 端同参数) ──
$envelope = Get-Content $LedgerFile -Raw | ConvertFrom-Json
if ($envelope.format -ne "keydrop-export") { Write-Error "不是 KeyDrop 导出文件"; exit 1 }
$salt     = [Convert]::FromBase64String($envelope.salt)
$combined = [Convert]::FromBase64String($envelope.combined)
$rfc  = [System.Security.Cryptography.Rfc2898DeriveBytes]::new($Passphrase, $salt, $envelope.iterations, [System.Security.Cryptography.HashAlgorithmName]::SHA256)
$key  = $rfc.GetBytes(32)
# combined = nonce(12) + ciphertext + tag(16)
$nonce = $combined[0..11]
$tag   = $combined[($combined.Length - 16)..($combined.Length - 1)]
$ct    = $combined[12..($combined.Length - 17)]
$aes   = [System.Security.Cryptography.AesGcm]::new($key, 16)
$plain = New-Object byte[] $ct.Length
try { $aes.Decrypt($nonce, $ct, $tag, $plain) } catch {
    Write-Host "✗ 解密失败: 口令错误或文件损坏"; exit 1
}
$payload = [Text.Encoding]::UTF8.GetString($plain) | ConvertFrom-Json
if ($payload.schemaVersion -gt 1) { Write-Error "schema 版本更新(v$($payload.schemaVersion)),请升级 Windows 工具"; exit 1 }

$active = @($payload.entries | Where-Object { $_.status -eq "active" })
Write-Host ("账本: 导出于 {0} · 活跃条目 {1} 个" -f ([DateTimeOffset]::FromUnixTimeSeconds($payload.exportedAt).LocalDateTime.ToString("MM-dd HH:mm")), $active.Count)

if ($ListOnly) {
    $active | ForEach-Object {
        Write-Host ("  ● {0}  {1}  [{2}]" -f $_.name, $_.url, (($_.models ?? @()) -join ","))
    }
    exit 0
}

# ── 3. 更新 Claude Code 的 settings.json(claude 系激活条目 → ANTHROPIC_* 环境块) ──
function IsClaudeModel([string]$m) { return ($m -match "claude|sonnet|opus|haiku|fable") }
$claudeEntries = @($active | Where-Object { ($_.models ?? @() | Where-Object { IsClaudeModel $_ }).Count -gt 0 })
if ($claudeEntries.Count -eq 0) { Write-Host "⚠ 账本里没有含 claude 系模型的条目,跳过 Claude Code 更新"; }
else {
    $pick = if ($EntryMatch) { @($claudeEntries | Where-Object { $_.name -match $EntryMatch -or $_.url -match $EntryMatch })[0] } else { $claudeEntries[0] }
    if (-not $pick) { Write-Host "⚠ -EntryMatch 未匹配到条目"; exit 1 }
    $claudeModel = ($pick.models | Where-Object { IsClaudeModel $_ } | Select-Object -First 1)
    $settings = if (Test-Path $ClaudeSettings) { Get-Content $ClaudeSettings -Raw | ConvertFrom-Json } else { [pscustomobject]@{} }
    # 备份
    if (Test-Path $ClaudeSettings) { Copy-Item $ClaudeSettings "$ClaudeSettings.bak-keydrop" -Force }
    $envObj = [ordered]@{
        ANTHROPIC_AUTH_TOKEN = $pick.key
        ANTHROPIC_BASE_URL   = $pick.url
        ANTHROPIC_MODEL               = $claudeModel
        ANTHROPIC_DEFAULT_SONNET_MODEL = $claudeModel
        ANTHROPIC_DEFAULT_SONNET_MODEL_NAME = $claudeModel
        ANTHROPIC_DEFAULT_OPUS_MODEL   = $claudeModel
        ANTHROPIC_DEFAULT_OPUS_MODEL_NAME = $claudeModel
        ANTHROPIC_DEFAULT_HAIKU_MODEL  = $claudeModel
        ANTHROPIC_DEFAULT_HAIKU_MODEL_NAME = $claudeModel
        CLAUDE_CODE_SUBAGENT_MODEL     = $claudeModel
    }
    # 保留非 ANTHROPIC 的既有键(如 onboarding 状态),清理旧 ANTHROPIC_*
    $kept = @{}
    if ($settings.env) { $settings.env.PSObject.Properties | Where-Object {
        $_.Name -notlike "ANTHROPIC_*" -and $_.Name -ne "CLAUDE_CODE_SUBAGENT_MODEL" } | ForEach-Object { $kept[$_.Name] = $_.Value } }
    $newEnv = [pscustomobject]$kept
    foreach ($p in $envObj.GetEnumerator()) { $newEnv | Add-Member -NotePropertyName $p.Key -NotePropertyValue $p.Value -Force }
    $settings | Add-Member -NotePropertyName "env" -NotePropertyValue $newEnv -Force
    $settings | ConvertTo-Json -Depth 10 | Set-Content $ClaudeSettings -Encoding UTF8
    Write-Host "✓ Claude Code 已更新: $($pick.name)($($pick.url))"
    Write-Host "  模型: $claudeModel · 重开 Claude Code 会话生效"
}

Write-Host ""
Write-Host "活跃条目清单(供 CPA/其他工具手动配置):"
$active | ForEach-Object {
    Write-Host ("  ● {0}  {1}" -f $_.name, $_.url)
    Write-Host ("    key: {0}" -f $_.key)
}
