# mxl-compile v1.26 — Compile 1C spreadsheet from JSON
# Source: https://github.com/Nikolay-Shirokov/cc-1c-skills
param(
	[Parameter(Mandatory)]
	[string]$JsonPath,

	[Parameter(Mandatory)]
	[string]$OutputPath
)

$ErrorActionPreference = "Stop"
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

# --- Support guard (Ext/ParentConfigurations.bin) ---
# See docs/1c-support-state-spec.md. Blocks edits of vendor objects "на замке" /
# read-only configs unless allowed. Trigger = bin present; reaction from
# .v8-project.json editingAllowedCheck (deny|warn|off, default deny). Never
# throws — guard errors degrade to allow.
function Get-RootUuid([string]$xmlPath) {
	if (-not (Test-Path $xmlPath)) { return $null }
	try {
		[xml]$mx = Get-Content -Path $xmlPath -Encoding UTF8
		$el = $mx.DocumentElement.FirstChild
		while ($el -and $el.NodeType -ne 'Element') { $el = $el.NextSibling }
		if ($el) { $u = $el.GetAttribute("uuid"); if ($u) { return $u } }
	} catch {}
	return $null
}
function Test-ExternalObjectRoot([string]$xmlPath) {
	if (-not (Test-Path $xmlPath)) { return $false }
	try {
		[xml]$mx = Get-Content -Path $xmlPath -Encoding UTF8
		$el = $mx.DocumentElement.FirstChild
		while ($el -and $el.NodeType -ne 'Element') { $el = $el.NextSibling }
		if ($el) { return @('ExternalDataProcessor','ExternalReport') -contains $el.LocalName }
	} catch {}
	return $false
}
function Find-V8Project([string]$startDir) {
	$d = $startDir
	for ($i = 0; $i -lt 20 -and $d; $i++) {
		$pj = Join-Path $d ".v8-project.json"
		if (Test-Path $pj) { return $pj }
		$parent = [System.IO.Path]::GetDirectoryName($d)
		if ($parent -eq $d) { break }
		$d = $parent
	}
	return $null
}
function Get-EditMode([string]$cfgDir) {
	try {
		$pj = Find-V8Project (Get-Location).Path
		if (-not $pj) { $pj = Find-V8Project $cfgDir }
		if (-not $pj) { return 'deny' }
		$proj = Get-Content -Raw $pj | ConvertFrom-Json
		$cfgFull = [System.IO.Path]::GetFullPath($cfgDir).TrimEnd('\', '/')
		if ($proj.databases) {
			foreach ($db in $proj.databases) {
				if ($db.configSrc) {
					$src = [System.IO.Path]::GetFullPath($db.configSrc).TrimEnd('\', '/')
					if ($cfgFull -eq $src -or $cfgFull.StartsWith($src + [System.IO.Path]::DirectorySeparatorChar)) {
						if ($db.editingAllowedCheck) { return $db.editingAllowedCheck }
					}
				}
			}
		}
		if ($proj.editingAllowedCheck) { return $proj.editingAllowedCheck }
		return 'deny'
	} catch { return 'deny' }
}
function Assert-EditAllowed([string]$targetPath, [string]$require) {
	try {
		$rp = $targetPath
		try { $rp = (Resolve-Path $targetPath -ErrorAction Stop).Path } catch {}
		# Autonomous external object (EPF/ERF): never part of a config on support (issue #39).
		if (Test-ExternalObjectRoot $rp) { return }
		$elemUuid = Get-RootUuid $rp
		$cfgDir = $null; $binPath = $null
		$d = if (Test-Path $rp -PathType Container) { $rp } else { [System.IO.Path]::GetDirectoryName($rp) }
		for ($i = 0; $i -lt 12 -and $d; $i++) {
			if (Test-ExternalObjectRoot "$d.xml") { return }
			if (-not $elemUuid) { $elemUuid = Get-RootUuid "$d.xml" }
			if (-not $cfgDir) {
				$cand = Join-Path (Join-Path $d "Ext") "ParentConfigurations.bin"
				if ((Test-Path $cand) -or (Test-Path (Join-Path $d "Configuration.xml"))) { $cfgDir = $d; $binPath = $cand }
			}
			if ($elemUuid -and $cfgDir) { break }
			$parent = [System.IO.Path]::GetDirectoryName($d)
			if ($parent -eq $d) { break }
			$d = $parent
		}
		# New object (no element file): fall back to config root uuid.
		if (-not $elemUuid -and $cfgDir) { $elemUuid = Get-RootUuid (Join-Path $cfgDir "Configuration.xml") }
		if (-not $binPath -or -not (Test-Path $binPath)) { return }
		$bytes = [System.IO.File]::ReadAllBytes($binPath)
		if ($bytes.Length -le 32) { return }
		$start = 0
		if ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) { $start = 3 }
		$text = [System.Text.Encoding]::UTF8.GetString($bytes, $start, $bytes.Length - $start)
		$hm = [regex]::Match($text, '^\{6,(\d+),(\d+),')
		if (-not $hm.Success) { return }
		$G = [int]$hm.Groups[1].Value
		$K = [int]$hm.Groups[2].Value
		if ($K -eq 0) { return }
		$best = $null
		if ($elemUuid) {
			$u = [regex]::Escape($elemUuid.ToLower())
			foreach ($m in [regex]::Matches($text, "([0-2]),0,$u")) {
				$f1 = [int]$m.Groups[1].Value
				if ($null -eq $best -or $f1 -lt $best) { $best = $f1 }
			}
		}
		$blocked = $false; $code = ""; $reason = ""
		if ($G -eq 1) { $blocked = $true; $code = "capability-off"; $reason = "возможность изменения конфигурации выключена (вся конфигурация read-only)" }
		elseif ($require -eq 'removed') {
			if ($null -ne $best -and $best -ne 2) { $blocked = $true; $code = "not-removed"; $reason = "объект не снят с поддержки — удаление сломает обновления" }
		}
		else {
			if ($null -ne $best -and $best -eq 0) { $blocked = $true; $code = "locked"; $reason = "объект на замке — редактирование сломает обновления" }
		}
		if (-not $blocked) { return }
		$mode = Get-EditMode $cfgDir
		if ($mode -eq 'off') { return }
		# Use Console.Error (not Write-Error) — under ErrorActionPreference=Stop the
		# latter throws and would be swallowed by this function's own catch.
		if ($mode -eq 'warn') { [Console]::Error.WriteLine("[support-guard] ПРЕДУПРЕЖДЕНИЕ: $reason. Цель: $rp"); return }
		$head = "[support-guard] Редактирование отклонено: это объект типовой конфигурации на поддержке поставщика, прямое редактирование молча сломает будущие обновления."
		$cfe = "Рекомендуемый путь: внести доработку в расширение (навыки cfe-borrow / cfe-patch-method) — состояние поддержки менять не нужно, обновления вендора сохраняются."
		$offNote = "Снять проверку для этой базы: editingAllowedCheck = warn|off в .v8-project.json."
		if ($code -eq "capability-off") {
			$state = "Состояние: у всей конфигурации выключена возможность изменения (режим read-only «из коробки») — поэтому объект «$rp» редактировать нельзя."
			$fix = "Либо снять защиту явно (навык support-edit, два шага):`n  1. support-edit -Path ""$cfgDir"" -Capability on — включить возможность изменения (объекты пока остаются на замке);`n  2. support-edit -Path ""$rp"" -Set editable — открыть этот объект для редактирования.`n  Изменение применяется в базу полной загрузкой выгрузки и обходит механизм обновлений вендора."
		} elseif ($code -eq "not-removed") {
			$state = "Состояние: объект «$rp» на поддержке (не снят с поддержки) — его удаление разорвёт обновления вендора."
			$fix = "Либо сначала снять объект с поддержки, затем удалять:`n  support-edit -Path ""$rp"" -Set off-support — объект уходит из-под обновлений, после этого удаление безопасно."
		} else {
			$state = "Состояние: объект «$rp» на замке (возможность изменения конфигурации включена, но сам объект не редактируется)."
			$fix = "Либо разрешить редактирование этого объекта (навык support-edit, выбрать одно):`n  support-edit -Path ""$rp"" -Set editable — редактировать и дальше получать обновления вендора (возможны конфликты слияния);`n  support-edit -Path ""$rp"" -Set off-support — снять с поддержки: обновления по объекту больше не приходят."
		}
		[Console]::Error.WriteLine("$head`n$state`n$cfe`n$fix`n$offNote")
		exit 1
	} catch { return }
}

# --- Detect XML format version ---
# У корня <document> нет атрибута version, поэтому версию берём из конфигурации, в дерево
# которой пишем макет. Вне конфигурации (автономный .xml, исходники EPF) остаётся 2.17.

function Detect-FormatVersion([string]$dir) {
	$d = $dir
	while ($d) {
		# Автономная внешняя обработка/отчёт: своего Configuration.xml у неё нет, версию несёт
		# корень самой обработки. Без этого форма и макет внутри обработки 2.21 писались бы 2.17.
		$extPath = "$d.xml"
		if (Test-Path $extPath) {
			$extText = [System.IO.File]::ReadAllText($extPath, [System.Text.Encoding]::UTF8)
			$extHead = $extText.Substring(0, [Math]::Min(2000, $extText.Length))
			if ($extHead -match '<(ExternalDataProcessor|ExternalReport)[ >]' -and $extHead -match '<MetaDataObject[^>]+version="(\d+\.\d+)"') { return $Matches[1] }
		}
		$cfgPath = Join-Path $d "Configuration.xml"
		if (Test-Path $cfgPath) {
			$cfgText = [System.IO.File]::ReadAllText($cfgPath, [System.Text.Encoding]::UTF8)
			# Длину среза берём по СТРОКЕ, а не по размеру файла: размер в БАЙТАХ, Substring считает
			# СИМВОЛЫ, и на кириллице байт больше — короткий Configuration.xml ронял навык исключением.
			$head = $cfgText.Substring(0, [Math]::Min(2000, $cfgText.Length))
			if ($head -match '<MetaDataObject[^>]+version="(\d+\.\d+)"') { return $Matches[1] }
		}
		$parent = Split-Path $d -Parent
		if ($parent -eq $d) { break }
		$d = $parent
	}
	return "2.17"
}

# Версия формата как число для сравнений: "2.20" → 220, "2.9" → 209.
# Строковое сравнение здесь неверно ("2.9" > "2.17" лексикографически) — известная ловушка.
function Get-FormatRank([string]$ver) {
	if ($ver -match '^(\d+)\.(\d+)$') { return [int]$Matches[1] * 100 + [int]$Matches[2] }
	return 0
}

$script:outPathResolved = if ([System.IO.Path]::IsPathRooted($OutputPath)) { $OutputPath } else { Join-Path (Get-Location) $OutputPath }
$script:formatVersion = Detect-FormatVersion ([System.IO.Path]::GetDirectoryName($script:outPathResolved))

# --- 1. Load and validate JSON ---

if (-not (Test-Path $JsonPath)) {
	[Console]::Error.WriteLine("File not found: $JsonPath")
	exit 1
}

$json = Get-Content -Raw -Encoding UTF8 $JsonPath
$def = $json | ConvertFrom-Json

# Проверяем НАЛИЧИЕ ключа, а не истинность значения: `columns: 0` — осмысленная величина
# (раскладка по умолчанию пустая, все строки живут в именованных раскладках), а пустой
# список областей встречается у макета без строк. Прежняя проверка `-not` объявляла и то
# и другое отсутствующим.
if (-not $def.PSObject.Properties['columns'] -or $null -eq $def.columns) {
	[Console]::Error.WriteLine("Required field 'columns' is missing")
	exit 1
}
if (-not $def.PSObject.Properties['areas'] -or $null -eq $def.areas) {
	[Console]::Error.WriteLine("Required field 'areas' is missing")
	exit 1
}

$totalColumns = [int]$def.columns
$defaultWidth = if ($def.defaultWidth) { [int]$def.defaultWidth } else { 10 }

# --- 2. Build font palette ---

$fontMap = [ordered]@{}   # name -> 0-based index
$fontEntries = @()        # array of hashtables

# Размер шрифта бывает дробным (8.3, 11.3). [int] его ТИХО округлял. Читаем инвариантной
# культурой и держим целым, когда дробной части нет, — иначе "10" стало бы "10.0".
function ConvertTo-FontSize {
	param($raw)
	$s = [string]$raw
	if ([string]::IsNullOrWhiteSpace($s)) { return 0 }
	$d = 0.0
	if (-not [double]::TryParse($s, [System.Globalization.NumberStyles]::Float,
			[System.Globalization.CultureInfo]::InvariantCulture, [ref]$d)) { return 0 }
	if ($d -eq [math]::Floor($d)) { return [int]$d }
	return $d
}

# Число в XML-атрибут: интерполяция строкой отдала бы "8,3" под русской культурой.
function Format-Num {
	param($v)
	return [System.Convert]::ToString($v, [System.Globalization.CultureInfo]::InvariantCulture)
}

function Add-Font {
	param([string]$name, $fontDef)
	$face = if ($fontDef.face) { $fontDef.face } else { "Arial" }
	$size = if ($fontDef.size) { ConvertTo-FontSize $fontDef.size } else { 10 }
	$bold = if ($fontDef.bold -eq $true) { "true" } else { "false" }
	$italic = if ($fontDef.italic -eq $true) { "true" } else { "false" }
	$underline = if ($fontDef.underline -eq $true) { "true" } else { "false" }
	$strikeout = if ($fontDef.strikeout -eq $true) { "true" } else { "false" }

	$idx = $script:fontEntries.Count
	$script:fontMap[$name] = $idx
	$script:fontEntries += @{
		Face      = $face
		Size      = $size
		Bold      = $bold
		Italic    = $italic
		Underline = $underline
		Strikeout = $strikeout
	}
}

# Add user-defined fonts
$hasDefault = $false
if ($def.fonts) {
	foreach ($prop in $def.fonts.PSObject.Properties) {
		if ($prop.Name -eq "default") { $hasDefault = $true }
		Add-Font -name $prop.Name -fontDef $prop.Value
	}
}

# Ensure default font exists
if (-not $hasDefault) {
	$defaultDef = New-Object PSObject -Property @{ face = "Arial"; size = 10 }
	Add-Font -name "default" -fontDef $defaultDef
}

# --- 3. Determine line palette ---

$hasThinBorders = $false
$hasThickBorders = $false

# Scan styles for border usage
if ($def.styles) {
	foreach ($prop in $def.styles.PSObject.Properties) {
		$s = $prop.Value
		if ($s.border -and $s.border -ne "none") {
			if ($s.borderWidth -eq "thick") {
				$hasThickBorders = $true
			} else {
				$hasThinBorders = $true
			}
		}
	}
}

$thinLineIndex = -1
$thickLineIndex = -1
$lineCount = 0
if ($hasThinBorders) {
	$thinLineIndex = $lineCount; $lineCount++
}
if ($hasThickBorders) {
	$thickLineIndex = $lineCount; $lineCount++
}

# --- 4. Parse column width specs ---

function Parse-ColumnSpec {
	param([string]$spec)
	$cols = @()
	foreach ($part in $spec -split ',') {
		$part = $part.Trim()
		if ($part -match '^(\d+)-(\d+)$') {
			$from = [int]$Matches[1]
			$to = [int]$Matches[2]
			for ($i = $from; $i -le $to; $i++) { $cols += $i }
		} else {
			$cols += [int]$part
		}
	}
	return $cols
}

# --- 4a. Auto-calculate defaultWidth from page format ---

$pageTargets = @{
	"A4-landscape" = 780
	"A4-portrait"  = 540
}

if ($def.page) {
	$pageName = "$($def.page)"
	$targetWidth = $null

	if ($pageName -match '^\d+$') {
		$targetWidth = [int]$pageName
	} elseif ($pageTargets.ContainsKey($pageName)) {
		$targetWidth = $pageTargets[$pageName]
	} else {
		Write-Warning "Unknown page format '$pageName'. Known: $($pageTargets.Keys -join ', '), or a number."
	}

	if ($targetWidth) {
		$totalUnits = 0.0
		$absoluteSum = 0
		$specifiedCols = @{}

		if ($def.columnWidths) {
			foreach ($prop in $def.columnWidths.PSObject.Properties) {
				$val = "$($prop.Value)"
				$cols = Parse-ColumnSpec $prop.Name
				foreach ($c in $cols) {
					$specifiedCols[[int]$c] = $true
					if ($val -match '^([0-9.]+)x$') {
						$totalUnits += [double]$Matches[1]
					} else {
						$absoluteSum += [int]$val
					}
				}
			}
		}

		for ($c = 1; $c -le $totalColumns; $c++) {
			if (-not $specifiedCols.ContainsKey($c)) {
				$totalUnits += 1.0
			}
		}

		if ($totalUnits -gt 0) {
			$defaultWidth = [int][math]::Round(($targetWidth - $absoluteSum) / $totalUnits)
		}
	}
}

# Build column width map: 1-based col -> width
function Build-ColWidthMap {
	param($widths)
	$map = @{}
	if ($widths) {
		foreach ($prop in $widths.PSObject.Properties) {
			$val = "$($prop.Value)"
			if ($val -match '^([0-9.]+)x$') {
				$width = [int][math]::Round([double]$Matches[1] * $defaultWidth)
			} else {
				$width = [int]$val
			}
			foreach ($c in (Parse-ColumnSpec $prop.Name)) { $map[$c] = $width }
		}
	}
	return $map
}

$colWidthMap = Build-ColWidthMap $def.columnWidths

# Колоночные раскладки: документные columns/columnWidths — раскладка по умолчанию (в XML
# элемент <columns> БЕЗ <id>, он всегда идёт первым). Дополнительные объявляются в
# columnSets, ключ — идентификатор, на него ссылается область ключом columnSet.
# Склейки по содержимому нет: в корпусе полно раскладок с одинаковым содержимым и разными
# идентификаторами, поэтому опознаёт раскладку только идентификатор.
# Платформа хранит идентификатор раскладки как UUID и другой не принимает. Имя из
# columnSets, полученное декомпиляцией, уже UUID — оставляем как есть, иначе раундтрип
# перестал бы совпадать. Читаемое имя, написанное автором, превращаем в UUID ДЕТЕРМИНИРОВАННО
# (из хэша имени), чтобы повторная компиляция давала тот же файл.
function ConvertTo-LayoutId {
	param([string]$name)
	if ($name -match '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$') {
		return $name
	}
	# UUID версии 3 (имя + MD5, RFC 4122): биты версии и варианта проставляются, иначе это
	# не UUID, а просто шестнадцатеричная строка нужной формы.
	$md5 = [System.Security.Cryptography.MD5]::Create()
	$b = $md5.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($name))
	$b[6] = [byte](($b[6] -band 0x0F) -bor 0x30)   # версия 3
	$b[8] = [byte](($b[8] -band 0x3F) -bor 0x80)   # вариант RFC 4122
	$h = ($b | ForEach-Object { $_.ToString('x2') }) -join ''
	return "$($h.Substring(0,8))-$($h.Substring(8,4))-$($h.Substring(12,4))-$($h.Substring(16,4))-$($h.Substring(20,12))"
}

