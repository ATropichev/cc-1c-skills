# skd-decompile v0.1 — Decompile 1C DCS Template.xml to JSON DSL (draft)
# Source: https://github.com/Nikolay-Shirokov/cc-1c-skills
param(
	[Parameter(Mandatory)]
	[Alias('Path')]
	[string]$TemplatePath,

	[string]$OutputPath
)

$ErrorActionPreference = "Stop"
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

# --- 0. Resolve and validate input ---

if (-not (Test-Path $TemplatePath)) {
	Write-Error "Template not found: $TemplatePath"
	exit 1
}

$TemplatePath = (Resolve-Path $TemplatePath).Path

$xmlDoc = New-Object System.Xml.XmlDocument
$xmlDoc.PreserveWhitespace = $false
$xmlDoc.Load($TemplatePath)

$root = $xmlDoc.DocumentElement

# Ring 3: not a DataCompositionSchema → fail-fast
if ($root.LocalName -ne 'DataCompositionSchema') {
	Write-Error "Root element <$($root.LocalName)> is not <DataCompositionSchema>. This is not a SKD template (perhaps a spreadsheet — use /mxl-decompile)."
	exit 2
}

# --- 1. Namespace manager ---

$ns = New-Object System.Xml.XmlNamespaceManager($xmlDoc.NameTable)
$ns.AddNamespace("dcs",    "http://v8.1c.ru/8.1/data-composition-system/schema")
$ns.AddNamespace("dcscom", "http://v8.1c.ru/8.1/data-composition-system/common")
$ns.AddNamespace("dcscor", "http://v8.1c.ru/8.1/data-composition-system/core")
$ns.AddNamespace("dcsset", "http://v8.1c.ru/8.1/data-composition-system/settings")
$ns.AddNamespace("dcsat",  "http://v8.1c.ru/8.1/data-composition-system/areatemplate")
$ns.AddNamespace("v8",     "http://v8.1c.ru/8.1/data/core")
$ns.AddNamespace("v8ui",   "http://v8.1c.ru/8.1/data/ui")
$ns.AddNamespace("xs",     "http://www.w3.org/2001/XMLSchema")
$ns.AddNamespace("xsi",    "http://www.w3.org/2001/XMLSchema-instance")

# Root may use default namespace = schema; XPath needs explicit prefix
$rootNS = $root.NamespaceURI
if (-not $rootNS) { $rootNS = "http://v8.1c.ru/8.1/data-composition-system/schema" }
# Re-bind dcs to actual root namespace if different
$ns.AddNamespace("r", $rootNS)

# --- 2. Warnings accumulator ---

$script:warnings = @()
$script:warningCounter = 0

function Add-Warning {
	param([string]$kind, [string]$loc, [string]$detail)
	$script:warningCounter++
	$id = "W{0:D3}" -f $script:warningCounter
	$script:warnings += [ordered]@{ id = $id; kind = $kind; loc = $loc; detail = $detail }
	return $id
}

function New-Sentinel {
	param([string]$kind, [string]$loc, [string]$detail)
	$id = Add-Warning -kind $kind -loc $loc -detail $detail
	return [ordered]@{ '__unsupported__' = [ordered]@{ id = $id; kind = $kind; loc = $loc } }
}

# --- 3. Extract: dataSets (query only, no fields yet) ---

function Get-Text {
	param($node, [string]$xpath)
	if (-not $node) { return $null }
	$n = $node.SelectSingleNode($xpath, $ns)
	if ($n) { return $n.InnerText } else { return $null }
}

$dataSets = @()
$dsNodes = $root.SelectNodes("r:dataSet", $ns)
foreach ($dsNode in $dsNodes) {
	$xsiType = $dsNode.GetAttribute("type", "http://www.w3.org/2001/XMLSchema-instance")
	$name = Get-Text $dsNode "r:name"
	$ds = [ordered]@{ name = $name }

	switch -Regex ($xsiType) {
		'DataSetQuery$' {
			$query = Get-Text $dsNode "r:query"
			# Decode XML entities — XmlDocument already decoded &amp; → & in InnerText
			$ds['query'] = $query
			# fields — layer 3
		}
		'DataSetObject$' {
			$ds['objectName'] = Get-Text $dsNode "r:objectName"
		}
		'DataSetUnion$' {
			$ds['__unsupported__'] = (New-Sentinel -kind 'DataSetUnion' -loc "dataSet[name=$name]" -detail 'Реализуется в слое 15')['__unsupported__']
		}
		default {
			$ds['__unsupported__'] = (New-Sentinel -kind "DataSetType:$xsiType" -loc "dataSet[name=$name]" -detail "Неизвестный тип набора данных")['__unsupported__']
		}
	}

	$dataSets += $ds
}

# --- 4. Build top-level JSON object ---

$out = [ordered]@{
	dataSets = $dataSets
}

# --- 5. Serialize ---

$json = $out | ConvertTo-Json -Depth 32

# Unescape \uXXXX → UTF-8 literals (PS 5.1 ConvertTo-Json escapes non-ASCII)
$json = [regex]::Replace($json, '\\u([0-9a-fA-F]{4})', {
	param($m)
	[char][int]("0x" + $m.Groups[1].Value)
})

if ($OutputPath) {
	if (-not [System.IO.Path]::IsPathRooted($OutputPath)) {
		$OutputPath = Join-Path (Get-Location).Path $OutputPath
	}
	$enc = New-Object System.Text.UTF8Encoding($false)
	[System.IO.File]::WriteAllText($OutputPath, $json, $enc)

	# Write warnings.md alongside, if any
	if ($script:warnings.Count -gt 0) {
		$wPath = [System.IO.Path]::ChangeExtension($OutputPath, $null).TrimEnd('.') + '.warnings.md'
		$sb = New-Object System.Text.StringBuilder
		[void]$sb.AppendLine("# skd-decompile warnings")
		[void]$sb.AppendLine("")
		[void]$sb.AppendLine("Source: $TemplatePath")
		[void]$sb.AppendLine("")
		foreach ($w in $script:warnings) {
			[void]$sb.AppendLine("- **$($w.id)** ($($w.kind)) at `$($w.loc)`: $($w.detail)")
		}
		[System.IO.File]::WriteAllText($wPath, $sb.ToString(), $enc)
		Write-Host "Warnings written: $wPath ($($script:warnings.Count) issue(s))" -ForegroundColor Yellow
	}

	# Summary to stderr
	$stats = "dataSets=$($dataSets.Count), warnings=$($script:warnings.Count)"
	[Console]::Error.WriteLine("Decompiled: $stats")
} else {
	Write-Output $json
	if ($script:warnings.Count -gt 0) {
		[Console]::Error.WriteLine("Warnings ($($script:warnings.Count)):")
		foreach ($w in $script:warnings) {
			[Console]::Error.WriteLine("  $($w.id) [$($w.kind)] $($w.loc): $($w.detail)")
		}
	}
}
