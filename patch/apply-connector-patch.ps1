<#
    Agents Anywhere connector 兼容补丁：让 connector 同时接受 DSH 投影版本 2 与 3。
    背景  ：插件 dsh-bridge-next 自 2026-09-25 起投影版本升为 3，而 AA 桌面端 2.0.0 内置的
            connector(anywhere-cli 0.1.7.2) 只认 2 → 每次 runtime.sync.subscribe 都抛
            ValueError，客户端每秒重订阅。症状："设备连得上，但会话内容永远不同步"。
    安全性：先比对 SHA256 再动手；哈希未知时拒绝执行（除非 -Force）；改前留一份
            sync.py.bak-<时间戳>；-Revert 一键还原；写完再验哈希，不符就自动回滚。
    用法  ：
      powershell -File apply-connector-patch.ps1                     # 自动定位安装目录
      powershell -File apply-connector-patch.ps1 -AppRoot "D:\Apps\Agents Anywhere"
      powershell -File apply-connector-patch.ps1 -Revert             # 还原
    改完必须重启 Agents Anywhere 桌面端才生效。
#>
param(
    [string]$AppRoot = "",
    [switch]$Revert,
    [switch]$Force
)
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [Text.Encoding]::UTF8

$Rel          = 'resources\connector\connector\runtimes\dsh\bridge\sync.py'
$OriginalSha  = 'DB88916C91983584F8748404176B77F2AEF001FE65618C5015CBABCBDC218AB0'  # AA 桌面端 2.0.0 内置
$PatchedSha   = '723B9BEDA7B67885D01C9CA9E8D5CECC16D4940CB9B57C29A0544BCEF369A39A'  # 打过本补丁

function Resolve-AppRoot([string]$Explicit) {
    if ($Explicit) {
        if (-not (Test-Path (Join-Path $Explicit $Rel))) {
            throw "在 '$Explicit' 下找不到 $Rel —— 请确认这是 Agents Anywhere 的安装目录"
        }
        return (Resolve-Path $Explicit).Path
    }
    $cands = New-Object System.Collections.Generic.List[string]
    foreach ($p in @(Get-Process -Name 'Agents Anywhere' -ErrorAction SilentlyContinue)) {
        if ($p.Path) { $cands.Add((Split-Path -Parent $p.Path)) }
    }
    if ($env:LOCALAPPDATA) { $cands.Add((Join-Path $env:LOCALAPPDATA 'Programs\Agents Anywhere')) }
    if ($env:ProgramFiles) { $cands.Add((Join-Path $env:ProgramFiles 'Agents Anywhere')) }
    if (${env:ProgramFiles(x86)}) { $cands.Add((Join-Path ${env:ProgramFiles(x86)} 'Agents Anywhere')) }
    foreach ($c in $cands) { if (Test-Path (Join-Path $c $Rel)) { return (Resolve-Path $c).Path } }
    throw "没找到 Agents Anywhere 安装目录：请用 -AppRoot 指定（该目录下应有 resources\connector\...）"
}

$appRoot = Resolve-AppRoot $AppRoot
$target  = Join-Path $appRoot $Rel
Write-Host "安装目录：$appRoot"
Write-Host "目标文件：$target"

$before = (Get-FileHash $target -Algorithm SHA256).Hash
Write-Host "当前哈希：$before"

if ($Revert) {
    if ($before -eq $OriginalSha) { Write-Host '[=] 当前就是原始文件，无需还原'; exit 0 }
    if ($before -ne $PatchedSha -and -not $Force) {
        throw "哈希既不是原始($OriginalSha)也不是已打补丁($PatchedSha)。`n    若确认要强行还原，加 -Force；或先用 sync.py.bak-* 手工比对。"
    }
    $pairs  = @(
        @('if subscription.get("projectionVersion") not in (2, 3):', 'if subscription.get("projectionVersion") != 2:'),
        @('if batch.get("projectionVersion") not in (2, 3) or', 'if batch.get("projectionVersion") != 2 or')
    )
    $expect = $OriginalSha
    $action = '还原'
} else {
    if ($before -eq $PatchedSha) { Write-Host '[=] 已经打过补丁，无需重复'; exit 0 }
    if ($before -ne $OriginalSha -and -not $Force) {
        throw "哈希不是预期的原始版本($OriginalSha)。`n    AA 可能已升级、或文件已被别的补丁改过：请对照 patch\connector-projection-v3.patch 人工确认后再决定（确认无误可加 -Force 强行替换）。"
    }
    $pairs  = @(
        @('if subscription.get("projectionVersion") != 2:', 'if subscription.get("projectionVersion") not in (2, 3):'),
        @('if batch.get("projectionVersion") != 2 or', 'if batch.get("projectionVersion") not in (2, 3) or')
    )
    $expect = $PatchedSha
    $action = '打补丁'
}

$text = [IO.File]::ReadAllText($target, [Text.Encoding]::UTF8)
$new  = $text
foreach ($p in $pairs) { $new = $new.Replace($p[0], $p[1]) }
if ($new -eq $text) {
    throw "没找到要替换的语句——你的 connector 版本可能与本补丁不同。`n    请对照 patch\connector-projection-v3.patch 手动处理。"
}

$bak = "$target.bak-$(Get-Date -Format 'yyyyMMdd-HHmmss')"
Copy-Item -LiteralPath $target -Destination $bak
[IO.File]::WriteAllText($target, $new, (New-Object Text.UTF8Encoding($false)))   # 保持 UTF-8 无 BOM

$after = (Get-FileHash $target -Algorithm SHA256).Hash
Write-Host "备份：$bak"
Write-Host "改后哈希：$after"

if ($after -eq $expect) {
    Write-Host "[OK] $action 完成（哈希与预期一致）"
} elseif ($Force) {
    Write-Host "[!] $action 已执行，但哈希与预期不同（-Force 模式跳过校验）：$after"
} else {
    Copy-Item -LiteralPath $bak -Destination $target -Force
    throw "$action 后哈希不符（$after ≠ $expect），已自动回滚。请对照 patch\connector-projection-v3.patch 手动处理。"
}

Write-Host ''
Write-Host '下一步：重启 Agents Anywhere 桌面端（connector 随应用启动，不重启不生效）。'
Write-Host '验收：connector 日志不再每秒出现 "DSH event sync interrupted ... (ValueError)"，且设备端内容正常更新。'
