<#
.SYNOPSIS
    一条命令把 ink2godot 工程跑起来。

.DESCRIPTION
    检查工具链 → 定位 Godot → 必要时重建导入缓存 → 冒烟测试出一张图。
    默认只做「能看画面」这一步，不需要 Node、不需要 ink-studio。

    -WithBaker 额外准备美术烘焙环境（art-pipeline + ink-studio），
    这一侧只有需要重新导出 splat 资产的人才要跑。

.PARAMETER Godot
    Godot 可执行文件路径。不传就按 PATH → 兄弟目录里的 portable 版本 自动找。

.PARAMETER WithBaker
    同时检查美术烘焙环境：../art-pipeline、ink-studio 仓库、Node 18+。

.PARAMETER Force
    即使 .godot 缓存存在也强制重新导入。

.PARAMETER SkipSmoke
    跳过冒烟测试（无显卡的机器用）。

.EXAMPLE
    ./setup.ps1
.EXAMPLE
    ./setup.ps1 -Godot "C:/tools/Godot_v4.7.2-stable_win64.exe" -WithBaker
#>
param(
    [string]$Godot,
    [switch]$WithBaker,
    [switch]$Force,
    [switch]$SkipSmoke
)

$ErrorActionPreference = 'Stop'
$here = $PSScriptRoot
$expectedMajor = 4.7   # 与 project.godot 的 config/features 保持一致

function Say($msg) { Write-Host $msg }
function Step($n, $msg) { Write-Host ""; Write-Host "[$n] $msg" -ForegroundColor Cyan }
function Ok($msg) { Write-Host "    OK   $msg" -ForegroundColor Green }
function Warn($msg) { Write-Host "    WARN $msg" -ForegroundColor Yellow }
function Die($msg) { Write-Host "    FAIL $msg" -ForegroundColor Red; exit 1 }

# 原生命令一律先 | Out-String 再解析：直接管道给 Select-Object 会掐断进程。
function Run([string]$exe, [string[]]$arguments) {
    $text = (& $exe @arguments 2>&1 | Out-String)
    [pscustomobject]@{ Code = $LASTEXITCODE; Text = ($text -replace "`e\[[0-9;]*m", '') }
}

Say "ink2godot 环境引导"
Say "工程目录: $here"

# ---------------------------------------------------------------- 1. 工具链
Step 1 '工具链'
$gitCmd = Get-Command git -ErrorAction SilentlyContinue
if ($gitCmd) {
    $v = (Run 'git' @('--version')).Text.Trim()
    Ok "$v"
} else {
    Warn 'git 不在 PATH（只影响拉取/提交，不影响运行）'
}

# Godot 定位顺序：显式参数 → PATH → 兄弟目录里的 portable 版本
$godotExe = $null
$searched = @()
if ($Godot) {
    if (Test-Path $Godot) { $godotExe = (Resolve-Path $Godot).Path }
    else { Die "-Godot 指定的路径不存在: $Godot" }
} else {
    $onPath = Get-Command godot, godot_console, 'Godot_v*-stable*' -ErrorAction SilentlyContinue |
        Where-Object { $_.Source -like '*.exe' } | Select-Object -First 1
    if ($onPath) { $godotExe = $onPath.Source }

    if (-not $godotExe) {
        $parent = Split-Path $here -Parent
        $candidates = @(
            Get-ChildItem -Path $parent -Directory -Filter 'Godot_v*' -ErrorAction SilentlyContinue |
                ForEach-Object {
                    Get-ChildItem -Path $_.FullName -File -Filter 'Godot_v*_console.exe' -ErrorAction SilentlyContinue
                }
        )
        if (-not $candidates.Count) {
            $candidates = @(
                Get-ChildItem -Path $parent -Directory -Filter 'Godot_v*' -ErrorAction SilentlyContinue |
                    ForEach-Object {
                        Get-ChildItem -Path $_.FullName -File -Filter 'Godot_v*.exe' -ErrorAction SilentlyContinue |
                            Where-Object { $_.Name -notlike '*_console*' }
                    }
            )
        }
        if ($candidates.Count) { $godotExe = $candidates[0].FullName }
    }
    if (-not $godotExe) {
        Die @"
找不到 Godot。三选一：
      1. 从 https://godotengine.org/download/windows/ 下 portable 版（4.7.x），解压到
         $(Split-Path $here -Parent)\Godot_v4.7.2-stable_win64\
      2. 把 godot.exe 加进 PATH
      3. 显式指定： ./setup.ps1 -Godot "C:\path\to\Godot_v4.7.2-stable_win64.exe"
"@
    }
}

$ver = (Run $godotExe @('--version')).Text.Trim()
Ok "$([System.IO.Path]::GetFileName($godotExe))  ->  $ver"
if ($ver -match '^(\d+\.\d+)') {
    $major = [double]$Matches[1]
    if ($major -ne $expectedMajor) {
        Warn "工程保存于 Godot $expectedMajor（config/features），当前是 $major。"
        Warn '版本不一致时首次打开会被提示升级工程文件，可能改动 .tscn —— 建议对齐版本。'
    }
}

# ---------------------------------------------------------------- 2. 资产
Step 2 'splat 资产'
$ply = @(Get-ChildItem -Path (Join-Path $here 'assets') -Recurse -File -Filter '*.ply' -ErrorAction SilentlyContinue)
if (-not $ply.Count) { Die 'assets/ 里没有 .ply。仓库不完整？' }
$bytes = ($ply | Measure-Object Length -Sum).Sum
Ok ("{0} 个 .ply / {1:N1} MB" -f $ply.Count, ($bytes / 1MB))