$columnLayouts = @()
$columnLayouts += @{ Id = $null; Name = $null; Size = $totalColumns; Widths = $colWidthMap }
if ($def.columnSets) {
	foreach ($prop in $def.columnSets.PSObject.Properties) {
		$cs = $prop.Value
		$size = if ($cs.columns) { [int]$cs.columns } else { $totalColumns }
		$columnLayouts += @{
			Id     = ConvertTo-LayoutId $prop.Name
			Name   = $prop.Name
			Size   = $size
			Widths = Build-ColWidthMap $cs.columnWidths
		}
	}
}

# --- 5. Style resolver ---

function Resolve-Style {
	param([string]$styleName, [string]$fillType)

	$fontIdx = $fontMap["default"]
	$lb = -1; $tb = -1; $rb = -1; $bb = -1
	$ha = ""; $va = ""; $nf = ""
	$wrap = $false

	if ($styleName -and $def.styles) {
		$style = $def.styles.$styleName
		if ($style) {
			# Font
			if ($style.font -and $fontMap.Contains($style.font)) {
				$fontIdx = $fontMap[$style.font]
			}

			# Borders
			if ($style.border -and $style.border -ne "none") {
				$lineIdx = if ($style.borderWidth -eq "thick") { $thickLineIndex } else { $thinLineIndex }
				foreach ($side in ($style.border -split ',')) {
					switch ($side.Trim()) {
						"all"    { $lb = $lineIdx; $tb = $lineIdx; $rb = $lineIdx; $bb = $lineIdx }
						"left"   { $lb = $lineIdx }
						"top"    { $tb = $lineIdx }
						"right"  { $rb = $lineIdx }
						"bottom" { $bb = $lineIdx }
					}
				}
			}

			# Alignment
			if ($style.align) {
				switch ($style.align) {
					"left"   { $ha = "Left" }
					"center" { $ha = "Center" }
					"right"  { $ha = "Right" }
				}
			}
			if ($style.valign) {
				switch ($style.valign) {
					"top"    { $va = "Top" }
					"center" { $va = "Center" }
				}
			}

			# Wrap
			if ($style.wrap -eq $true) { $wrap = $true }

			# Number format
			if ($style.format) { $nf = $style.format }
		}
	}

	return @{
		FontIdx      = $fontIdx
		LB           = $lb; TB = $tb; RB = $rb; BB = $bb
		HA           = $ha; VA = $va
		Wrap         = $wrap
		FillType     = $fillType
		NumberFormat = $nf
	}
}

# --- 6. Format palette builder ---

$formatRegistry = [ordered]@{}  # key -> hashtable with properties
$formatOrder = @()              # ordered keys for index assignment

function Get-FormatKey {
	param(
		[int]$fontIdx = -1,
		[int]$lb = -1, [int]$tb = -1, [int]$rb = -1, [int]$bb = -1,
		[string]$ha = "", [string]$va = "",
		[bool]$wrap = $false,
		[string]$fillType = "",
		[string]$numberFormat = "",
		[int]$width = -1,
		[int]$height = -1
	)
	return "f=$fontIdx|lb=$lb|tb=$tb|rb=$rb|bb=$bb|ha=$ha|va=$va|wr=$wrap|ft=$fillType|nf=$numberFormat|w=$width|h=$height"
}

function Register-Format {
	param([string]$key, [hashtable]$props)
	if (-not $script:formatRegistry.Contains($key)) {
		$script:formatRegistry[$key] = $props
		$script:formatOrder += $key
	}
	# Return 1-based index
	$idx = 0
	foreach ($k in $script:formatRegistry.Keys) {
		$idx++
		if ($k -eq $key) { return $idx }
	}
	return $idx
}

# 6a. Default width format
$defaultFormatKey = Get-FormatKey -width $defaultWidth
$defaultFormatIndex = Register-Format -key $defaultFormatKey -props @{ Width = $defaultWidth }