# ---------------------------------------------------------------- 3. 导入缓存
Step 3 '导入缓存'
$cache = Join-Path $here '.godot'
if ((Test-Path $cache) -and -not $Force) {
    $size = (Get-ChildItem $cache -Recurse -File -ErrorAction SilentlyContinue |
        Measure-Object Length -Sum).Sum
    Ok ("已存在，{0:N0} MB（要重建用 -Force）" -f ($size / 1MB))
} else {
    Say '    重建中，大约 1 分钟、约 220 MB……'
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $r = Run $godotExe @('--headless', '--path', $here, '--import')
    if ($r.Code -ne 0) { Die "导入失败（退出码 $($r.Code)）：`n$($r.Text)" }
    $ready = @($r.Text -split "`n" | Where-Object { $_ -match 'gaussians ready' })
    $size = (Get-ChildItem $cache -Recurse -File -ErrorAction SilentlyContinue |
        Measure-Object Length -Sum).Sum
    Ok ("{0:N1}s，{1:N0} MB，{2} 个 splat 资产就绪" -f $sw.Elapsed.TotalSeconds, ($size / 1MB), $ready.Count)
}

# ---------------------------------------------------------------- 4. 冒烟测试
Step 4 '冒烟测试（真渲染一张图）'
if ($SkipSmoke) {
    Warn '已按 -SkipSmoke 跳过'
} else {
    $shot = Join-Path $here 'artifacts/overview_rehearsal.png'
    Remove-Item $shot -Force -ErrorAction SilentlyContinue
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $r = Run $godotExe @(
        '--path', $here, '--rendering-driver', 'vulkan', '--resolution', '320x180',
        'res://overview.tscn', '--', '--capture', '--only=rehearsal'
    )
    if ($r.Code -ne 0) {
        Warn "渲染失败（退出码 $($r.Code)）"
        Say ($r.Text -split "`n" | Where-Object { $_ -match 'ERROR|Vulkan|driver' } |
                Select-Object -First 6 | ForEach-Object { '        ' + $_.Trim() })
        Die '多数是显卡/驱动问题，或无窗口环境。可先用 -SkipSmoke 跳过。'
    }
    if (-not (Test-Path $shot)) { Die "渲染进程正常退出，但没有出图：$shot" }
    $kb = (Get-Item $shot).Length / 1KB
    if ($kb -lt 1) { Die "出图为空文件：$shot" }
    $backend = ($r.Text -split "`n" | Where-Object { $_ -match 'rendering backend' } | Select-Object -First 1)
    Ok ("{0:N1}s，出图 {1:N0} KB{2}" -f $sw.Elapsed.TotalSeconds, $kb,
        $(if ($backend) { "，" + $backend.Trim() } else { '' }))
}

# ---------------------------------------------------------------- 5. 烘焙环境
if ($WithBaker) {
    Step 5 '美术烘焙环境（可选路线）'
    $nodeCmd = Get-Command node -ErrorAction SilentlyContinue
    if ($nodeCmd) {
        $nv = (Run 'node' @('-v')).Text.Trim()
        if ($nv -match '^v(\d+)' -and [int]$Matches[1] -ge 18) { Ok "Node $nv" }
        else { Die "Node 需要 18+，当前 $nv" }
    } else {
        Die '需要 Node 18+（ink-studio 是 Node 脚本，无需构建）'
    }

    $pipeline = Join-Path (Split-Path $here -Parent) 'art-pipeline'
    if (-not (Test-Path $pipeline)) {
        Warn "缺少兄弟目录 art-pipeline: $pipeline"
        Say '        这是导出器仓库，单独 clone 到同级即可。'
    } else {
        Ok "art-pipeline: $pipeline"
        try {
            $ink = (& node (Join-Path $pipeline 'find-ink.js') 2>&1 | Out-String).Trim()
            Ok "ink-studio: $ink"
        } catch {
            Warn '找不到 ink-studio 仓库'
            Say @'
        它是私有仓库，需要向项目负责人申请读权限，然后：
          git clone <私有地址> <本目录同级>/shapeshift-labs-ink-studio
          git -C <该目录> checkout 1350b4f        # 见 art-pipeline/VERSIONS.md
        或设置环境变量 INK_STUDIO_DIR 指向已有的副本。
        不安装也不影响看图 —— 仓库里已经带了导出的资产。
'@
        }
        if (Test-Path (Join-Path $pipeline 'inkstudio2ply.js') -and (Test-Path $ink)) {
            $tmp = Join-Path $env:TEMP 'ink-bake-smoke.ply'
            $r = Run 'node' @((Join-Path $pipeline 'inkstudio2ply.js'), '--scene', 'rehearsal', '--out', $tmp)
            if ($r.Code -eq 0) { Ok '烘焙冒烟（rehearsal）通过' }
            else { Warn "烘焙冒烟失败：$($r.Text)" }
            Remove-Item $tmp -Force -ErrorAction SilentlyContinue
        }
    }
}

# ---------------------------------------------------------------- 完成
Say ''
Say '---------------- 可以开始了 ----------------'
Say "  主场景   : & `"$godotExe`" --path `"$here`" res://main.tscn"
Say "  角色动画 : & `"$godotExe`" --path `"$here`" res://courier.tscn"
Say "  VFX      : & `"$godotExe`" --path `"$here`" res://vfx.tscn"
Say "  七场景   : & `"$godotExe`" --path `"$here`" res://overview.tscn"
Say ''
Say '  抓图（--headless 出不了图，必须开窗口）：'
Say "    ... res://main.tscn -- --capture     # -> artifacts/shot.png"
Say ''
Say "  工程内详细命令见 README-RUN.md，管线原理见 ../art-pipeline/SPEC-inkstudio-to-godot-ply.md"