# 6b. Column width formats — по одной карте на каждую колоночную раскладку
foreach ($layout in $columnLayouts) {
	$map = @{}  # 1-based col -> format index
	foreach ($col in ($layout.Widths.Keys | Sort-Object)) {
		$w = $layout.Widths[$col]
		$key = Get-FormatKey -width $w
		$map[[int]$col] = Register-Format -key $key -props @{ Width = $w }
	}
	$layout.FormatMap = $map
}
$colFormatMap = $columnLayouts[0].FormatMap

# 6c. Scan areas for row heights and cell formats
# We need to do two passes: first collect all formats, then generate XML

# Helper: escape XML special characters
function Esc-Xml {
	param([string]$s)
	# Эскейп ЗНАЧЕНИЯ АТРИБУТА: & < > и кавычка — внутри "..." литеральная " невалидна.
	return $s.Replace('&','&amp;').Replace('<','&lt;').Replace('>','&gt;').Replace('"','&quot;')
}

function Esc-XmlText {
	# Экранирование ТЕКСТА элемента: только & < > . Кавычки в тексте платформа НЕ экранирует —
	# пишет литерально (проверено: 92142 сырых кавычки на корпус, ни одной &quot;). &quot; платформа
	# принимает, но при выгрузке нормализует обратно в кавычку → лишний шум в роундтрипе.
	param([string]$s)
	return $s.Replace('&','&amp;').Replace('<','&lt;').Replace('>','&gt;')
}

# Текст ячейки платформа хранит по элементу на язык. Конвенция ML-значений (та же, что у
# synonym/tooltip/title в метаданных и формах): объект — по элементу на язык В ПОРЯДКЕ КЛЮЧЕЙ,
# строка — один и тот же текст на всех языках макета (textLanguages, по умолчанию только ru).
$textLanguages = @('ru')
if ($def.textLanguages) {
	$declared = @($def.textLanguages | ForEach-Object { "$_" } | Where-Object { $_ })
	if ($declared.Count -gt 0) { $textLanguages = $declared }
}

function Emit-CellText {
	param($value)
	$pairs = @()
	if ($value -is [System.Collections.IDictionary]) {
		foreach ($k in $value.Keys) { $pairs += @{ Lang = "$k"; Text = "$($value[$k])" } }
	} elseif ($value -is [System.Management.Automation.PSCustomObject]) {
		foreach ($p in $value.PSObject.Properties) { $pairs += @{ Lang = $p.Name; Text = "$($p.Value)" } }
	} else {
		foreach ($l in $textLanguages) { $pairs += @{ Lang = $l; Text = "$value" } }
	}
	X "`t`t`t`t`t<tl>"
	foreach ($p in $pairs) {
		X "`t`t`t`t`t`t<v8:item>"
		X "`t`t`t`t`t`t`t<v8:lang>$($p.Lang)</v8:lang>"
		X "`t`t`t`t`t`t`t<v8:content>$(Esc-XmlText $p.Text)</v8:content>"
		X "`t`t`t`t`t`t</v8:item>"
	}
	X "`t`t`t`t`t</tl>"
}

# Helper: determine fillType from cell content
# Text НЕ эмитим: платформа его практически не пишет — на выборке корпуса 344 981 текстовая
# ячейка из 348 023 (99,1%) ссылается на формат БЕЗ fillType. Наличие <tl> и так означает
# текст, поэтому тег избыточен. Parameter и Template платформа пишет — их оставляем.
function Get-FillType {
	param($cell)
	if ($cell.param) { return "Parameter" }
	if ($cell.template) { return "Template" }
	return ""
}

# Helper: register a cell format and return its index
function Register-CellFormat {
	param($styleName, [string]$fillType)
	$resolved = Resolve-Style -styleName $styleName -fillType $fillType
	# Ячейка без собственного оформления ссылается на формат ПО УМОЛЧАНИЮ — так делает
	# платформа: в её палитре у неоформленного макета один формат (ширина колонки), и все
	# ячейки указывают на него. Мы же заводили каждой свой формат с <font>0</font>, где ноль
	# означает «шрифт не задан», то есть формат был пуст по смыслу.
	if ($resolved.FontIdx -eq $fontMap["default"] -and
		$resolved.LB -lt 0 -and $resolved.TB -lt 0 -and $resolved.RB -lt 0 -and $resolved.BB -lt 0 -and
		-not $resolved.HA -and -not $resolved.VA -and -not $resolved.Wrap -and
		-not $resolved.FillType -and -not $resolved.NumberFormat) {
		return $script:defaultFormatIndex
	}
	$key = Get-FormatKey -fontIdx $resolved.FontIdx `
		-lb $resolved.LB -tb $resolved.TB -rb $resolved.RB -bb $resolved.BB `
		-ha $resolved.HA -va $resolved.VA `
		-wrap $resolved.Wrap -fillType $resolved.FillType `
		-numberFormat $resolved.NumberFormat
	$props = @{
		FontIdx      = $resolved.FontIdx
		LB           = $resolved.LB; TB = $resolved.TB
		RB           = $resolved.RB; BB = $resolved.BB
		HA           = $resolved.HA; VA = $resolved.VA
		Wrap         = $resolved.Wrap
		FillType     = $resolved.FillType
		NumberFormat = $resolved.NumberFormat
	}
	return Register-Format -key $key -props $props
}

# --- 5.5. Шорткат строк: строка-массив ячеек ---
# Та же форма, что у макетов СКД (skd-compile): позиция ячейки = индекс в массиве,
# ">" продолжает ячейку слева, "|" — ячейку сверху, null — пустая колонка,
# "{Имя}" — параметр. Разворачиваем в обычную строку с явными col/span/rowspan,
# поэтому весь код ниже про шорткат не знает.

function Set-CellProp {
	param($cell, [string]$name, $value)
	$cell | Add-Member -NotePropertyName $name -NotePropertyValue $value -Force
}

function Expand-ShorthandRow {
	param($row, [string]$areaName, [int]$rowIdx, $openByCol, [int]$maxCols)

	$cells = @()
	$placed = @{}     # 1-based col -> ячейка, занимающая колонку в ЭТОЙ строке
	$extended = @()   # ячейки, чей rowspan уже нарастили в этой строке (span>1 даёт несколько "|")
	$last = $null     # последняя реальная ячейка слева — цель для ">"
	$idx = 0

	foreach ($el in $row) {
		$idx++
		# Внутри функции пишем в stderr напрямую: Write-Error приписал бы к сообщению имя
		# функции, и текст перестал бы совпадать с py-портом.
		if ($idx -gt $maxCols) {
			[Console]::Error.WriteLine("Row exceeds 'columns' ($maxCols): area `"$areaName`", row $rowIdx")
			exit 1
		}

		if ($null -eq $el) { $last = $null; continue }

		if ($el -is [string] -and $el -eq '>') {
			if ($null -eq $last) {
				[Console]::Error.WriteLine("Row shorthand: '>' has no cell to the left: area `"$areaName`", row $rowIdx, cell $idx")
				exit 1
			}
			$span = if ($last.span) { [int]$last.span } else { 1 }
			Set-CellProp $last 'span' ($span + 1)
			$placed[$idx] = $last
			continue
		}

		if ($el -is [string] -and $el -eq '|') {
			$above = $openByCol[$idx]
			if ($null -eq $above) {
				[Console]::Error.WriteLine("Row shorthand: '|' has no cell above: area `"$areaName`", row $rowIdx, cell $idx")
				exit 1
			}
			if (-not ($extended -contains $above)) {
				$rowspan = if ($above.rowspan) { [int]$above.rowspan } else { 1 }
				Set-CellProp $above 'rowspan' ($rowspan + 1)
				$extended += $above
			}
			$placed[$idx] = $above
			$last = $null
			continue
		}

		if ($el -is [string]) {
			$cell = [PSCustomObject]@{ col = $idx; span = 1 }
			$m = [regex]::Match($el, '^\{(.+)\}$')
			if ($m.Success) { Set-CellProp $cell 'param' $m.Groups[1].Value }
			else { Set-CellProp $cell 'text' $el }
		} else {
			# Объектный элемент — обычная ячейка mxl, позиция берётся из индекса.
			if ($el.PSObject.Properties['col']) {
				[Console]::Error.WriteLine("Row shorthand: cell object must not carry 'col': area `"$areaName`", row $rowIdx, cell $idx")
				exit 1
			}
			$cell = $el
			Set-CellProp $cell 'col' $idx
			if (-not $cell.span) { Set-CellProp $cell 'span' 1 }
		}

		$cells += $cell
		$placed[$idx] = $cell
		$last = $cell
		# Ячейка занимает СТОЛЬКО позиций, каков её span. У строки со следующими ">" это
		# получается само (каждый маркер съедает позицию), а объектный элемент несёт span
		# внутри — без этого сдвига всё правее него уезжало влево.
		$elSpan = if ($cell.span) { [int]$cell.span } else { 1 }
		if ($elSpan -gt 1) {
			for ($s = 1; $s -lt $elSpan; $s++) { $idx++; $placed[$idx] = $cell }
		}
	}

	# Колонки, не занятые в этой строке, теряют «ячейку сверху».
	$openByCol.Clear()
	foreach ($k in $placed.Keys) { $openByCol[$k] = $placed[$k] }

	return [PSCustomObject]@{ cells = $cells }
}

# Позиционный список ячеек опознаём по наличию хотя бы одного элемента-строки или null:
# маркеры, текст и пропуски бывают только в нём. Список из одних объектов разбирается
# как обычный — для простой строки обе трактовки дают один результат, неоднозначности нет.
function Test-PositionalCells {
	param($cells)
	if ($null -eq $cells -or -not ($cells -is [array])) { return $false }
	foreach ($el in $cells) {
		if ($null -eq $el -or $el -is [string]) { return $true }
	}
	return $false
}

# Карту занятых колонок ведём и по объектным строкам: "|" продолжает ту ячейку,
# которая реально стоит выше, независимо от того, какой формой её записали.
function Update-OpenByCol {
	param($row, $openByCol)
	$placed = @{}
	if ($row.cells) {
		foreach ($cell in $row.cells) {
			# Ячейки без col (строка с автопотоком) на этом шаге ещё не разложены — позиция
			# станет известна позже, поэтому «ячейку сверху» они не дают, и "|" под такой
			# строкой честно скажет, что сверху ничего нет.
			if (-not $cell.PSObject.Properties['col'] -or $null -eq $cell.col) { continue }
			$col = [int]$cell.col
			$span = if ($cell.span) { [int]$cell.span } else { 1 }
			for ($c = $col; $c -lt ($col + $span); $c++) { $placed[$c] = $cell }
		}
	}
	$openByCol.Clear()
	foreach ($k in $placed.Keys) { $openByCol[$k] = $placed[$k] }
}

foreach ($area in $def.areas) {
	$areaName = $area.name
	# Ширина сетки берётся из раскладки области: у каждой она своя.
	$areaMaxCols = $totalColumns
	if ($area.PSObject.Properties['columnSet'] -and "$($area.columnSet)" -ne '') {
		$lay = @($columnLayouts | Where-Object { $_.Name -eq "$($area.columnSet)" })[0]
		if ($lay) { $areaMaxCols = [int]$lay.Size }
	}
	$openByCol = @{}
	$rowIdx = 0
	$expandedRows = @()
	foreach ($row in $area.rows) {
		$rowIdx++
		if ($row -is [array]) {
			# Строка целиком массивом — сахар для { cells: [...] }.
			$expandedRows += Expand-ShorthandRow -row $row -areaName $areaName -rowIdx $rowIdx -openByCol $openByCol -maxCols $areaMaxCols
		} elseif (Test-PositionalCells $row.cells) {
			# Короткая запись — свойство СПИСКА ЯЧЕЕК, а не строки: свои height и rowStyle
			# строка при этом сохраняет.
			$expanded = Expand-ShorthandRow -row $row.cells -areaName $areaName -rowIdx $rowIdx -openByCol $openByCol -maxCols $areaMaxCols
			$row.cells = $expanded.cells
			$expandedRows += $row
		} else {
			$expandedRows += $row
			if ($row.empty) { $openByCol.Clear() } else { Update-OpenByCol -row $row -openByCol $openByCol }
		}
	}
	$area.rows = $expandedRows
}

# Pre-register all formats from areas
foreach ($area in $def.areas) {
	foreach ($row in $area.rows) {
		# Skip empty row placeholder
		if ($row.empty) { continue }

		# Row height format
		if ($row.height) {
			$hKey = Get-FormatKey -height ([int]$row.height)
			Register-Format -key $hKey -props @{ Height = [int]$row.height } | Out-Null
		}

		# rowStyle gap-fill format (no content → no fillType)
		if ($row.rowStyle) {
			Register-CellFormat -styleName $row.rowStyle -fillType "" | Out-Null
		}

		# Explicit cell formats
		if ($row.cells) {
			foreach ($cell in $row.cells) {
				$cellStyle = if ($cell.style) { $cell.style } elseif ($row.rowStyle) { $row.rowStyle } else { "default" }
				$ft = Get-FillType $cell
				Register-CellFormat -styleName $cellStyle -fillType $ft | Out-Null
			}
		}
	}
}

# --- 7. Generate XML ---

$xml = New-Object System.Text.StringBuilder 4096

function X {
	param([string]$text)
	$script:xml.AppendLine($text) | Out-Null
}

# 7a. Header
$docNsDecl = 'xmlns="http://v8.1c.ru/8.2/data/spreadsheet" xmlns:style="http://v8.1c.ru/8.1/data/ui/style" xmlns:v8="http://v8.1c.ru/8.1/data/core" xmlns:v8ui="http://v8.1c.ru/8.1/data/ui" xmlns:xs="http://www.w3.org/2001/XMLSchema" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance"'
# 2.21 (8.5) добавила в шапку пространство палитры. Вставляем НА МЕСТО (перед style):
# платформа держит объявления по алфавиту, дописать в конец нельзя.
if ((Get-FormatRank $script:formatVersion) -ge 221) {
	$docNsDecl = $docNsDecl -replace ' xmlns:style=', ' xmlns:pal="http://v8.1c.ru/8.1/data/ui/colors/palette" xmlns:style='
}
X '<?xml version="1.0" encoding="UTF-8"?>'
X "<document $docNsDecl>"

# 7b. Language settings
X "`t<languageSettings>"
X "`t`t<currentLanguage>ru</currentLanguage>"
X "`t`t<defaultLanguage>ru</defaultLanguage>"
X "`t`t<languageInfo>"
X "`t`t`t<id>ru</id>"
X "`t`t`t<code>Русский</code>"
X "`t`t`t<description>Русский</description>"
X "`t`t</languageInfo>"
X "`t</languageSettings>"

# 7c. Columns
# Раскладка по умолчанию идёт первой и без <id> — так их хранит платформа.
foreach ($layout in $columnLayouts) {
	X "`t<columns>"
	if ($layout.Id) { X "`t`t<id>$($layout.Id)</id>" }
	X "`t`t<size>$($layout.Size)</size>"

	# Emit columnsItem for columns with non-default widths
	foreach ($col in ($layout.FormatMap.Keys | Sort-Object)) {
		$fmtIdx = $layout.FormatMap[$col]
		$colIdx = $col - 1  # Convert to 0-based
		X "`t`t<columnsItem>"
		X "`t`t`t<index>$colIdx</index>"
		X "`t`t`t<column>"
		X "`t`t`t`t<formatIndex>$fmtIdx</formatIndex>"
		X "`t`t`t</column>"
		X "`t`t</columnsItem>"
	}

	X "`t</columns>"
}

# 7d. Rows — main generation loop
$globalRow = 0
$merges = @()
$namedItems = @()
$totalRowCount = 0

foreach ($area in $def.areas) {
	$areaStartRow = $globalRow
	$areaName = $area.name
	$activeRowspans = @()  # @{ColStart=1-based; ColEnd=1-based; EndLocalRow=int}
	$localRow = 0
	# Ссылка области на колоночную раскладку — её получают все строки области.
	# Раскладка адресуется ИМЕНЕМ из columnSets — инлайновой формы в этом DSL нет ни у чего
	# (стиль и шрифт тоже только по имени). Иначе сообщение включало бы сериализованный
	# объект, а он у портов выглядит по-разному.
	if ($area.PSObject.Properties['columnSet'] -and
		($area.columnSet -is [System.Management.Automation.PSCustomObject] -or $area.columnSet -is [System.Collections.IDictionary])) {
		[Console]::Error.WriteLine("'columnSet' must be a name declared in columnSets, got an object: area `"$($area.name)`"")
		exit 1
	}
	$areaColumnSetName = if ($area.PSObject.Properties['columnSet']) { "$($area.columnSet)" } else { '' }
	$areaColumnSet = ''
	$areaLayout = $columnLayouts[0]
	if ($areaColumnSetName) {
		$areaLayout = @($columnLayouts | Where-Object { $_.Name -eq $areaColumnSetName })[0]
		if (-not $areaLayout) {
			[Console]::Error.WriteLine("Unknown 'columnSet': `"$areaColumnSetName`" is not declared in columnSets")
			exit 1
		}
		$areaColumnSet = $areaLayout.Id
	}
	# Ширина сетки — у КАЖДОЙ раскладки своя, поэтому позиции колонок сверяем с ней,
	# а не с документным columns (у макетов с раскладками умолчание бывает и пустым).
	$areaColumns = [int]$areaLayout.Size

	foreach ($row in $area.rows) {
		# Empty row placeholder: emit N empty rows
		if ($row.empty) {
			$count = [int]$row.empty
			for ($ei = 0; $ei -lt $count; $ei++) {
				X "`t<rowsItem>"
				X "`t`t<index>$globalRow</index>"
				X "`t`t<row>"
				X "`t`t`t<empty>true</empty>"
				X "`t`t</row>"
				X "`t</rowsItem>"
				$globalRow++; $localRow++
			}
			continue
		}

		# Build set of columns occupied by rowspans from previous rows
		$rowspanOccupied = @{}  # 1-based col -> $true
		foreach ($rs in $activeRowspans) {
			if ($localRow -gt $rs.StartLocalRow -and $localRow -le $rs.EndLocalRow) {
				for ($c = $rs.ColStart; $c -le $rs.ColEnd; $c++) {
					$rowspanOccupied[$c] = $true
				}
			}
		}

		$rowHasContent = $false
		$rowCells = @()  # array of { Col(0-based), FormatIdx, Content }

		# Determine row height format
		$rowFormatIdx = 0
		if ($row.height) {
			$hKey = Get-FormatKey -height ([int]$row.height)
			# Find format index for this key
			$rIdx = 0
			foreach ($k in $formatRegistry.Keys) {
				$rIdx++
				if ($k -eq $hKey) { $rowFormatIdx = $rIdx; break }
			}
		}

		if ($row.cells -and $row.cells.Count -gt 0) {
			$rowHasContent = $true

			# Прощающий ввод: строка, в которой НИ У ОДНОЙ ячейки нет col, раскладывается
			# слева направо с учётом span и rowspan сверху. Канон один и он в документации —
			# col обязателен; здесь мы лишь спасаем естественный DSL вместо тихой порчи
			# ($null -> [int]0 -> Col = -1). Смешанную строку не угадываем: это опечатка.
			$positioned = @($row.cells | Where-Object {
				$_.PSObject.Properties['col'] -and $null -ne $_.col -and "$($_.col)" -ne ""
			})
			if ($positioned.Count -eq 0) {
				$cursor = 1
				foreach ($cell in $row.cells) {
					$colSpan = if ($cell.span) { [int]$cell.span } else { 1 }
					while ($true) {
						$isFree = $true
						for ($c = $cursor; $c -lt ($cursor + $colSpan); $c++) {
							if ($rowspanOccupied[$c]) { $isFree = $false; break }
						}
						if ($isFree) { break }
						$cursor++
					}
					if (($cursor + $colSpan - 1) -gt $areaColumns) {
						[Console]::Error.WriteLine("Row exceeds 'columns' ($areaColumns): area `"$areaName`", row $($localRow + 1)")
						exit 1
					}
					$cell | Add-Member -NotePropertyName col -NotePropertyValue $cursor -Force
					$cursor += $colSpan
				}
			} elseif ($positioned.Count -ne $row.cells.Count) {
				[Console]::Error.WriteLine("Cell without 'col' mixed with positioned cells: area `"$areaName`", row $($localRow + 1)")
				exit 1
			}

			# Позиция обязана быть в 1..columns: до этой проверки нечисловой или нулевой col
			# молча превращался в Col = -1 и давал битую ячейку без единого сообщения.
			$cellIdx = 0
			foreach ($cell in $row.cells) {
				$cellIdx++
				$colParsed = 0
				if (-not [int]::TryParse("$($cell.col)", [ref]$colParsed) -or $colParsed -lt 1 -or $colParsed -gt $areaColumns) {
					[Console]::Error.WriteLine("Invalid 'col' value `"$($cell.col)`": area `"$areaName`", row $($localRow + 1), cell $cellIdx")
					exit 1
				}
			}

			# Build set of occupied columns (1-based): explicit cells + rowspan from above
			$occupiedCols = @{}
			foreach ($rsk in $rowspanOccupied.Keys) { $occupiedCols[$rsk] = $true }
			foreach ($cell in $row.cells) {
				$colStart = [int]$cell.col
				$colSpan = if ($cell.span) { [int]$cell.span } else { 1 }
				for ($c = $colStart; $c -lt ($colStart + $colSpan); $c++) {
					$occupiedCols[$c] = $true
				}
			}

			# Generate explicit cells
			foreach ($cell in $row.cells) {
				$colStart = [int]$cell.col
				$colSpan = if ($cell.span) { [int]$cell.span } else { 1 }
				$rowspan = if ($cell.rowspan) { [int]$cell.rowspan } else { 1 }
				$cellStyle = if ($cell.style) { $cell.style } elseif ($row.rowStyle) { $row.rowStyle } else { "default" }
				$ft = Get-FillType $cell
				$fmtIdx = Register-CellFormat -styleName $cellStyle -fillType $ft

				$cellInfo = @{
					Col       = $colStart - 1  # 0-based
					FormatIdx = $fmtIdx
					Param     = $cell.param
					Detail    = $cell.detail
					Text      = $cell.text
					Template  = $cell.template
				}
				$rowCells += $cellInfo

				# Track rowspan for subsequent rows
				if ($rowspan -gt 1) {
					$activeRowspans += @{
						ColStart      = $colStart
						ColEnd        = $colStart + $colSpan - 1
						StartLocalRow = $localRow
						EndLocalRow   = $localRow + $rowspan - 1
					}
				}

				# Collect merge (horizontal, vertical, or both)
				if ($colSpan -gt 1 -or $rowspan -gt 1) {
					$merge = @{ R = $globalRow; C = $colStart - 1; W = $colSpan - 1 }
					if ($rowspan -gt 1) { $merge.H = $rowspan - 1 }
					$merges += $merge
				}
			}

			# Generate gap-fill cells for rowStyle
			if ($row.rowStyle) {
				$gapFmtIdx = Register-CellFormat -styleName $row.rowStyle -fillType ""
				for ($c = 1; $c -le $totalColumns; $c++) {
					if (-not $occupiedCols.ContainsKey($c)) {
						$rowCells += @{
							Col       = $c - 1  # 0-based
							FormatIdx = $gapFmtIdx
							Param     = $null
							Detail    = $null
							Text      = $null
							Template  = $null
						}
					}
				}
			}

			# Sort cells by column
			$rowCells = $rowCells | Sort-Object { $_.Col }

		} elseif ($row.rowStyle) {
			# Row with only rowStyle, no explicit cells — fill non-rowspan columns
			$rowHasContent = $true
			$gapFmtIdx = Register-CellFormat -styleName $row.rowStyle -fillType ""
			for ($c = 1; $c -le $totalColumns; $c++) {
				if ($rowspanOccupied.ContainsKey($c)) { continue }
				$rowCells += @{
					Col       = $c - 1
					FormatIdx = $gapFmtIdx
					Param     = $null
					Detail    = $null
					Text      = $null
					Template  = $null
				}
			}
		}

		# Emit rowsItem
		X "`t<rowsItem>"
		X "`t`t<index>$globalRow</index>"
		X "`t`t<row>"

		if ($areaColumnSet) {
			X "`t`t`t<columnsID>$areaColumnSet</columnsID>"
		}

		if ($rowFormatIdx -gt 0) {
			X "`t`t`t<formatIndex>$rowFormatIdx</formatIndex>"
		}

		if (-not $rowHasContent) {
			X "`t`t`t<empty>true</empty>"
		} else {
			foreach ($cellInfo in $rowCells) {
				X "`t`t`t<c>"
				X "`t`t`t`t<i>$($cellInfo.Col)</i>"
				X "`t`t`t`t<c>"
				X "`t`t`t`t`t<f>$($cellInfo.FormatIdx)</f>"

				if ($cellInfo.Param) {
					X "`t`t`t`t`t<parameter>$($cellInfo.Param)</parameter>"
					if ($cellInfo.Detail) {
						X "`t`t`t`t`t<detailParameter>$($cellInfo.Detail)</detailParameter>"
					}
				}

				# Проверяем НАЛИЧИЕ ключа, а не истинность: пустая строка — это текст, платформа
				# такие ячейки пишет с пустым <tl>, и по истинности он терялся.
				if ($null -ne $cellInfo.Text) { Emit-CellText $cellInfo.Text }

				if ($null -ne $cellInfo.Template) { Emit-CellText $cellInfo.Template }

				X "`t`t`t`t</c>"
				X "`t`t`t</c>"
			}
		}

		X "`t`t</row>"
		X "`t</rowsItem>"

		$localRow++
		$globalRow++
	}

	$areaEndRow = $globalRow - 1
	# Блок без имени — просто кусок сетки: строки, не принадлежащие ни одной именованной
	# области (в корпусе таких дыр 34%, а макетов вовсе без Rows-областей — 21%).
	# Имя на блоке — сахар: разворачиваем его в обычную именованную область типа Rows.
	if (-not [string]::IsNullOrEmpty($areaName)) {
		$namedItems += @{
			Name     = $areaName
			BeginRow = $areaStartRow
			EndRow   = $areaEndRow
			BeginCol = -1
			EndCol   = -1
		}
	}
}

$totalRowCount = $globalRow

# 7d-bis. Именованные области, заданные координатами (namedAreas).
# Нужны для всего, что блоком не выражается: области не-Rows и пересекающиеся Rows.
# Ось, которую не указали, означает «вся» — так же устроен ТабличныйДокумент.Область().

# Диапазон — та же грамматика, что у columnWidths: число или "N-M". Список через запятую
# для области бессмыслен: область непрерывна, платформа разрывную не хранит.
function ConvertTo-AreaRange {
	param($spec, [string]$axis, [string]$where)
	if ($null -eq $spec) { return $null }
	$s = ([string]$spec).Trim()
	if ($s -eq '') { return $null }
	if ($s.Contains(',')) {
		[Console]::Error.WriteLine("namedAreas: '$axis' must be a single number or range, got list `"$s`": $where")
		exit 1
	}
	if ($s -match '^(\d+)\s*-\s*(\d+)$') {
		$from = [int]$Matches[1]; $to = [int]$Matches[2]
	} elseif ($s -match '^(\d+)$') {
		$from = [int]$Matches[1]; $to = $from
	} else {
		[Console]::Error.WriteLine("namedAreas: invalid '$axis' value `"$s`": $where")
		exit 1
	}
	# Платформа трактует 0 как 1 (см. описание Область()) — принимаем так же.
	if ($from -lt 1) { $from = 1 }
	if ($to -lt $from) {
		[Console]::Error.WriteLine("namedAreas: '$axis' range is reversed `"$s`": $where")
		exit 1
	}
	return @{ From = $from; To = $to }
}

# Прощающий ввод: платформенный адрес "R1C1:R2C2" — модель, пишущая код на встроенном
# языке, естественно потянется за ним. В документацию не выносим.
function ConvertFrom-R1C1 {
	param([string]$s)
	$m = [regex]::Match($s.Trim(), '^R(\d+)(?:C(\d+))?(?::R(\d+)(?:C(\d+))?)?$', 'IgnoreCase')
	if (-not $m.Success) {
		$m2 = [regex]::Match($s.Trim(), '^C(\d+)(?::C(\d+))?$', 'IgnoreCase')
		if (-not $m2.Success) { return $null }
		$c1 = [int]$m2.Groups[1].Value
		$c2 = if ($m2.Groups[2].Success) { [int]$m2.Groups[2].Value } else { $c1 }
		return @{ Rows = $null; Cols = @{ From = $c1; To = $c2 } }
	}
	$r1 = [int]$m.Groups[1].Value
	$r2 = if ($m.Groups[3].Success) { [int]$m.Groups[3].Value } else { $r1 }
	$cols = $null
	if ($m.Groups[2].Success) {
		$c1 = [int]$m.Groups[2].Value
		$c2 = if ($m.Groups[4].Success) { [int]$m.Groups[4].Value } else { $c1 }
		$cols = @{ From = $c1; To = $c2 }
	}
	return @{ Rows = @{ From = $r1; To = $r2 }; Cols = $cols }
}

if ($def.namedAreas) {
	$naIdx = 0
	foreach ($na in $def.namedAreas) {
		$naIdx++
		$naName = "$($na.name)"
		$where = "namedAreas[$naIdx]" + $(if ($naName) { " `"$naName`"" } else { '' })
		if ([string]::IsNullOrEmpty($naName)) {
			[Console]::Error.WriteLine("namedAreas: 'name' is required: $where")
			exit 1
		}
		$rows = ConvertTo-AreaRange $na.rows 'rows' $where
		$cols = ConvertTo-AreaRange $na.cols 'cols' $where
		if (-not $rows -and -not $cols) {
			$addr = $null
			foreach ($k in 'area', 'at', 'address') {
				if ($na.PSObject.Properties[$k] -and "$($na.$k)" -ne '') { $addr = "$($na.$k)"; break }
			}
			if ($addr) {
				$parsed = ConvertFrom-R1C1 $addr
				if ($null -eq $parsed) {
					[Console]::Error.WriteLine("namedAreas: invalid address `"$addr`": $where")
					exit 1
				}
				$rows = $parsed.Rows; $cols = $parsed.Cols
			}
		}
		if (-not $rows -and -not $cols) {
			[Console]::Error.WriteLine("namedAreas: at least one of 'rows'/'cols' is required: $where")
			exit 1
		}
		# DSL 1-based, XML 0-based; отсутствующая ось помечается -1.
		$namedItems += @{
			Name     = $naName
			BeginRow = if ($rows) { $rows.From - 1 } else { -1 }
			EndRow   = if ($rows) { $rows.To - 1 } else { -1 }
			BeginCol = if ($cols) { $cols.From - 1 } else { -1 }
			EndCol   = if ($cols) { $cols.To - 1 } else { -1 }
		}
	}
}

# 7e. Scalar metadata
X "`t<templateMode>true</templateMode>"
X "`t<defaultFormatIndex>$defaultFormatIndex</defaultFormatIndex>"
X "`t<height>$totalRowCount</height>"
X "`t<vgRows>$totalRowCount</vgRows>"

# 7f. Merges
foreach ($m in $merges) {
	X "`t<merge>"
	X "`t`t<r>$($m.R)</r>"
	X "`t`t<c>$($m.C)</c>"
	if ($m.H) { X "`t`t<h>$($m.H)</h>" }
	X "`t`t<w>$($m.W)</w>"
	X "`t</merge>"
}

# 7g. Named items
# Платформа хранит именованные элементы ОТСОРТИРОВАННЫМИ по имени: на выборке 541 макета
# с несколькими элементами иного порядка нет ни разу. Сортировка регистронезависимая и
# ординальная — Sort-Object брать нельзя, он сортирует по текущей культуре и на кириллице
# даст другой порядок. NB: имён с «ё» в выборке не встретилось, этот случай не проверен.
$sortedNamedItems = @($namedItems | Sort-Object -Property @{ Expression = { $_.Name.ToLowerInvariant() } } `
	-CaseSensitive)
foreach ($ni in $sortedNamedItems) {
	# Тип области выводится из указанных осей, как в ТабличныйДокумент.Область():
	# нет колонок → полоса строк, нет строк → полоса колонок, обе → прямоугольник.
	$hasRows = $ni.BeginRow -ge 0
	$hasCols = $ni.BeginCol -ge 0
	$type = if ($hasRows -and $hasCols) { 'Rectangle' } elseif ($hasCols) { 'Columns' } else { 'Rows' }
	X "`t<namedItem xsi:type=`"NamedItemCells`">"
	X "`t`t<name>$($ni.Name)</name>"
	X "`t`t<area>"
	X "`t`t`t<type>$type</type>"
	X "`t`t`t<beginRow>$($ni.BeginRow)</beginRow>"
	X "`t`t`t<endRow>$($ni.EndRow)</endRow>"
	X "`t`t`t<beginColumn>$($ni.BeginCol)</beginColumn>"
	X "`t`t`t<endColumn>$($ni.EndCol)</endColumn>"
	X "`t`t</area>"
	X "`t</namedItem>"
}

# 7h. Line palette
if ($hasThinBorders) {
	X "`t<line width=`"1`" gap=`"false`">"
	X "`t`t<v8ui:style xsi:type=`"v8ui:SpreadsheetDocumentCellLineType`">Solid</v8ui:style>"
	X "`t</line>"
}
if ($hasThickBorders) {
	X "`t<line width=`"2`" gap=`"false`">"
	X "`t`t<v8ui:style xsi:type=`"v8ui:SpreadsheetDocumentCellLineType`">Solid</v8ui:style>"
	X "`t</line>"
}

# 7i. Font palette
foreach ($fe in $fontEntries) {
	X "`t<font faceName=`"$($fe.Face)`" height=`"$(Format-Num $fe.Size)`" bold=`"$($fe.Bold)`" italic=`"$($fe.Italic)`" underline=`"$($fe.Underline)`" strikeout=`"$($fe.Strikeout)`" kind=`"Absolute`" scale=`"100`"/>"
}

# 7j. Format palette
foreach ($key in $formatRegistry.Keys) {
	$fmt = $formatRegistry[$key]
	X "`t<format>"

	if ($fmt.FontIdx -ne $null -and $fmt.FontIdx -ge 0) {
		X "`t`t<font>$($fmt.FontIdx)</font>"
	}
	if ($fmt.LB -ne $null -and $fmt.LB -ge 0) {
		X "`t`t<leftBorder>$($fmt.LB)</leftBorder>"
	}
	if ($fmt.TB -ne $null -and $fmt.TB -ge 0) {
		X "`t`t<topBorder>$($fmt.TB)</topBorder>"
	}
	if ($fmt.RB -ne $null -and $fmt.RB -ge 0) {
		X "`t`t<rightBorder>$($fmt.RB)</rightBorder>"
	}
	if ($fmt.BB -ne $null -and $fmt.BB -ge 0) {
		X "`t`t<bottomBorder>$($fmt.BB)</bottomBorder>"
	}
	if ($fmt.Width) {
		X "`t`t<width>$($fmt.Width)</width>"
	}
	if ($fmt.Height) {
		X "`t`t<height>$($fmt.Height)</height>"
	}
	if ($fmt.HA) {
		X "`t`t<horizontalAlignment>$($fmt.HA)</horizontalAlignment>"
	}
	if ($fmt.VA) {
		X "`t`t<verticalAlignment>$($fmt.VA)</verticalAlignment>"
	}
	if ($fmt.Wrap -eq $true) {
		X "`t`t<textPlacement>Wrap</textPlacement>"
	}
	if ($fmt.FillType) {
		X "`t`t<fillType>$($fmt.FillType)</fillType>"
	}
	if ($fmt.NumberFormat) {
		X "`t`t<format>"
		X "`t`t`t<v8:item>"
		X "`t`t`t`t<v8:lang>ru</v8:lang>"
		X "`t`t`t`t<v8:content>$(Esc-XmlText $fmt.NumberFormat)</v8:content>"
		X "`t`t`t</v8:item>"
		X "`t`t</format>"
	}

	X "`t</format>"
}

# 7k. Close document
X '</document>'

# --- 8. Write output ---

$enc = New-Object System.Text.UTF8Encoding($true)
$resolvedPath = if ([System.IO.Path]::IsPathRooted($OutputPath)) { $OutputPath } else { Join-Path (Get-Location) $OutputPath }
# Каталог назначения создаём сами: типовой путь — Templates/<Имя>/Ext/Template.xml,
# и его может ещё не быть. Так делают и form-compile, и skd-compile, и py-порт этого
# навыка; без этого PS-порт падал на «Could not find a part of the path».
$outDir = [System.IO.Path]::GetDirectoryName($resolvedPath)
if ($outDir -and -not (Test-Path $outDir)) { New-Item -ItemType Directory -Path $outDir -Force | Out-Null }
Assert-EditAllowed $resolvedPath 'editable'
[System.IO.File]::WriteAllText($resolvedPath, $xml.ToString().TrimEnd("`r", "`n"), $enc)

# --- 9. Summary ---

Write-Host "[OK] Compiled: $OutputPath"
if ($def.page) {
	Write-Host "     Page: $pageName -> target $targetWidth, defaultWidth=$defaultWidth"
}
Write-Host "     Areas: $($namedItems.Count), Rows: $totalRowCount, Columns: $totalColumns"
Write-Host "     Fonts: $($fontEntries.Count), Lines: $lineCount, Formats: $($formatRegistry.Count)"
Write-Host "     Merges: $($merges.Count)"
