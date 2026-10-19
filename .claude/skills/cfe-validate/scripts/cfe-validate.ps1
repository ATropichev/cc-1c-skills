# cfe-validate v1.24 — Validate 1C configuration extension structure (CFE)
# Source: https://github.com/Nikolay-Shirokov/cc-1c-skills
[CmdletBinding(PositionalBinding=$false)]
param(
	[Parameter(Mandatory, Position=0)]
	[Alias('Path')]
	[string]$ExtensionPath,

	[switch]$Detailed,

	[int]$MaxErrors = 30,

	[string]$OutFile,

	# Конфигурация-источник. Без неё проверки, требующие сравнения с основной конфигурацией,
	# пропускаются (о чём сказано в отчёте), остальные работают как раньше.
	[string]$ConfigPath
)

$ErrorActionPreference = "Stop"
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

# --- Resolve path ---
if (-not [System.IO.Path]::IsPathRooted($ExtensionPath)) {
	$ExtensionPath = Join-Path (Get-Location).Path $ExtensionPath
}

if (Test-Path $ExtensionPath -PathType Container) {
	$candidate = Join-Path $ExtensionPath "Configuration.xml"
	if (Test-Path $candidate) {
		$ExtensionPath = $candidate
	} else {
		Write-Host "[ERROR] No Configuration.xml found in directory: $ExtensionPath"
		exit 1
	}
}

if (-not (Test-Path $ExtensionPath)) {
	Write-Host "[ERROR] File not found: $ExtensionPath"
	exit 1
}

$resolvedPath = (Resolve-Path $ExtensionPath).Path
$configDir = Split-Path $resolvedPath -Parent

# --- Output infrastructure ---
$script:errors = 0
$script:warnings = 0
$script:okCount = 0
$script:stopped = $false
$script:output = New-Object System.Text.StringBuilder 8192

function Out-Line {
	param([string]$msg)
	$script:output.AppendLine($msg) | Out-Null
}

function Report-OK {
	param([string]$msg)
	$script:okCount++
	if ($Detailed) { Out-Line "[OK]    $msg" }
}

function Report-Error {
	param([string]$msg)
	$script:errors++
	Out-Line "[ERROR] $msg"
	if ($script:errors -ge $MaxErrors) {
		$script:stopped = $true
	}
}

function Report-Warn {
	param([string]$msg)
	$script:warnings++
	Out-Line "[WARN]  $msg"
}

$finalize = {
	$checks = $script:okCount + $script:errors + $script:warnings
	if ($script:errors -eq 0 -and $script:warnings -eq 0 -and -not $Detailed) {
		$result = "=== Validation OK: Extension.$objName ($checks checks) ==="
	} else {
		Out-Line ""
		Out-Line "=== Result: $($script:errors) errors, $($script:warnings) warnings ($checks checks) ==="
		$result = $script:output.ToString()
	}
	Write-Host $result

	if ($OutFile) {
		$utf8Bom = New-Object System.Text.UTF8Encoding $true
		[System.IO.File]::WriteAllText($OutFile, $result, $utf8Bom)
		Write-Host "Written to: $OutFile"
	}
}

# --- Format version ---
# Проверенный диапазон версий формата выгрузки: 2.17 (8.3.24) … 2.21 (8.5). Полная лестница —
# docs/1c-configuration-spec.md, «Лестница версий». Версию задаёт платформа ВЫГРУЗКИ, а не режим
# совместимости конфигурации. Версии ниже 2.17 (платформы 8.3.23 и старше) существуют, но навыки
# на них не проверялись — это предупреждение о непокрытии, а не о некорректности файла.
$formatVerifiedMin = "2.17"
$formatVerifiedMax = "2.21"
# Версия формата как число: "2.20" → 220. Строковое сравнение неверно ("2.9" > "2.17").
function Get-FormatRank([string]$ver) {
	if ($ver -match '^(\d+)\.(\d+)$') { return [int]$Matches[1] * 100 + [int]$Matches[2] }
	return 0
}

# Штамп версии формата — атрибут version КОРНЕВОГО элемента файла. Копия общего эталона (семья
# root_version, авторитет — meta-validate). Корневого: в Form.xml расширения ниже стоит <BaseForm version=…>.
function Get-RootVersion([string]$xmlPath) {
	if (-not (Test-Path -LiteralPath $xmlPath -PathType Leaf)) { return $null }
	$buf = New-Object byte[] 4096
	$fs = [System.IO.File]::OpenRead($xmlPath)
	try { $len = $fs.Read($buf, 0, $buf.Length) } finally { $fs.Dispose() }
	$head = [System.Text.Encoding]::UTF8.GetString($buf, 0, $len)
	$m = [regex]::Match($head, '<[A-Za-z_][\w.:-]*(\s[^>]*)?/?>')
	if (-not $m.Success) { return $null }
	$v = [regex]::Match($m.Groups[1].Value, '(?:^|\s)version="([^"]*)"')
	if ($v.Success) { return $v.Groups[1].Value }
	return $null
}

# --- Reference tables ---
# Модули заимствованных объектов: тип → виды модулей. Имя свойства в <xr:PropertyState>
# совпадает с базовым именем файла модуля. Копия таблицы есть в cfe-borrow (навыки автономны).
$moduleKindsByType = @{
	"CommonModule"=@("Module"); "HTTPService"=@("Module"); "WebService"=@("Module")
	"Catalog"=@("ObjectModule","ManagerModule"); "Document"=@("ObjectModule","ManagerModule")
	"Report"=@("ObjectModule","ManagerModule"); "DataProcessor"=@("ObjectModule","ManagerModule")
	"ExchangePlan"=@("ObjectModule","ManagerModule")
	"ChartOfCharacteristicTypes"=@("ObjectModule","ManagerModule")
	"ChartOfAccounts"=@("ObjectModule","ManagerModule")
	"ChartOfCalculationTypes"=@("ObjectModule","ManagerModule")
	"BusinessProcess"=@("ObjectModule","ManagerModule"); "Task"=@("ObjectModule","ManagerModule")
	"InformationRegister"=@("RecordSetModule","ManagerModule")
	"AccumulationRegister"=@("RecordSetModule","ManagerModule")
	"AccountingRegister"=@("RecordSetModule","ManagerModule")
	"CalculationRegister"=@("RecordSetModule","ManagerModule")
	"Sequence"=@("RecordSetModule","ManagerModule")
	"Constant"=@("ValueManagerModule","ManagerModule")
	"Enum"=@("ManagerModule"); "DocumentJournal"=@("ManagerModule")
	"FilterCriterion"=@("ManagerModule")
}

$guidPattern ='^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$'
$identPattern = '^[A-Za-z\u0410-\u042F\u0401\u0430-\u044F\u0451_][A-Za-z0-9\u0410-\u042F\u0401\u0430-\u044F\u0451_]*$'

# 7 fixed ClassIds for Configuration
$validClassIds = @(
	"9cd510cd-abfc-11d4-9434-004095e12fc7",
	"9fcd25a0-4822-11d4-9414-008048da11f9",
	"e3687481-0a87-462c-a166-9f34594f9bba",
	"9de14907-ec23-4a07-96f0-85521cb6b53b",
	"51f2d5d8-ea4d-4064-8892-82951750031e",
	"e68182ea-4237-4383-967f-90c1e3370bc7",
	"fb282519-d103-4dd3-bc12-cb271d631dfc"
)

# 46 types in canonical order
$childObjectTypes = @(
	"Language","Subsystem","StyleItem","Style",
	"CommonPicture","SessionParameter","Role","CommonTemplate",
	"FilterCriterion","CommonModule","CommonAttribute","ExchangePlan",
	"XDTOPackage","WebService","HTTPService","WSReference",
	"EventSubscription","ScheduledJob","SettingsStorage","FunctionalOption",
	"FunctionalOptionsParameter","DefinedType","Bot","PaletteColor","CommonCommand","CommandGroup",
	"Constant","CommonForm","Catalog","Document",
	"DocumentNumerator","Sequence","DocumentJournal","Enum",
	"Report","DataProcessor","InformationRegister","AccumulationRegister",
	"ChartOfCharacteristicTypes","ChartOfAccounts","AccountingRegister",
	"ChartOfCalculationTypes","CalculationRegister",
	"BusinessProcess","Task","ExternalDataSource","IntegrationService"
)

# Type -> directory mapping
$childTypeDirMap = @{
	"Language"="Languages"; "Subsystem"="Subsystems"; "StyleItem"="StyleItems"; "Style"="Styles"; "Bot"="Bots"; "PaletteColor"="PaletteColors"
	"CommonPicture"="CommonPictures"; "SessionParameter"="SessionParameters"; "Role"="Roles"
	"CommonTemplate"="CommonTemplates"; "FilterCriterion"="FilterCriteria"; "CommonModule"="CommonModules"
	"CommonAttribute"="CommonAttributes"; "ExchangePlan"="ExchangePlans"; "XDTOPackage"="XDTOPackages"
	"WebService"="WebServices"; "HTTPService"="HTTPServices"; "WSReference"="WSReferences"
	"EventSubscription"="EventSubscriptions"; "ScheduledJob"="ScheduledJobs"
	"SettingsStorage"="SettingsStorages"; "FunctionalOption"="FunctionalOptions"
	"FunctionalOptionsParameter"="FunctionalOptionsParameters"; "DefinedType"="DefinedTypes"
	"CommonCommand"="CommonCommands"; "CommandGroup"="CommandGroups"; "Constant"="Constants"
	"CommonForm"="CommonForms"; "Catalog"="Catalogs"; "Document"="Documents"
	"DocumentNumerator"="DocumentNumerators"; "Sequence"="Sequences"
	"DocumentJournal"="DocumentJournals"; "Enum"="Enums"; "Report"="Reports"
	"DataProcessor"="DataProcessors"; "InformationRegister"="InformationRegisters"
	"AccumulationRegister"="AccumulationRegisters"
	"ChartOfCharacteristicTypes"="ChartsOfCharacteristicTypes"
	"ChartOfAccounts"="ChartsOfAccounts"; "AccountingRegister"="AccountingRegisters"
	"ChartOfCalculationTypes"="ChartsOfCalculationTypes"
	"CalculationRegister"="CalculationRegisters"
	"BusinessProcess"="BusinessProcesses"; "Task"="Tasks"
	"ExternalDataSource"="ExternalDataSources"; "IntegrationService"="IntegrationServices"
}

# Наборы GeneratedType по типу объекта (эталон — таблица §2.5 спецификации конфигурации).
# Неполный набор в заимствованной оболочке платформа отвергает при загрузке: «отсутствует один
# или более типов объекта <Тип>». Типы, у которых GeneratedType нет вовсе (общие модули,
# подписки, регламентные задания и т.п.), в карте отсутствуют — для них проверка не выполняется.
$generatedTypeCategories = @{
	"Catalog"                    = @("Object","Ref","Selection","List","Manager")
	"Document"                   = @("Object","Ref","Selection","List","Manager")
	"Enum"                       = @("Ref","Manager","List")
	"Constant"                   = @("Manager","ValueManager","ValueKey")
	"Report"                     = @("Object","Manager")
	"DataProcessor"              = @("Object","Manager")
	"ExchangePlan"               = @("Object","Ref","Selection","List","Manager")
	"Task"                       = @("Object","Ref","Selection","List","Manager")
	"BusinessProcess"            = @("Object","Ref","Selection","List","Manager","RoutePointRef")
	"ChartOfCharacteristicTypes" = @("Object","Ref","Selection","List","Manager","Characteristic")
	"ChartOfAccounts"            = @("Object","Ref","Selection","List","Manager","ExtDimensionTypes","ExtDimensionTypesRow")
	"ChartOfCalculationTypes"    = @("Object","Ref","Selection","List","Manager","DisplacingCalculationTypes","DisplacingCalculationTypesRow","BaseCalculationTypes","BaseCalculationTypesRow","LeadingCalculationTypes","LeadingCalculationTypesRow")
	"InformationRegister"        = @("Record","Manager","Selection","List","RecordSet","RecordKey","RecordManager")
	"AccumulationRegister"       = @("Record","Manager","Selection","List","RecordSet","RecordKey")
	"AccountingRegister"         = @("Record","Manager","Selection","List","RecordSet","RecordKey","ExtDimensions")
	"CalculationRegister"        = @("Record","Manager","Selection","List","RecordSet","RecordKey","Recalcs")
	"DocumentJournal"            = @("Selection","List","Manager")
	"Sequence"                   = @("Record","Manager","RecordSet")
	"FilterCriterion"            = @("Manager","List")
	"SettingsStorage"            = @("Manager")
	"ExternalDataSource"         = @("Manager","TablesManager","CubesManager")
	"IntegrationService"         = @("Manager")
	"WSReference"                = @("Manager")
	"DefinedType"                = @("DefinedType")
}

# Стандартные поля строки табличной части: в ChildObjects их нет, но пути Объект.<ТЧ>.<Стандартный>
# законны. Имена зависят от варианта встроенного языка, поэтому держим оба написания.
$script:standardObjectFields = @(
	"Code","Description","Ref","Parent","Owner","DeletionMark","Predefined","IsFolder","LineNumber",
	"Number","Date","Posted","PredefinedDataName","RegisterRecords","DataVersion","RowsCount",
	"Код","Наименование","Ссылка","Родитель","Владелец","ПометкаУдаления","Предопределенный",
	"ЭтоГруппа","НомерСтроки","Номер","Дата","Проведен","ИмяПредопределенныхДанных",
	"Движения","ВерсияДанных","КоличествоСтрок"
)

# Стандартные реквизиты, которые платформа принимает первым сегментом пути формы, — по типу
# основного реквизита (замер 8.3.24 на собственных объектах расширения, оба написания). Набор
# зависит и от свойств объекта (Parent — иерархия, Owner — владельцы, ExtDimensionDr — корреспонденция),
# здесь — надмножество по типу. Типа нет в карте (не замерен) — пути формы не проверяются.
$script:mainAttrStandardFields = @{}
foreach ($entry in @(
	@("CatalogObject", "Code Description Ref Parent Owner DeletionMark Predefined PredefinedDataName IsFolder Код Наименование Ссылка Родитель Владелец ПометкаУдаления Предопределенный ИмяПредопределенныхДанных ЭтоГруппа"),
	@("DocumentObject", "Number Date Posted Ref DeletionMark RegisterRecords Номер Дата Проведен Ссылка ПометкаУдаления Движения"),
	@("ChartOfCharacteristicTypesObject", "Code Description Ref Parent IsFolder DeletionMark Predefined PredefinedDataName ValueType Код Наименование Ссылка Родитель ЭтоГруппа ПометкаУдаления Предопределенный ИмяПредопределенныхДанных ТипЗначения"),
	@("ChartOfAccountsObject", "Code Description Ref Parent DeletionMark Predefined PredefinedDataName OffBalance Order Type ExtDimensionTypes Код Наименование Ссылка Родитель ПометкаУдаления Предопределенный ИмяПредопределенныхДанных Забалансовый Порядок Вид ВидыСубконто"),
	@("ChartOfCalculationTypesObject", "Code Description Ref DeletionMark Predefined PredefinedDataName ActionPeriodIsBasic BaseCalculationTypes LeadingCalculationTypes DisplacingCalculationTypes Код Наименование Ссылка ПометкаУдаления Предопределенный ИмяПредопределенныхДанных ПериодДействияБазовый БазовыеВидыРасчета ВедущиеВидыРасчета ВытесняющиеВидыРасчета"),
	@("ExchangePlanObject", "Code Description Ref DeletionMark ThisNode SentNo ReceivedNo Код Наименование Ссылка ПометкаУдаления ЭтотУзел НомерОтправленного НомерПринятого"),
	@("TaskObject", "Number Date Description Ref DeletionMark BusinessProcess RoutePoint Executed Номер Дата Наименование Ссылка ПометкаУдаления БизнесПроцесс ТочкаМаршрута Выполнена"),
	@("BusinessProcessObject", "Number Date Ref DeletionMark Started Completed HeadTask Номер Дата Ссылка ПометкаУдаления Стартован Завершен ВедущаяЗадача"),
	@("DataProcessorObject", ""),
	@("ReportObject", ""),
	@("InformationRegisterRecordManager", "Period Recorder LineNumber Active Период Регистратор НомерСтроки Активность"),
	@("InformationRegisterRecordSet", "Period Recorder LineNumber Active RowsCount Период Регистратор НомерСтроки Активность КоличествоСтрок"),
	@("AccumulationRegisterRecordSet", "Period Recorder LineNumber Active RecordType RowsCount Период Регистратор НомерСтроки Активность ВидДвижения КоличествоСтрок"),
	@("AccountingRegisterRecordSet", "Period Recorder LineNumber Active RecordType RowsCount Account AccountDr AccountCr ExtDimension1 ExtDimension2 ExtDimension3 ExtDimensionDr1 ExtDimensionDr2 ExtDimensionDr3 ExtDimensionCr1 ExtDimensionCr2 ExtDimensionCr3 Период Регистратор НомерСтроки Активность ВидДвижения КоличествоСтрок Счет СчетДт СчетКт Субконто1 Субконто2 Субконто3 СубконтоДт1 СубконтоДт2 СубконтоДт3 СубконтоКт1 СубконтоКт2 СубконтоКт3"),
	@("CalculationRegisterRecordSet", "Recorder LineNumber Active RowsCount CalculationType RegistrationPeriod ReversingEntry ActionPeriod BegOfActionPeriod EndOfActionPeriod BegOfBasePeriod EndOfBasePeriod Регистратор НомерСтроки Активность КоличествоСтрок ВидРасчета ПериодРегистрации Сторно ПериодДействия ПериодДействияНачало ПериодДействияКонец БазовыйПериодНачало БазовыйПериодКонец")
)) {
	$set = New-Object System.Collections.Hashtable ([StringComparer]::OrdinalIgnoreCase)
	foreach ($n in ($entry[1] -split ' ' | Where-Object { $_ })) { $set[$n] = $true }
	$script:mainAttrStandardFields[$entry[0]] = $set
}

# Объект, по которому разрешаются пути формы, — тип её основного реквизита, а не владелец формы:
# форма обработки бывает с основным реквизитом DocumentObject.X. Берётся первый тип, который
# является объектом метаданных (префикс пространства имён любой, в т.ч. объявленный на самом <v8:Type>). Нет такого (динамический список,
# таблица значений) — $null: путь не по составу объекта.
function Get-MainAttributeTarget {
	param([string]$mainAttrXml)
	foreach ($tm in [regex]::Matches($mainAttrXml, '<v8:Type[^>]*>(?:\w+:)?(\w+?)(Object|RecordManager|RecordSet)\.([^<]+)</v8:Type>')) {
		if ($childTypeDirMap.ContainsKey($tm.Groups[1].Value)) {
			return @{
				Key = "$($tm.Groups[1].Value).$($tm.Groups[3].Value)"
				Category = "$($tm.Groups[1].Value)$($tm.Groups[2].Value)"
				TypeName = "$($tm.Groups[1].Value)$($tm.Groups[2].Value).$($tm.Groups[3].Value)"
			}
		}
	}
	return $null
}

# Valid enum values for extension properties
$validEnumValues = @{
	"ConfigurationExtensionCompatibilityMode" = @("DontUse","Version8_1","Version8_2_13","Version8_2_16","Version8_3_1","Version8_3_2","Version8_3_3","Version8_3_4","Version8_3_5","Version8_3_6","Version8_3_7","Version8_3_8","Version8_3_9","Version8_3_10","Version8_3_11","Version8_3_12","Version8_3_13","Version8_3_14","Version8_3_15","Version8_3_16","Version8_3_17","Version8_3_18","Version8_3_19","Version8_3_20","Version8_3_21","Version8_3_22","Version8_3_23","Version8_3_24","Version8_3_25","Version8_3_26","Version8_3_27","Version8_3_28","Version8_5_1")
	"DefaultRunMode" = @("ManagedApplication","OrdinaryApplication","Auto")
	"ScriptVariant" = @("Russian","English")
	"InterfaceCompatibilityMode" = @("Version8_2","Version8_2EnableTaxi","Taxi","TaxiEnableVersion8_2","TaxiEnableVersion8_5","Version8_5EnableTaxi","Version8_5")
}

# --- 1. Parse XML ---
Out-Line ""

$xmlDoc = $null
try {
	$xmlDoc = New-Object System.Xml.XmlDocument
	$xmlDoc.PreserveWhitespace = $false
	$xmlDoc.Load($resolvedPath)
} catch {
	Out-Line "=== Validation: Extension (parse failed) ==="
	Out-Line ""
	Report-Error "1. XML parse failed: $($_.Exception.Message)"
	& $finalize
	exit 1
}

# --- Register namespaces ---
$ns = New-Object System.Xml.XmlNamespaceManager($xmlDoc.NameTable)
$ns.AddNamespace("md", "http://v8.1c.ru/8.3/MDClasses")
$ns.AddNamespace("v8", "http://v8.1c.ru/8.1/data/core")
$ns.AddNamespace("xr", "http://v8.1c.ru/8.3/xcf/readable")
$ns.AddNamespace("xsi", "http://www.w3.org/2001/XMLSchema-instance")
$ns.AddNamespace("xs", "http://www.w3.org/2001/XMLSchema")
$ns.AddNamespace("app", "http://v8.1c.ru/8.2/managed-application/core")

$root = $xmlDoc.DocumentElement

# --- Check 1: Root structure ---
$check1Ok = $true
$expectedNs = "http://v8.1c.ru/8.3/MDClasses"

if ($root.LocalName -ne "MetaDataObject") {
	Report-Error "1. Root element is '$($root.LocalName)', expected 'MetaDataObject'"
	& $finalize
	exit 1
}

if ($root.NamespaceURI -ne $expectedNs) {
	Report-Error "1. Root namespace is '$($root.NamespaceURI)', expected '$expectedNs'"
	$check1Ok = $false
}

$version = $root.GetAttribute("version")
$versionRank = Get-FormatRank $version
if (-not $version) {
	Report-Warn "1. Missing version attribute on MetaDataObject"
} elseif ($versionRank -eq 0) {
	Report-Error "1. Malformed version '$version' (expected N.N)"
} elseif ($versionRank -lt (Get-FormatRank $formatVerifiedMin)) {
	Report-Warn "1. Format version '$version' is below the tested range $formatVerifiedMin-$formatVerifiedMax — skills were not verified on it"
} elseif ($versionRank -gt (Get-FormatRank $formatVerifiedMax)) {
	Report-Warn "1. Format version '$version' is above the tested range $formatVerifiedMin-$formatVerifiedMax — skills were not verified on it"
}

# Must have Configuration child
$cfgNode = $null
foreach ($child in $root.ChildNodes) {
	if ($child.NodeType -eq 'Element' -and $child.LocalName -eq "Configuration" -and $child.NamespaceURI -eq $expectedNs) {
		$cfgNode = $child; break
	}
}

if (-not $cfgNode) {
	Report-Error "1. No <Configuration> element found inside MetaDataObject"
	& $finalize
	exit 1
}

# UUID
$cfgUuid = $cfgNode.GetAttribute("uuid")
if (-not $cfgUuid) {
	Report-Error "1. Missing uuid on <Configuration>"
	$check1Ok = $false
} elseif ($cfgUuid -notmatch $guidPattern) {
	Report-Error "1. Invalid uuid '$cfgUuid' on <Configuration>"
	$check1Ok = $false
}

# Get name early for header
$propsNode = $cfgNode.SelectSingleNode("md:Properties", $ns)
$nameNode = if ($propsNode) { $propsNode.SelectSingleNode("md:Name", $ns) } else { $null }
$objName = if ($nameNode -and $nameNode.InnerText) { $nameNode.InnerText } else { "(unknown)" }

$script:output.Insert(0, "=== Validation: Extension.$objName ===$([Environment]::NewLine)") | Out-Null

if ($check1Ok) {
	Report-OK "1. Root structure: MetaDataObject/Configuration, version $version"
}

if ($script:stopped) { & $finalize; exit 1 }

# --- Check 2: InternalInfo ---
$internalInfo = $cfgNode.SelectSingleNode("md:InternalInfo", $ns)
$check2Ok = $true

if (-not $internalInfo) {
	Report-Error "2. InternalInfo: missing"
} else {
	$contained = $internalInfo.SelectNodes("xr:ContainedObject", $ns)
	if ($contained.Count -ne 7) {
		Report-Warn "2. InternalInfo: expected 7 ContainedObject, found $($contained.Count)"
	}

	$foundClassIds = @{}
	foreach ($co in $contained) {
		$classId = $co.SelectSingleNode("xr:ClassId", $ns)
		$objectId = $co.SelectSingleNode("xr:ObjectId", $ns)

		if (-not $classId -or -not $classId.InnerText) {
			Report-Error "2. ContainedObject missing ClassId"
			$check2Ok = $false
			continue
		}

		$cid = $classId.InnerText
		if ($validClassIds -notcontains $cid) {
			Report-Error "2. Unknown ClassId: $cid"
			$check2Ok = $false
		}

		if ($foundClassIds.ContainsKey($cid)) {
			Report-Error "2. Duplicate ClassId: $cid"
			$check2Ok = $false
		}
		$foundClassIds[$cid] = $true

		if (-not $objectId -or -not $objectId.InnerText) {
			Report-Error "2. ContainedObject missing ObjectId for ClassId $cid"
			$check2Ok = $false
		} elseif ($objectId.InnerText -notmatch $guidPattern) {
			Report-Error "2. Invalid ObjectId '$($objectId.InnerText)' for ClassId $cid"
			$check2Ok = $false
		}
	}

	$missingIds = @($validClassIds | Where-Object { -not $foundClassIds.ContainsKey($_) })
	if ($missingIds.Count -gt 0) {
		Report-Warn "2. Missing ClassIds: $($missingIds.Count) of 7"
	}

	if ($check2Ok) {
		Report-OK "2. InternalInfo: $($contained.Count) ContainedObject, all ClassIds valid"
	}
}

if ($script:stopped) { & $finalize; exit 1 }

# --- Check 3: Extension-specific properties ---
if (-not $propsNode) {
	Report-Error "3. Properties block missing"
} else {
	$check3Ok = $true

	# ObjectBelonging = Adopted
	$obNode = $propsNode.SelectSingleNode("md:ObjectBelonging", $ns)
	if (-not $obNode -or $obNode.InnerText -ne "Adopted") {
		Report-Error "3. ObjectBelonging must be 'Adopted', got '$($obNode.InnerText)'"
		$check3Ok = $false
	}

	# Name
	if (-not $nameNode -or -not $nameNode.InnerText) {
		Report-Error "3. Name is missing or empty"
		$check3Ok = $false
	} else {
		$nameVal = $nameNode.InnerText
		if ($nameVal -notmatch $identPattern) {
			Report-Error "3. Name '$nameVal' is not a valid 1C identifier"
			$check3Ok = $false
		}
	}

	# ConfigurationExtensionPurpose
	$purposeNode = $propsNode.SelectSingleNode("md:ConfigurationExtensionPurpose", $ns)
	$validPurposes = @("Patch","Customization","AddOn")
	if (-not $purposeNode -or -not $purposeNode.InnerText) {
		Report-Error "3. ConfigurationExtensionPurpose is missing"
		$check3Ok = $false
	} elseif ($validPurposes -notcontains $purposeNode.InnerText) {
		Report-Error "3. ConfigurationExtensionPurpose '$($purposeNode.InnerText)' invalid (expected: Patch, Customization, AddOn)"
		$check3Ok = $false
	}

	# NamePrefix
	$prefixNode = $propsNode.SelectSingleNode("md:NamePrefix", $ns)
	if (-not $prefixNode -or -not $prefixNode.InnerText) {
		Report-Warn "3. NamePrefix is empty"
	}

	# KeepMappingToExtendedConfigurationObjectsByIDs
	$keepMapNode = $propsNode.SelectSingleNode("md:KeepMappingToExtendedConfigurationObjectsByIDs", $ns)
	if (-not $keepMapNode) {
		Report-Warn "3. KeepMappingToExtendedConfigurationObjectsByIDs is missing"
	}

	# DefaultLanguage
	$defLangNode = $propsNode.SelectSingleNode("md:DefaultLanguage", $ns)
	$defLang = if ($defLangNode -and $defLangNode.InnerText) { $defLangNode.InnerText } else { "" }

	if ($check3Ok) {
		$purposeVal = if ($purposeNode) { $purposeNode.InnerText } else { "?" }
		$prefixVal = if ($prefixNode -and $prefixNode.InnerText) { $prefixNode.InnerText } else { "(empty)" }
		Report-OK "3. Extension properties: Name=`"$objName`", Purpose=$purposeVal, Prefix=$prefixVal"
	}
}

if ($script:stopped) { & $finalize; exit 1 }

# --- Check 4: Enum property values ---
if ($propsNode) {
	$enumChecked = 0
	$check4Ok = $true

	foreach ($propName in $validEnumValues.Keys) {
		$propNode = $propsNode.SelectSingleNode("md:$propName", $ns)
		if ($propNode -and $propNode.InnerText) {
			$val = $propNode.InnerText
			$allowed = $validEnumValues[$propName]
			if ($allowed -notcontains $val) {
				Report-Error "4. Property '$propName' has invalid value '$val'"
				$check4Ok = $false
			}
			$enumChecked++
		}
	}

	if ($check4Ok) {
		Report-OK "4. Property values: $enumChecked enum properties checked"
	}
} else {
	Report-Warn "4. No Properties block to check"
}

if ($script:stopped) { & $finalize; exit 1 }

# --- Check 5: ChildObjects — valid types, no duplicates, order ---
$childObjNode = $cfgNode.SelectSingleNode("md:ChildObjects", $ns)

if (-not $childObjNode) {
	Report-Error "5. ChildObjects block missing"
} else {
	$check5Ok = $true
	$totalCount = 0
	$script:childObjectIndex = @{}
	$duplicates = @{}
	$typeFirstIndex = @{}
	$lastTypeOrder = -1
	$orderOk = $true

	foreach ($child in $childObjNode.ChildNodes) {
		if ($child.NodeType -ne 'Element') { continue }
		$typeName = $child.LocalName
		$objNameVal = $child.InnerText

		$typeIdx = $childObjectTypes.IndexOf($typeName)
		if ($typeIdx -lt 0) {
			Report-Error "5. Unknown type '$typeName' in ChildObjects"
			$check5Ok = $false
		} else {
			if (-not $typeFirstIndex.ContainsKey($typeName)) {
				$typeFirstIndex[$typeName] = $typeIdx
				if ($typeIdx -lt $lastTypeOrder) {
					Report-Warn "5. Type '$typeName' is out of canonical order (after type at position $lastTypeOrder)"
					$orderOk = $false
				}
				$lastTypeOrder = $typeIdx
			}
		}

		if (-not $script:childObjectIndex.ContainsKey($typeName)) { $script:childObjectIndex[$typeName] = @{} }
		if ($script:childObjectIndex[$typeName].ContainsKey($objNameVal)) {
			if (-not $duplicates.ContainsKey("$typeName.$objNameVal")) {
				Report-Error "5. Duplicate: $typeName.$objNameVal"
				$duplicates["$typeName.$objNameVal"] = $true
				$check5Ok = $false
			}
		} else {
			$script:childObjectIndex[$typeName][$objNameVal] = $true
		}

		$totalCount++
	}

	$typeCount = $script:childObjectIndex.Count
	if ($check5Ok) {
		$orderInfo = if ($orderOk) { ", order correct" } else { "" }
		Report-OK "5. ChildObjects: $typeCount types, $totalCount objects${orderInfo}"
	}
}

if ($script:stopped) { & $finalize; exit 1 }

# --- Check 6: DefaultLanguage references existing Language in ChildObjects ---
if ($defLang -and $childObjNode) {
	$langName = $defLang
	if ($langName.StartsWith("Language.")) {
		$langName = $langName.Substring(9)
	}

	$found = $false
	foreach ($child in $childObjNode.ChildNodes) {
		if ($child.NodeType -eq 'Element' -and $child.LocalName -eq "Language" -and $child.InnerText -eq $langName) {
			$found = $true; break
		}
	}

	if ($found) {
		Report-OK "6. DefaultLanguage `"$defLang`" found in ChildObjects"
	} else {
		Report-Error "6. DefaultLanguage `"$defLang`" not found in ChildObjects"
	}
} else {
	if (-not $defLang) {
		Report-Warn "6. Cannot check DefaultLanguage (empty)"
	} else {
		Report-Warn "6. Cannot check DefaultLanguage (no ChildObjects)"
	}
}

if ($script:stopped) { & $finalize; exit 1 }

# --- Check 7: Language files exist ---
if ($childObjNode) {
	$langNames = @()
	foreach ($child in $childObjNode.ChildNodes) {
		if ($child.NodeType -eq 'Element' -and $child.LocalName -eq "Language") {
			$langNames += $child.InnerText
		}
	}

	if ($langNames.Count -gt 0) {
		$existCount = 0
		foreach ($ln in $langNames) {
			$langFile = Join-Path (Join-Path $configDir "Languages") "$ln.xml"
			if (Test-Path $langFile) {
				$existCount++
			} else {
				Report-Warn "7. Language file missing: Languages/$ln.xml"
			}
		}
		if ($existCount -eq $langNames.Count) {
			Report-OK "7. Language files: $existCount/$($langNames.Count) exist"
		}
	} else {
		Report-Warn "7. No Language entries in ChildObjects"
	}
} else {
	Report-Warn "7. Cannot check language files (no ChildObjects)"
}

if ($script:stopped) { & $finalize; exit 1 }

# --- Check 8: Object directories exist ---
if ($childObjNode) {
	$dirsToCheck = @{}
	foreach ($child in $childObjNode.ChildNodes) {
		if ($child.NodeType -ne 'Element') { continue }
		$typeName = $child.LocalName
		if ($typeName -eq "Language") { continue }
		if ($childTypeDirMap.ContainsKey($typeName)) {
			$dirName = $childTypeDirMap[$typeName]
			if (-not $dirsToCheck.ContainsKey($dirName)) {
				$dirsToCheck[$dirName] = 0
			}
			$dirsToCheck[$dirName] = $dirsToCheck[$dirName] + 1
		}
	}

	$missingDirs = @()
	foreach ($dir in $dirsToCheck.Keys) {
		$dirPath = Join-Path $configDir $dir
		if (-not (Test-Path $dirPath -PathType Container)) {
			$missingDirs += "$dir ($($dirsToCheck[$dir]) objects)"
		}
	}

	if ($missingDirs.Count -eq 0) {
		Report-OK "8. Object directories: $($dirsToCheck.Count) directories, all exist"
	} else {
		foreach ($md in $missingDirs) {
			Report-Warn "8. Missing directory: $md"
		}
	}
}

if ($script:stopped) { & $finalize; exit 1 }

# Типы подобъекта метаданных: тексты <v8:Type>; определяемый тип и прочие наборы — меткой «#TypeSet»,
# квалификаторы пропускаются.
function Get-MdTypeList {
	param($el, $nsm)
	$list = @()
	$typeNode = $el.SelectSingleNode("md:Properties/md:Type", $nsm)
	if ($typeNode) {
		foreach ($tn in $typeNode.ChildNodes) {
			if ($tn.NodeType -ne 'Element') { continue }
			if ($tn.LocalName -eq 'Type') { $list += $tn.InnerText.Trim() }
			elseif ($tn.LocalName -eq 'TypeSet') { $list += '#TypeSet' }
		}
	}
	return ,$list
}

# Типы стандартного ссылочного реквизита справочника, через который путь идёт дальше: Родитель — сам
# справочник, Владелец — единственный владелец (несколько — не замерено). Иначе $null.
function Get-StdRefTypes {
	param([string]$kind, [string]$name, [string]$seg)
	if ($kind -ne "Catalog") { return $null }
	if ($seg -in @("Parent", "Родитель")) { return ,@("cfg:CatalogRef.$name") }
	if ($seg -in @("Owner", "Владелец")) {
		$entry = $script:extObjIndex["$kind.$name"]
		if ($entry -and @($entry.Owners).Count -eq 1) {
			$om = [regex]::Match(@($entry.Owners)[0], '^(\w+)\.(.+)$')
			if ($om.Success) { return ,@("cfg:$($om.Groups[1].Value)Ref.$($om.Groups[2].Value)") }
		}
	}
	return $null
}

# Хвост пути после ссылочного реквизита: сегмент с номером $i и дальше. Замер 8.3.24: сегмент
# разрешается по целевому объекту в расширении (заимствованные и собственные подобъекты) и стандартным
# реквизитам вида — набор тот же, что у объекта ($script:mainAttrStandardFields); объекта в расширении
# нет — только стандартные.
# ТЧ цели — дальше колонка этой ТЧ; Родитель и Владелец справочника — дальше по их типу. Правило
# повторяется на каждом шаге. У составного типа (любой состав) дальше реквизита путь не разрешается.
# Не замерено (определяемый, примитивный тип, перечисление, прочие стандартные реквизиты в середине
# пути) — не проверяем. Ошибка — @(номер сегмента, текст), иначе $null.
function Get-RefTailError {
	param($types, [string[]]$segs, [int]$i)
	while ($i -lt $segs.Count) {
		$types = @($types)
		if ($types -contains '#TypeSet') { return $null }
		if ($types.Count -ge 2) {
			return @($i, "у $($segs[$i - 1]) составной тип — дальше него путь не разрешается")
		}
		if ($types.Count -ne 1) { return $null }
		$rm = [regex]::Match([string]$types[0], '^(?:\w+:)?(\w+?)Ref\.(.+)$')
		if (-not $rm.Success) { return $null }
		$tKind = $rm.Groups[1].Value; $tName = $rm.Groups[2].Value
		$tStd = $script:mainAttrStandardFields["${tKind}Object"]
		if ($null -eq $tStd) { return $null }
		$tKey = "$tKind.$tName"
		$seg = $segs[$i]
		if ($tStd.ContainsKey($seg)) {
			$stdTypes = Get-StdRefTypes $tKind $tName $seg
			if ($null -eq $stdTypes) { return $null }
			$types = $stdTypes
			$i++
			continue
		}
		$tEntry = $script:extObjIndex[$tKey]
		if (-not $tEntry) {
			if ($script:extObjListed.ContainsKey($tKey)) { return $null }
			return @($i, "у $tKey нет в расширении реквизита ${seg}: объект не заимствован, без заимствования через ссылку видны только стандартные реквизиты")
		}
		if (-not $tEntry.Names.ContainsKey($seg)) {
			return @($i, "у $tKey в расширении нет реквизита ${seg} (незаимствованный реквизит источника форме расширения не виден)")
		}
		if ($tEntry.TSColumns.ContainsKey($seg)) {
			if ($i + 1 -ge $segs.Count) { return $null }
			$col = $segs[$i + 1]
			if ($script:standardObjectFields -contains $col) { return $null }
			if (-not $tEntry.TSColumns[$seg].ContainsKey($col)) {
				return @(($i + 1), "у табличной части $seg объекта $tKey в расширении нет колонки $col")
			}
			$types = $tEntry.TSColumns[$seg][$col]
			$i += 2
			continue
		}
		$types = $tEntry.Names[$seg]
		$i++
	}
	return $null
}

# Хвост пути через ссылку — в список висячих путей формы (ключ — путь до сегмента с ошибкой).
function Add-RefTailBadPath {
	param($badPaths, [string]$rootName, [string[]]$segs, $types, [int]$i)
	$tail = Get-RefTailError $types $segs $i
	if ($tail) { $badPaths["${rootName}." + ($segs[0..$tail[0]] -join '.')] = $tail[1] }
}

# --- Check 9: Borrowed objects validation + Check 10: Sub-items ---
$script:enumValuesIndex = @{}
$script:extObjIndex = New-Object System.Collections.Hashtable ([StringComparer]::OrdinalIgnoreCase)
# Все объекты состава расширения, и те, чей файл не прочитан: отличить «объекта нет» от «не разобран»
$script:extObjListed = New-Object System.Collections.Hashtable ([StringComparer]::OrdinalIgnoreCase)
$script:formList = @()

# Собственные подобъекты данных в заимствованном объекте (реквизит, ТЧ, колонка заимствованной ТЧ,
# измерение, ресурс, признаки учёта, реквизит адресации): у ПВХ, ПС, ПВР и регистров платформа их загружает, но базу не
# обновляет («Добавление дочерних объектов этого типа к заимствованным в расширениях недопустимо»,
# 8.3.24–8.5.1 при любом режиме совместимости); у БП и Задачи — так же на платформе ниже 8.3.25, а с
# 8.3.25 можно (граница по версии платформы, не по режиму — по исходникам её не определить).
# Формы, команды и макеты — можно везде (замер 8.3.24, 8.3.27, 8.5.1).
$script:ownChildRestricted = @{
	"ChartOfCharacteristicTypes" = "Error"; "ChartOfAccounts" = "Error"; "ChartOfCalculationTypes" = "Error"
	"InformationRegister" = "Error"; "AccumulationRegister" = "Error"; "AccountingRegister" = "Error"
	"CalculationRegister" = "Error"; "BusinessProcess" = "Since8325"; "Task" = "Since8325"
}
$script:ownDataChildTags = @('Attribute','TabularSection','Dimension','Resource','AccountingFlag','ExtDimensionAccountingFlag','AddressingAttribute')

# Helper: check if sub-item has explicit borrowed metadata
function Test-BorrowedSubItem {
	param($subItem, $nsm)
	$subProps = $subItem.SelectSingleNode("md:Properties", $nsm)
	if (-not $subProps) { return $false }
	$subOb = $subProps.SelectSingleNode("md:ObjectBelonging", $nsm)
	if ($subOb -and $subOb.InnerText) { return $true }
	$subExt = $subProps.SelectSingleNode("md:ExtendedConfigurationObject", $nsm)
	return [bool]($subExt -and $subExt.InnerText)
}

# Helper: validate a borrowed Attribute/EnumValue sub-item
function Validate-BorrowedSubItem {
	param([string]$checkNum, [string]$context, [string]$subType, $subItem, $nsm)
	$subProps = $subItem.SelectSingleNode("md:Properties", $nsm)
	if (-not $subProps) {
		Report-Error "${checkNum}. ${context}: ${subType} missing Properties"
		return $false
	}
	$ok = $true
	$subOb = $subProps.SelectSingleNode("md:ObjectBelonging", $nsm)
	if (-not $subOb -or $subOb.InnerText -ne "Adopted") {
		Report-Error "${checkNum}. ${context}: ${subType} ObjectBelonging must be 'Adopted'"
		$ok = $false
	}
	$subName = $subProps.SelectSingleNode("md:Name", $nsm)
	if (-not $subName -or -not $subName.InnerText) {
		Report-Error "${checkNum}. ${context}: ${subType} missing Name"
		$ok = $false
	}
	$subExt = $subProps.SelectSingleNode("md:ExtendedConfigurationObject", $nsm)
	if (-not $subExt -or -not $subExt.InnerText) {
		Report-Error "${checkNum}. ${context}: ${subType}.$($subName.InnerText) missing ExtendedConfigurationObject"
		$ok = $false
	} elseif ($subExt.InnerText -notmatch $guidPattern) {
		Report-Error "${checkNum}. ${context}: ${subType}.$($subName.InnerText) invalid ExtendedConfigurationObject"
		$ok = $false
	}
	return $ok
}

if ($childObjNode) {
	$borrowedCount = 0
	$borrowedOk = 0
	$check9Ok = $true
	$check10Ok = $true
	$subItemCount = 0

	foreach ($child in $childObjNode.ChildNodes) {
		if ($child.NodeType -ne 'Element') { continue }
		$typeName = $child.LocalName
		$childName = $child.InnerText
		if ($typeName -eq "Language") { continue }

		if (-not $childTypeDirMap.ContainsKey($typeName)) { continue }
		$dirName = $childTypeDirMap[$typeName]
		$script:extObjListed["${typeName}.${childName}"] = $true
		$objFile = Join-Path (Join-Path $configDir $dirName) "$childName.xml"

		if (-not (Test-Path $objFile)) { continue }

		# Parse object XML
		$objDoc = $null
		try {
			$objDoc = New-Object System.Xml.XmlDocument
			$objDoc.PreserveWhitespace = $false
			$objDoc.Load($objFile)
		} catch {
			Report-Warn "9. Cannot parse $dirName/$childName.xml: $($_.Exception.Message)"
			continue
		}

		$objNs = New-Object System.Xml.XmlNamespaceManager($objDoc.NameTable)
		$objNs.AddNamespace("md", "http://v8.1c.ru/8.3/MDClasses")
		$objNs.AddNamespace("xr", "http://v8.1c.ru/8.3/xcf/readable")

		# Find the object element (Catalog, Document, etc.)
		$objRoot = $objDoc.DocumentElement
		$objEl = $null
		foreach ($c in $objRoot.ChildNodes) {
			if ($c.NodeType -eq 'Element') { $objEl = $c; break }
		}
		if (-not $objEl) { continue }

		$objProps = $objEl.SelectSingleNode("md:Properties", $objNs)
		if (-not $objProps) { continue }

		# --- Check 9: ObjectBelonging + ExtendedConfigurationObject ---
		$obNode = $objProps.SelectSingleNode("md:ObjectBelonging", $objNs)
		if ($obNode -and $obNode.InnerText -eq "Adopted") {
			$borrowedCount++

			$extObj = $objProps.SelectSingleNode("md:ExtendedConfigurationObject", $objNs)
			if (-not $extObj -or -not $extObj.InnerText) {
				Report-Error "9. Borrowed ${typeName}.${childName}: missing ExtendedConfigurationObject"
				$check9Ok = $false
			} elseif ($extObj.InnerText -notmatch $guidPattern) {
				Report-Error "9. Borrowed ${typeName}.${childName}: invalid ExtendedConfigurationObject UUID '$($extObj.InnerText)'"
				$check9Ok = $false
			} else {
				$borrowedOk++
			}

			# Полнота набора GeneratedType: платформа отвергает оболочку с неполным набором
			# («отсутствует один или более типов объекта ChartOfCharacteristicTypes»)
			$expectedCats = $generatedTypeCategories[$typeName]
			if ($expectedCats) {
				$objInfo = $objEl.SelectSingleNode("md:InternalInfo", $objNs)
				$foundCats = @{}
				if ($objInfo) {
					foreach ($gt in $objInfo.SelectNodes("xr:GeneratedType", $objNs)) {
						$cat = $gt.GetAttribute("category")
						if ($cat) { $foundCats[$cat] = $true }
					}
				}
				$missingCats = @($expectedCats | Where-Object { -not $foundCats.ContainsKey($_) })
				if ($missingCats.Count -gt 0) {
					Report-Error "9. Borrowed ${typeName}.${childName}: missing GeneratedType categor$(if ($missingCats.Count -eq 1) { 'y' } else { 'ies' }) $($missingCats -join ', ')"
					$check9Ok = $false
				}
			}
		}

		# --- Check 10: Sub-items (Attribute, TabularSection, EnumValue, Form) ---
		$objChildObjects = $objEl.SelectSingleNode("md:ChildObjects", $objNs)

		# Объект таким, каким он описан в расширении: реквизиты (и реквизиты адресации задачи, признаки
		# учёта плана счетов), измерения, ресурсы, ТЧ и колонки ТЧ — и заимствованные, и собственные;
		# значение — список типов (по нему разрешается путь через ссылочный реквизит). По этому описанию платформа разрешает пути любой формы
		# расширения (проверка 14) и таблицы <AdditionalColumns> (проверка 12); незаимствованный
		# подобъект источника она не видит. Имена регистронезависимы, как в языке 1С.
		$ixNames = New-Object System.Collections.Hashtable ([StringComparer]::OrdinalIgnoreCase)
		$ixTSColumns = New-Object System.Collections.Hashtable ([StringComparer]::OrdinalIgnoreCase)
		if ($objChildObjects) {
			foreach ($ixSub in $objChildObjects.ChildNodes) {
				if ($ixSub.NodeType -ne 'Element') { continue }
				if ($ixSub.LocalName -notin @('Attribute','Dimension','Resource','TabularSection','AddressingAttribute','AccountingFlag','ExtDimensionAccountingFlag')) { continue }
				$ixNameNode = $ixSub.SelectSingleNode("md:Properties/md:Name", $objNs)
				if (-not $ixNameNode) { continue }
				$ixName = $ixNameNode.InnerText.Trim()
				$ixNames[$ixName] = Get-MdTypeList $ixSub $objNs
				if ($ixSub.LocalName -ne 'TabularSection') { continue }
				$ixCols = New-Object System.Collections.Hashtable ([StringComparer]::OrdinalIgnoreCase)
				foreach ($ixCol in $ixSub.SelectNodes("md:ChildObjects/md:Attribute", $objNs)) {
					$ixColName = $ixCol.SelectSingleNode("md:Properties/md:Name", $objNs)
					if ($ixColName) { $ixCols[$ixColName.InnerText.Trim()] = Get-MdTypeList $ixCol $objNs }
				}
				$ixTSColumns[$ixName] = $ixCols
			}
		}
		$ixOwners = @(foreach ($ixOwner in $objEl.SelectNodes("md:Properties/md:Owners/xr:Item", $objNs)) { $ixOwner.InnerText.Trim() })
		$ixExtDim = $objEl.SelectSingleNode("md:Properties/md:ExtDimensionTypes", $objNs)
		$ixMaxExtDim = $objEl.SelectSingleNode("md:Properties/md:MaxExtDimensionCount", $objNs)
		$script:extObjIndex["${typeName}.${childName}"] = @{ Names = $ixNames; TSColumns = $ixTSColumns; Owners = $ixOwners
			ExtDimTypes = [bool]($ixExtDim -and $ixExtDim.InnerText.Trim() -and $ixMaxExtDim -and $ixMaxExtDim.InnerText.Trim()) }

		# Собственные подобъекты данных в заимствованном объекте вида, где они запрещены
		$ownRule = $null
		if ($obNode -and $obNode.InnerText -eq "Adopted") { $ownRule = $script:ownChildRestricted[$typeName] }
		if ($ownRule -and $objChildObjects) {
			$ownFound = @()
			foreach ($oc in $objChildObjects.ChildNodes) {
				if ($oc.NodeType -ne 'Element' -or $oc.LocalName -notin $script:ownDataChildTags) { continue }
				$ocName = $oc.SelectSingleNode("md:Properties/md:Name", $objNs)
				$ocLabel = "$($oc.LocalName).$(if ($ocName) { $ocName.InnerText.Trim() } else { '?' })"
				if (-not (Test-BorrowedSubItem $oc $objNs)) { $ownFound += $ocLabel; continue }
				if ($oc.LocalName -ne 'TabularSection') { continue }
				foreach ($occ in $oc.SelectNodes("md:ChildObjects/md:Attribute", $objNs)) {
					if (Test-BorrowedSubItem $occ $objNs) { continue }
					$occName = $occ.SelectSingleNode("md:Properties/md:Name", $objNs)
					$ownFound += "$ocLabel.Attribute.$(if ($occName) { $occName.InnerText.Trim() } else { '?' })"
				}
			}
			foreach ($ownLabel in $ownFound) {
				if ($script:stopped) { break }
				if ($ownRule -eq "Error") {
					Report-Error "10. ${typeName}.${childName}: собственный $ownLabel в заимствованном объекте — платформа загрузит расширение, но базу не обновит («Добавление дочерних объектов этого типа к заимствованным в расширениях недопустимо»)"
					$check10Ok = $false
				} else {
					Report-Warn "10. ${typeName}.${childName}: собственный $ownLabel в заимствованном объекте — на платформе ниже 8.3.25 базу не обновит («Добавление дочерних объектов этого типа к заимствованным в расширениях недопустимо»)"
				}
			}
		}

		if ($objChildObjects) {
			$ctx = "${typeName}.${childName}"
			foreach ($subItem in $objChildObjects.ChildNodes) {
				if ($subItem.NodeType -ne 'Element') { continue }
				$subType = $subItem.LocalName

				if ($subType -eq "Attribute") {
					if (-not (Test-BorrowedSubItem $subItem $objNs)) { continue }
					$subItemCount++
					if (-not (Validate-BorrowedSubItem "10" $ctx "Attribute" $subItem $objNs)) {
						$check10Ok = $false
					}
				}
				elseif ($subType -eq "TabularSection") {
					if (-not (Test-BorrowedSubItem $subItem $objNs)) { continue }
					$subItemCount++
					if (-not (Validate-BorrowedSubItem "10" $ctx "TabularSection" $subItem $objNs)) {
						$check10Ok = $false
					} else {
						# Check InternalInfo GeneratedTypes
						$tsInfo = $subItem.SelectSingleNode("md:InternalInfo", $objNs)
						$tsName = $subItem.SelectSingleNode("md:Properties/md:Name", $objNs)
						$tsLabel = if ($tsName) { $tsName.InnerText } else { "?" }
						if (-not $tsInfo) {
							Report-Error "10. ${ctx}: TabularSection.${tsLabel} missing InternalInfo"
							$check10Ok = $false
						} else {
							$gtNodes = $tsInfo.SelectNodes("xr:GeneratedType", $objNs)
							$hasTSCat = $false; $hasTSRCat = $false
							foreach ($gt in $gtNodes) {
								$cat = $gt.GetAttribute("category")
								if ($cat -eq "TabularSection") { $hasTSCat = $true }
								if ($cat -eq "TabularSectionRow") { $hasTSRCat = $true }
							}
							if (-not $hasTSCat -or -not $hasTSRCat) {
								Report-Error "10. ${ctx}: TabularSection.${tsLabel} missing GeneratedType (need TabularSection + TabularSectionRow)"
								$check10Ok = $false
							}
						}
						# Recurse into TS ChildObjects/Attribute
						$tsChildObjs = $subItem.SelectSingleNode("md:ChildObjects", $objNs)
						if ($tsChildObjs) {
							foreach ($tsAttr in $tsChildObjs.ChildNodes) {
								if ($tsAttr.NodeType -ne 'Element' -or $tsAttr.LocalName -ne "Attribute") { continue }
								if (-not (Test-BorrowedSubItem $tsAttr $objNs)) { continue }
								$subItemCount++
								if (-not (Validate-BorrowedSubItem "10" "${ctx}.ТЧ.${tsLabel}" "Attribute" $tsAttr $objNs)) {
									$check10Ok = $false
								}
							}
						}
					}
				}
				elseif ($subType -eq "EnumValue" -and $typeName -eq "Enum") {
					if (-not (Test-BorrowedSubItem $subItem $objNs)) { continue }
					$subItemCount++
					if (Validate-BorrowedSubItem "10" $ctx "EnumValue" $subItem $objNs) {
						$evName = $subItem.SelectSingleNode("md:Properties/md:Name", $objNs)
						if ($evName -and $evName.InnerText) {
							if (-not $script:enumValuesIndex.ContainsKey($childName)) {
								$script:enumValuesIndex[$childName] = @{}
							}
							$script:enumValuesIndex[$childName][$evName.InnerText] = $true
						}
					} else {
						$check10Ok = $false
					}
				}
				elseif ($subType -eq "Form") {
					$formName = $subItem.InnerText
					if ($formName) {
						$formMetaFile = Join-Path (Join-Path (Join-Path (Join-Path $configDir $dirName) $childName) "Forms") "${formName}.xml"
						if (-not (Test-Path $formMetaFile)) {
							Report-Error "10. ${ctx}: Form.${formName} metadata file missing"
							$check10Ok = $false
						}
						$script:formList += @{
							TypeName = $typeName; ObjName = $childName
							FormName = $formName; DirName = $dirName
						}
						$subItemCount++
					}
				}
			}
		}

		if ($script:stopped) { break }
	}

	if ($borrowedCount -eq 0) {
		Report-OK "9. Borrowed objects: none found"
	} elseif ($check9Ok) {
		Report-OK "9. Borrowed objects: $borrowedOk/$borrowedCount validated"
	}

	if ($subItemCount -eq 0) {
		Report-OK "10. Sub-items: none found"
	} elseif ($check10Ok) {
		Report-OK "10. Sub-items: $subItemCount validated (Attributes, TabularSections, EnumValues, Forms)"
	}
}

if ($script:stopped) { & $finalize; exit 1 }

# --- Check 11: Borrowed form structure ---
$script:borrowedFormsWithTree = @()
# Все формы объектов расширения с текстом Form.xml — заимствованные и собственные (проверка 14)
$script:formsWithText = @()
$check11Ok = $true
$formCount = 0

foreach ($fi in $script:formList) {
	$formCount++
	$formBase = Join-Path (Join-Path (Join-Path (Join-Path $configDir $fi.DirName) $fi.ObjName) "Forms") $fi.FormName
	$formMetaFile = Join-Path (Split-Path $formBase -Parent) "$($fi.FormName).xml"
	$formXmlFile = Join-Path (Join-Path $formBase "Ext") "Form.xml"
	$moduleBslFile = Join-Path (Join-Path (Join-Path $formBase "Ext") "Form") "Module.bsl"
	$ctx = "$($fi.TypeName).$($fi.ObjName).Form.$($fi.FormName)"

	# Validate form metadata XML
	if (Test-Path $formMetaFile) {
		try {
			$fmDoc = New-Object System.Xml.XmlDocument
			$fmDoc.PreserveWhitespace = $false
			$fmDoc.Load($formMetaFile)
			$fmNs = New-Object System.Xml.XmlNamespaceManager($fmDoc.NameTable)
			$fmNs.AddNamespace("md", "http://v8.1c.ru/8.3/MDClasses")

			$fmEl = $null
			foreach ($c in $fmDoc.DocumentElement.ChildNodes) {
				if ($c.NodeType -eq 'Element') { $fmEl = $c; break }
			}
			if ($fmEl) {
				$fmProps = $fmEl.SelectSingleNode("md:Properties", $fmNs)
				if ($fmProps) {
					$fmOb = $fmProps.SelectSingleNode("md:ObjectBelonging", $fmNs)
					$isBorrowed = $fmOb -and $fmOb.InnerText -eq "Adopted"
					if ($isBorrowed) {
						$fmExt = $fmProps.SelectSingleNode("md:ExtendedConfigurationObject", $fmNs)
						if (-not $fmExt -or $fmExt.InnerText -notmatch $guidPattern) {
							Report-Error "11. ${ctx}: invalid/missing ExtendedConfigurationObject"
							$check11Ok = $false
						}
					}
					$fmType = $fmProps.SelectSingleNode("md:FormType", $fmNs)
					if ($fmType -and $fmType.InnerText -ne "Managed") {
						Report-Error "11. ${ctx}: FormType must be 'Managed', got '$($fmType.InnerText)'"
						$check11Ok = $false
					}
				}
			}
		} catch {
			Report-Warn "11. ${ctx}: Cannot parse metadata: $($_.Exception.Message)"
		}
	}

	# Form.xml must exist
	if (-not (Test-Path $formXmlFile)) {
		Report-Error "11. ${ctx}: Ext/Form.xml missing"
		$check11Ok = $false
		continue
	}

	# Module.bsl should exist
	if (-not (Test-Path $moduleBslFile)) {
		Report-Warn "11. ${ctx}: Ext/Form/Module.bsl missing"
	}

	# Read Form.xml as raw text for BaseForm checks
	$formRawText = [System.IO.File]::ReadAllText($formXmlFile, [System.Text.Encoding]::UTF8)
	$script:formsWithText += @{
		RawText = $formRawText; Context = $ctx; OwnerKey = "$($fi.TypeName).$($fi.ObjName)"
	}

	if ($formRawText -match '<BaseForm') {
		# Check BaseForm has version
		if ($formRawText -notmatch '<BaseForm[^>]+version=') {
			Report-Warn "11. ${ctx}: <BaseForm> missing version attribute"
		}

		$script:borrowedFormsWithTree += @{
			Path = $formXmlFile; RawText = $formRawText; Context = $ctx
		}
	}
}

if ($formCount -eq 0) {
	Report-OK "11. Borrowed forms: none found"
} elseif ($check11Ok) {
	$bfCount = $script:borrowedFormsWithTree.Count
	Report-OK "11. Borrowed forms: $formCount validated ($bfCount with BaseForm)"
}

if ($script:stopped) { & $finalize; exit 1 }

# --- Check 12: Form dependency references ---
$platformStyleItems = @{
	"TableHeaderBackColor"=$true; "AccentColor"=$true; "NormalTextFont"=$true
	"FormBackColor"=$true; "ToolTipBackColor"=$true; "BorderColor"=$true
	"FieldBackColor"=$true; "FieldTextColor"=$true; "ButtonBackColor"=$true
	"ButtonTextColor"=$true; "AlternateRowColor"=$true; "SpecialTextColor"=$true
	"TextFont"=$true; "ImportantColor"=$true; "FormTextColor"=$true
	"SmallTextFont"=$true; "ExtraLargeTextFont"=$true; "LargeTextFont"=$true
	"NormalTextColor"=$true; "GroupHeaderBackColor"=$true; "GroupHeaderFont"=$true
	"ErrorColor"=$true; "SuccessColor"=$true; "WarningColor"=$true
}
$check12Ok = $true
$depCheckCount = 0

foreach ($bf in $script:borrowedFormsWithTree) {
	$raw = $bf.RawText
	$ctx = $bf.Context
	$missingItems = @()

	# CommonPicture references
	$cpRefs = @{}
	foreach ($m in [regex]::Matches($raw, '<xr:Ref>CommonPicture\.(\w+)</xr:Ref>')) {
		$cpRefs[$m.Groups[1].Value] = $true
	}
	$cpIndex = $script:childObjectIndex["CommonPicture"]
	foreach ($cpName in $cpRefs.Keys) {
		$depCheckCount++
		if (-not $cpIndex -or -not $cpIndex.ContainsKey($cpName)) {
			$missingItems += "CommonPicture.${cpName}"
		}
	}

	# StyleItem references
	$siRefs = @{}
	foreach ($m in [regex]::Matches($raw, 'style:([A-Za-z\u0410-\u044F\u0401\u0451_][A-Za-z0-9\u0410-\u044F\u0401\u0451_]*)')) {
		$siRefs[$m.Groups[1].Value] = $true
	}
	$siIndex = $script:childObjectIndex["StyleItem"]
	foreach ($siName in $siRefs.Keys) {
		$depCheckCount++
		if ($platformStyleItems.ContainsKey($siName)) { continue }
		if (-not $siIndex -or -not $siIndex.ContainsKey($siName)) {
			$missingItems += "StyleItem.${siName}"
		}
	}

	# Enum DesignTimeRef references
	$enumRefs = @{}
	foreach ($m in [regex]::Matches($raw, 'xr:DesignTimeRef">Enum\.(\w+)\.EnumValue\.(\w+)')) {
		$eKey = "$($m.Groups[1].Value).$($m.Groups[2].Value)"
		$enumRefs[$eKey] = @{ Enum = $m.Groups[1].Value; Value = $m.Groups[2].Value }
	}
	$eIndex = $script:childObjectIndex["Enum"]
	foreach ($entry in $enumRefs.Values) {
		$depCheckCount++
		if (-not $eIndex -or -not $eIndex.ContainsKey($entry.Enum)) {
			$missingItems += "Enum.$($entry.Enum)"
		} elseif (-not $script:enumValuesIndex.ContainsKey($entry.Enum) -or -not $script:enumValuesIndex[$entry.Enum].ContainsKey($entry.Value)) {
			$missingItems += "Enum.$($entry.Enum).EnumValue.$($entry.Value)"
		}
	}

		# Корень путей формы — имя её основного реквизита: «Объект» только у формы объекта, у формы
	# списка «Список», у формы записи регистра «Запись». С зашитым «Объект» обе проверки ниже на
	# таких формах молча не срабатывали. Ищем сначала в <Attributes> самой формы, потом в <BaseForm>.
	$rootName = ""
	$rootMatch = [regex]::Match($raw, '(?s)<Attribute name="([^"]+)"[^>]*>(?:(?!</Attribute>).)*?<MainAttribute>true</MainAttribute>')
	if ($rootMatch.Success) { $rootName = $rootMatch.Groups[1].Value }

	# <AdditionalColumns table="Объект.X"> — доп. колонки табличной части, объявленные в самой форме.
	# Колонки есть, а самой ТЧ в расширении нет (ни заимствованной, ни собственной) → платформа
	# отвергает загрузку: «Неверный путь к данным» плюс «Колонки не могут быть добавлены к реквизиту».
	# Только своя часть формы: <BaseForm> — снимок исходной формы, его платформа разрешает по конфигурации.
	$acTables = @{}
	if ($rootName) {
		$rootPat = [regex]::Escape($rootName)
		$ownPart = ($raw -split '<BaseForm', 2)[0]
		foreach ($m in [regex]::Matches($ownPart, "<AdditionalColumns table=`"${rootPat}\.(\w+)`"")) {
			$acTables[$m.Groups[1].Value] = $true
		}
	}
	# Соседние проверки этого блока эвристичны (имя стиля добывается регуляркой), поэтому там
	# предупреждение. Здесь сигнал точный — имя ТЧ берётся из атрибута, — а последствие жёсткое,
	# поэтому ошибка. ТЧ ищется у объекта основного реквизита; типа у реквизита нет — у владельца формы;
	# тип не объект метаданных (таблица значений, список) — ТЧ объекта тут ни при чём. Объекта основного
	# реквизита в расширении нет — об этом скажет проверка 14, здесь бы вышла ложная подсказка про ТЧ.
	$acTarget = Get-MainAttributeTarget $rootMatch.Value
	$ownerKey = $null
	if ($acTarget) {
		if ($script:extObjIndex.ContainsKey($acTarget.Key)) { $ownerKey = $acTarget.Key }
	} elseif ($rootMatch.Value -notmatch '<v8:Type') {
		$ownerKey = ($ctx -split '\.Form\.')[0]
	}
	if ($acTables.Count -gt 0 -and $ownerKey) {
		$ownerEntry = $script:extObjIndex[$ownerKey]
		foreach ($tblName in $acTables.Keys) {
			$depCheckCount++
			if (-not $ownerEntry -or -not $ownerEntry.TSColumns.ContainsKey($tblName)) {
				Report-Error "12. ${ctx}: <AdditionalColumns table=`"${rootName}.${tblName}`"> — TabularSection.${tblName} is neither borrowed nor added in extension"
				$check12Ok = $false
			}
		}
	}

	foreach ($mi in $missingItems) {
		Report-Warn "12. ${ctx}: references ${mi} not borrowed in extension"
		$check12Ok = $false
	}
}

if ($script:borrowedFormsWithTree.Count -eq 0) {
	Report-OK "12. Form dependencies: no borrowed forms with tree"
} elseif ($check12Ok) {
	Report-OK "12. Form dependencies: $depCheckCount references checked"
}

if ($script:stopped) { & $finalize; exit 1 }

# --- Check 13: TypeLink with human-readable paths ---
$check13Ok = $true
$typeLinkCount = 0

foreach ($bf in $script:borrowedFormsWithTree) {
	$raw = $bf.RawText
	$ctx = $bf.Context
	$matches = [regex]::Matches($raw, '<TypeLink>\s*<xr:DataPath>Items\.[^<]*</xr:DataPath>')
	if ($matches.Count -gt 0) {
		$typeLinkCount += $matches.Count
		Report-Warn "13. ${ctx}: $($matches.Count) TypeLink(s) with human-readable Items.* DataPath (should be stripped)"
		$check13Ok = $false
	}
}

if ($script:borrowedFormsWithTree.Count -eq 0) {
	Report-OK "13. TypeLink: no borrowed forms with tree"
} elseif ($check13Ok) {
	Report-OK "13. TypeLink: clean"
}

# Каталог конфигурации-источника из -ConfigPath (каталог или путь к Configuration.xml) для
# проверки 18; есть ли там Configuration.xml, она решает и сообщает сама.
function Get-SourceConfigRoot {
	$root = $ConfigPath
	if (-not [System.IO.Path]::IsPathRooted($root)) { $root = Join-Path (Get-Location).Path $root }
	if ((Test-Path $root) -and -not (Test-Path $root -PathType Container)) { $root = Split-Path $root -Parent }
	return $root
}

# --- Check 14: пути <Основной реквизит>.* форм расширения против объекта в расширении ---
# Платформа разрешает путь любой формы расширения — и заимствованной, и собственной — по объекту
# таким, каким он описан в расширении: заимствованные и собственные реквизиты, ТЧ и их колонки
# (индекс $script:extObjIndex, проверка 10). Незаимствованный реквизит источника она не видит даже
# на заимствованной форме, где он был в исходной: «Неверный путь к данным». Имена — без учёта
# регистра. Стандартные реквизиты — по типу основного реквизита ($script:mainAttrStandardFields).
# После ссылочного реквизита или колонки путь продолжается по целевому объекту (Get-RefTailError).
if (-not $script:stopped -and $script:formsWithText.Count -gt 0) {
	$check14Ok = $true
	$pathCheckCount = 0

	foreach ($fw in $script:formsWithText) {
		$raw = $fw.RawText
		$ctx = $fw.Context
		# Только своя часть формы: <BaseForm> — снимок исходной формы, его платформа разрешает по
		# конфигурации, а не по расширению.
		$own = ($raw -split '<BaseForm', 2)[0]
		# Корень путей — имя основного реквизита формы (см. проверку 12). Нет его в <Attributes>
		# формы — путей с корнем не бывает, проверять нечего.
		$rootMatch14 = [regex]::Match($own, '(?s)<Attribute name="([^"]+)"[^>]*>(?:(?!</Attribute>).)*?<MainAttribute>true</MainAttribute>')
		if (-not $rootMatch14.Success) { continue }
		$rootName = $rootMatch14.Groups[1].Value
		# Тип не объект метаданных — пути не по составу объекта. Так и у динамического списка: его поля —
		# результат запроса, туда входят стандартные поля списка (Ref, Date, DefaultPicture) и псевдонимы
		# (корпусная проверка: 3383 таких сегмента на 1094 формах списка УТ).
		$target = Get-MainAttributeTarget $rootMatch14.Value
		if (-not $target) { continue }
		$ownerKey = $target.Key
		$ownerEntry = $script:extObjIndex[$ownerKey]
		if (-not $ownerEntry) {
			# Объект в составе расширения есть, но его файл не прочитан — об этом уже сказала проверка 9.
			if ($script:extObjListed.ContainsKey($ownerKey)) { continue }
			# Объекта основного реквизита в расширении нет — тип не разрешается, и платформа не читает
			# форму целиком: «Исключение XDTO произошло при чтении файла». Это ошибка типа, а не путей,
			# поэтому она не зависит от того, замерен ли набор стандартных реквизитов этого типа (ниже).
			Report-Error "14. ${ctx}: основной реквизит '${rootName}' типа $($target.TypeName) — объекта $ownerKey в расширении нет (заимствуйте его)"
			$check14Ok = $false
			continue
		}
		$stdFields = $script:mainAttrStandardFields[$target.Category]
		if ($null -eq $stdFields) { continue }

		# Колонки ТЧ — из описания в расширении плюс объявленные в самой форме через
		# <Columns>/<AdditionalColumns table="Объект.X">. Копия, чтобы не дописывать в индекс.
		$tsColumns = New-Object System.Collections.Hashtable ([StringComparer]::OrdinalIgnoreCase)
		foreach ($tsName in $ownerEntry.TSColumns.Keys) {
			$tsColumns[$tsName] = New-Object System.Collections.Hashtable ($ownerEntry.TSColumns[$tsName], [StringComparer]::OrdinalIgnoreCase)
		}
		$rootPat14 = [regex]::Escape($rootName)
		foreach ($acm in [regex]::Matches($own, "(?s)<AdditionalColumns table=`"${rootPat14}\.(\w+)`">(.*?)</AdditionalColumns>")) {
			$tbl = $acm.Groups[1].Value
			if (-not $tsColumns.ContainsKey($tbl)) { $tsColumns[$tbl] = New-Object System.Collections.Hashtable ([StringComparer]::OrdinalIgnoreCase) }
			foreach ($cm in [regex]::Matches($acm.Groups[2].Value, '<Column name="(\w+)"')) {
				if (-not $tsColumns[$tbl].ContainsKey($cm.Groups[1].Value)) { $tsColumns[$tbl][$cm.Groups[1].Value] = @() }
			}
		}

		$badPaths = @{}
		foreach ($m in [regex]::Matches($own, "<(?:\w+:)?\w*DataPath[^>]*>${rootPat14}\.([^<]+)</(?:\w+:)?\w*DataPath>")) {
			# Индекс строки ТЧ (Объект.Товары[0].Цена) к имени не относится
			$segments = @(($m.Groups[1].Value -split '\.') | ForEach-Object { $_ -replace '\[.*$', '' })
			$seg0 = $segments[0]
			$pathCheckCount++
			if ($stdFields.ContainsKey($seg0)) {
				# Стандартная ТЧ видов субконто плана счетов видна, только если в описании объекта в расширении
				# заданы свойства ExtDimensionTypes и MaxExtDimensionCount: без любого из них — «Неверный путь к
				# данным» (замер 8.3.24). ПВХ видов субконто ещё должен быть заимствован — иначе «Неизвестный объект
				# метаданных», это не про пути.
				if ($target.Category -eq 'ChartOfAccountsObject' -and $seg0 -in @('ExtDimensionTypes','ВидыСубконто') -and -not $ownerEntry.ExtDimTypes) {
					$badPaths["${rootName}.${seg0}"] = "у ${ownerKey} в расширении не заданы свойства ExtDimensionTypes и MaxExtDimensionCount — стандартная ТЧ видов субконто форме не видна (перенесите их и заимствуйте ПВХ видов субконто)"
					continue
				}
				if ($segments.Count -ge 2) {
					$targetParts = $ownerKey -split '\.', 2
					$stdTypes = Get-StdRefTypes $targetParts[0] $targetParts[1] $seg0
					if ($stdTypes) { Add-RefTailBadPath $badPaths $rootName $segments $stdTypes 1 }
				}
				continue
			}
			if (-not $ownerEntry.Names.ContainsKey($seg0)) {
				$badPaths["${rootName}.${seg0}"] = "у ${ownerKey} в расширении нет такого реквизита или табличной части (незаимствованный реквизит источника форме расширения не виден)"
				continue
			}
			if ($segments.Count -lt 2) { continue }
			if (-not $tsColumns.ContainsKey($seg0)) {
				Add-RefTailBadPath $badPaths $rootName $segments $ownerEntry.Names[$seg0] 1
				continue
			}
			$seg1 = $segments[1]
			if ($script:standardObjectFields -contains $seg1) { continue }
			# Итог колонки — псевдополе платформы: Total<Колонка> при живой колонке законен
			if ($seg1 -like "Total*" -and $tsColumns[$seg0].ContainsKey($seg1.Substring(5))) { continue }
			if (-not $tsColumns[$seg0].ContainsKey($seg1)) {
				$badPaths["${rootName}.${seg0}.${seg1}"] = "у табличной части ${seg0} в расширении нет колонки ${seg1}, и <Columns> формы её не объявляет"
				continue
			}
			# Дальше колонки — по её типу (Объект.Товары.Номенклатура.Артикул)
			if ($segments.Count -gt 2) {
				Add-RefTailBadPath $badPaths $rootName $segments $tsColumns[$seg0][$seg1] 2
			}
		}
		foreach ($bad in ($badPaths.Keys | Sort-Object)) {
			Report-Error "14. ${ctx}: путь '${bad}' — $($badPaths[$bad])"
			$check14Ok = $false
		}
	}

	if ($check14Ok) {
		Report-OK "14. Form object paths: $pathCheckCount checked"
	}
}

# --- Check 15: основные роли расширения не дают прав на заимствованные объекты ---
# Платформа: «Назначение прав доступа на заимствованные объекты основными ролями в
# расширениях недопустимо». Роль вне <DefaultRoles> так делать вправе — проверяем только
# основные. Ловится статически, а по симптому (отказ загрузки) причина не читается.
$defaultRoleNodes = @($cfgNode.SelectNodes("md:Properties/md:DefaultRoles/xr:Item", $ns))
if ($defaultRoleNodes.Count -gt 0) {
	$adoptedCache = @{}

	function Test-ObjectAdopted {
		param([string]$typeName, [string]$objName)
		$key = "$typeName.$objName"
		if ($adoptedCache.ContainsKey($key)) { return $adoptedCache[$key] }
		$adoptedCache[$key] = $false
		if ($childTypeDirMap.ContainsKey($typeName)) {
			$objPath = Join-Path (Join-Path $configDir $childTypeDirMap[$typeName]) "$objName.xml"
			if (Test-Path $objPath) {
				try {
					$objDoc = New-Object System.Xml.XmlDocument
					$objDoc.Load($objPath)
					$objNs = New-Object System.Xml.XmlNamespaceManager($objDoc.NameTable)
					$objNs.AddNamespace("md", "http://v8.1c.ru/8.3/MDClasses")
					$ob = $objDoc.SelectSingleNode("/md:MetaDataObject/md:$typeName/md:Properties/md:ObjectBelonging", $objNs)
					if ($ob -and $ob.InnerText -eq "Adopted") { $adoptedCache[$key] = $true }
				} catch {}
			}
		}
		return $adoptedCache[$key]
	}

	$check15Ok = $true
	$check15Count = 0
	foreach ($rn in $defaultRoleNodes) {
		$roleRef = $rn.InnerText
		if ($roleRef -notmatch '^Role\.(.+)$') { continue }
		$defRoleName = $Matches[1]
		$rightsPath = Join-Path (Join-Path (Join-Path $configDir "Roles") $defRoleName) "Ext\Rights.xml"
		if (-not (Test-Path $rightsPath)) { continue }
		try {
			$rDoc = New-Object System.Xml.XmlDocument
			$rDoc.Load($rightsPath)
		} catch {
			continue
		}
		$rNs = New-Object System.Xml.XmlNamespaceManager($rDoc.NameTable)
		$rNs.AddNamespace("r", "http://v8.1c.ru/8.2/roles")
		foreach ($nameNode in $rDoc.SelectNodes("/r:Rights/r:object/r:name", $rNs)) {
			$fullName = $nameNode.InnerText
			$segs = $fullName.Split(".")
			# Configuration.* — права самого расширения, не объект; заимствования там нет.
			if ($segs.Count -lt 2 -or $segs[0] -eq "Configuration") { continue }
			$check15Count++
			if (Test-ObjectAdopted $segs[0] $segs[1]) {
				Report-Error ("15. Роль '$defRoleName' входит в DefaultRoles и даёт права на заимствованный $($segs[0]).$($segs[1]) " +
					"($fullName): платформа это запрещает. Вынесите такие права в отдельную роль вне DefaultRoles.")
				$check15Ok = $false
			}
		}
	}
	if ($check15Ok -and $check15Count -gt 0) {
		Report-OK "15. Основные роли: прав на заимствованные объекты нет ($check15Count checked)"
	}
}

if ($script:stopped) { & $finalize; exit 1 }

# --- Check 16: модуль заимствованного объекта и пометка расширенного свойства ---
# Свойство <xr:PropertyState> появилось в формате 2.19 (8.3.26); ниже платформа его молча
# выбрасывает, поэтому там проверять нечего. С 2.19 состояние обязано соответствовать факту:
# есть файл модуля — есть пометка, и наоборот. Перекос платформа принимает (проверено на стенде),
# но выгрузка Конфигуратора так не выглядит — отсюда предупреждение, а не ошибка.
if ($versionRank -ge 219 -and $childObjNode) {
	$stateIssues = @()
	$stateChecked = 0
	foreach ($child in $childObjNode.ChildNodes) {
		if ($child.NodeType -ne 'Element') { continue }
		$typeName = $child.LocalName
		if (-not $moduleKindsByType.ContainsKey($typeName)) { continue }
		if (-not $childTypeDirMap.ContainsKey($typeName)) { continue }
		$stateObjName = $child.InnerText.Trim()
		if (-not $stateObjName) { continue }
		$typeDir = Join-Path $configDir $childTypeDirMap[$typeName]
		$objFile = Join-Path $typeDir "$stateObjName.xml"
		if (-not (Test-Path $objFile)) { continue }
		$objText = [System.IO.File]::ReadAllText($objFile, [System.Text.Encoding]::UTF8)
		if ($objText -notmatch '<ObjectBelonging>Adopted</ObjectBelonging>') { continue }

		foreach ($kind in $moduleKindsByType[$typeName]) {
			$stateChecked++
			$hasFile = Test-Path (Join-Path (Join-Path (Join-Path $typeDir $stateObjName) "Ext") "$kind.bsl")
			$hasFlag = $objText -match "<xr:Property>$kind</xr:Property>"
			if ($hasFile -and -not $hasFlag) {
				$stateIssues += "$typeName.$stateObjName — есть $kind.bsl, но нет <xr:PropertyState> для $kind"
			} elseif ($hasFlag -and -not $hasFile) {
				$stateIssues += "$typeName.$stateObjName — есть <xr:PropertyState> для $kind, но нет $kind.bsl"
			}
		}
	}

	if ($stateChecked -gt 0) {
		if ($stateIssues.Count -eq 0) {
			Report-OK "16. Модули заимствованных объектов: пометки расширенных свойств согласованы ($stateChecked)"
		} else {
			foreach ($issue in $stateIssues) { Report-Warn "16. $issue" }
		}
	}
}

# --- Check 17: версия формата согласована внутри объектов расширения; сверка с Configuration.xml ---
# Дескриптор объекта и его штампованные тела X/Ext/*.xml, дескриптор формы/макета и его тело (и
# Configuration.xml с его Ext/*.xml) платформа загружает только в одной версии формата: «Версия формата
# загружаемого файла … отличается от версии формата ранее загруженных файлов». Объект целиком в другой
# версии, чем расширение, загружается — это лишь неоднородность выгрузки (типично после мержа веток,
# выгруженных разными платформами), поэтому такое расхождение только предупреждение.
if ($version) {
	# Каждый элемент — пара: дескриптор и его версия, известная заранее (у Configuration.xml — своя).
	$verDescriptors = @($resolvedPath)
	if ($childObjNode) {
		foreach ($child in $childObjNode.ChildNodes) {
			if ($child.NodeType -ne 'Element') { continue }
			if (-not $childTypeDirMap.ContainsKey($child.LocalName)) { continue }
			$verObjName = $child.InnerText.Trim()
			if (-not $verObjName) { continue }
			$verTypeDir = Join-Path $configDir $childTypeDirMap[$child.LocalName]
			$verObjFile = Join-Path $verTypeDir "$verObjName.xml"
			if (-not (Test-Path $verObjFile)) { continue }
			$verDescriptors += $verObjFile
			foreach ($sub in @("Forms","Templates")) {
				$subDir = Join-Path (Join-Path $verTypeDir $verObjName) $sub
				if (-not (Test-Path $subDir -PathType Container)) { continue }
				$names = @(Get-ChildItem $subDir -Filter "*.xml" -File | ForEach-Object { $_.Name })
				[Array]::Sort($names, [StringComparer]::Ordinal)
				foreach ($n in $names) { $verDescriptors += (Join-Path $subDir $n) }
			}
		}
	}
	$verRel = { param($p) $p.Substring($configDir.Length).TrimStart('\', '/') -replace '\\', '/' }
	$verErrors = 0
	$verBodiesOk = 0
	$verOff = @()
	foreach ($desc in $verDescriptors) {
		if ($script:stopped) { break }
		$isRoot = ($desc -eq $resolvedPath)
		$descVer = if ($isRoot) { $version } else { Get-RootVersion $desc }
		if (-not $descVer) { continue }
		if (-not $isRoot -and $descVer -ne $version) { $verOff += "$(& $verRel $desc) $descVer" }
		# Тела Configuration.xml лежат в <корень>/Ext, тела объекта X.xml — в X/Ext.
		$extDir = if ($isRoot) { Join-Path $configDir "Ext" } else { Join-Path (Join-Path (Split-Path $desc) ([System.IO.Path]::GetFileNameWithoutExtension($desc))) "Ext" }
		if (-not (Test-Path $extDir -PathType Container)) { continue }
		$bodyNames = @(Get-ChildItem $extDir -Filter "*.xml" -File | ForEach-Object { $_.Name })
		[Array]::Sort($bodyNames, [StringComparer]::Ordinal)
		foreach ($bn in $bodyNames) {
			$body = Join-Path $extDir $bn
			$bodyVer = Get-RootVersion $body
			if (-not $bodyVer) { continue }
			# У заимствованной формы второй штамп — <BaseForm version=…> внутри тела; платформа сверяет
			# с дескриптором и его.
			if ($bn -ceq "Form.xml") {
				$bodyText = [System.IO.File]::ReadAllText($body, [System.Text.Encoding]::UTF8)
				$bfm = [regex]::Match($bodyText, '<BaseForm\s[^>]*?version="([^"]*)"')
				if ($bfm.Success -and $bfm.Groups[1].Value -ne $descVer) {
					$verErrors++
					Report-Error "17. $(& $verRel $body) <BaseForm> is stamped $($bfm.Groups[1].Value), its descriptor $(& $verRel $desc) $descVer — the platform refuses to load parts of one object in different formats"
					if ($script:stopped) { break }
				}
			}
			if ($bodyVer -eq $descVer) { $verBodiesOk++; continue }
			$verErrors++
			Report-Error "17. $(& $verRel $body) is stamped $bodyVer, its descriptor $(& $verRel $desc) $descVer — the platform refuses to load parts of one object in different formats"
			if ($script:stopped) { break }
		}
	}
	if ($verOff.Count -gt 0) {
		$shown = ($verOff | Select-Object -First 5) -join ", "
		if ($verOff.Count -gt 5) { $shown += ", … (+$($verOff.Count - 5))" }
		Report-Warn "17. Format version differs from the extension ($version): $shown — the platform loads it, but the dump is no longer uniform (typical after merging branches dumped by different platforms)"
	} elseif ($verErrors -eq 0 -and $verBodiesOk -gt 0) {
		Report-OK "17. Format version: $verBodiesOk stamped part(s) agree with their descriptors and the extension"
	}
}

# --- Check 18: заимствованные объекты и основной язык против конфигурации-источника ---
# ОбъектРасширяемойКонфигурации контролируется у самого объекта и у каждого заимствованного
# подобъекта (реквизит, ТЧ, колонка ТЧ, форма — замер 8.3.24), ОсновнойЯзык — у расширения.
# Расхождение платформа принимает при загрузке, а применять расширение отказывается, и по
# сообщению не видно, откуда взялся чужой UUID. Нулевой UUID (cfe-init без -ConfigPath) не
# совпадёт ни с чем — его видно и без источника. Собственный подобъект с именем незаимствованного
# подобъекта источника платформа тоже загружает, а базу не обновляет.

# UUID, по которому подобъект связан с основной конфигурацией: в расширении —
# ExtendedConfigurationObject (у собственных подобъектов его нет), в источнике — атрибут uuid.
function Get-MdIdValue {
	param($el, [bool]$fromExtension)
	if ($fromExtension) {
		$n = $el.SelectSingleNode("*[local-name()='Properties']/*[local-name()='ExtendedConfigurationObject']")
		if ($n) { return $n.InnerText.Trim() }
		return $null
	}
	return $el.GetAttribute("uuid")
}

# Подобъекты, у которых в ChildObjects владельца только имя, а описание — в отдельном файле
# <каталог владельца>/<Имя владельца>/<Каталог>/<Имя>.xml.
$nestedFileDirs = @{ "Form"="Forms"; "Template"="Templates"; "Subsystem"="Subsystems"; "Recalculation"="Recalculations" }

# Объект или подобъект из отдельного файла: сам файл и всё, что под ним. $false — файла нет или он
# не читается.
function Add-MdIdFile {
	param($idx, [string]$objFile, [string]$key, [bool]$fromExtension)
	if (-not (Test-Path -LiteralPath $objFile)) { return $false }
	try {
		$doc = New-Object System.Xml.XmlDocument
		$doc.Load($objFile)
	} catch { return $false }
	$objEl = $null
	foreach ($c in $doc.DocumentElement.ChildNodes) {
		if ($c.NodeType -eq 'Element') { $objEl = $c; break }
	}
	if (-not $objEl) { return $false }
	$v = Get-MdIdValue $objEl $fromExtension
	if ($v) { $idx[$key] = $v }
	$ownDir = Join-Path (Split-Path $objFile -Parent) ([System.IO.Path]::GetFileNameWithoutExtension($objFile))
	Add-MdIdEntries $idx $objEl $key $fromExtension $ownDir
	return $true
}

# Подобъекты с собственными свойствами (реквизиты, ТЧ и их колонки, значения перечисления, команды
# и т.п.) лежат в ChildObjects целиком — обходим их рекурсивно. Формы, макеты, вложенные подсистемы
# и перерасчёты там — только имя: их UUID в отдельном файле под каталогом владельца.
function Add-MdIdEntries {
	param($idx, $el, [string]$prefix, [bool]$fromExtension, [string]$ownDir)
	$co = $el.SelectSingleNode("*[local-name()='ChildObjects']")
	if (-not $co) { return }
	foreach ($sub in $co.ChildNodes) {
		if ($sub.NodeType -ne 'Element') { continue }
		$nameNode = $sub.SelectSingleNode("*[local-name()='Properties']/*[local-name()='Name']")
		if ($nameNode) {
			$key = "$prefix.$($sub.LocalName).$($nameNode.InnerText.Trim())"
			$v = Get-MdIdValue $sub $fromExtension
			if ($v) { $idx[$key] = $v }
			Add-MdIdEntries $idx $sub $key $fromExtension ""
		} elseif ($ownDir -and $nestedFileDirs.ContainsKey($sub.LocalName) -and $sub.InnerText.Trim()) {
			$subName = $sub.InnerText.Trim()
			$subFile = Join-Path (Join-Path $ownDir $nestedFileDirs[$sub.LocalName]) "$subName.xml"
			Add-MdIdFile $idx $subFile "$prefix.$($sub.LocalName).$subName" $fromExtension | Out-Null
		}
	}
}

# Индекс «путь подобъекта → UUID связи» по файлу объекта; $null — файла нет или он не читается.
function Get-MdIdIndex {
	param([string]$typeDir, [string]$typeName, [string]$objName, [bool]$fromExtension)
	# Ключи — Ordinal: имя заимствованного подобъекта платформа сверяет С УЧЁТОМ регистра (контролируемое
	# свойство «Имя», замер 8.3.24), хотя в коде 1С имена регистронезависимы. [ordered]@{} так не умеет.
	$idx = New-Object System.Collections.Specialized.OrderedDictionary ([StringComparer]::Ordinal)
	if (-not (Add-MdIdFile $idx (Join-Path $typeDir "$objName.xml") "$typeName.$objName" $fromExtension)) { return $null }
	return $idx
}

# Собственные подобъекты заимствованного объекта, одноимённые (без учёта регистра) с незаимствованным
# подобъектом источника того же вида на том же уровне: реквизит, ТЧ, колонка заимствованной ТЧ, значение
# перечисления, форма, команда, макет. Платформа расширение загружает, а базу не обновляет: «Уже существует объект с
# именем …» (замер 8.3.24, 8.3.27). Реквизит и ТЧ с одним именем друг другу не мешают. Совпадение с
# подобъектом, заимствованным в этом же расширении, — дубль имени, его платформа отвергает уже на загрузке.
function Get-OwnNameCollisions {
	param([string]$objFile, [string]$prefix, $extIdx, $srcIdx)
	$result = @()
	$doc = New-Object System.Xml.XmlDocument
	try { $doc.Load($objFile) } catch { return $result }
	$objEl = $null
	foreach ($c in $doc.DocumentElement.ChildNodes) {
		if ($c.NodeType -eq 'Element') { $objEl = $c; break }
	}
	$co = if ($objEl) { $objEl.SelectSingleNode("*[local-name()='ChildObjects']") } else { $null }
	if (-not $co) { return $result }
	$ownDir = Join-Path (Split-Path $objFile -Parent) ([System.IO.Path]::GetFileNameWithoutExtension($objFile))
	$keys = @()
	foreach ($sub in $co.ChildNodes) {
		if ($sub.NodeType -ne 'Element') { continue }
		if ($sub.LocalName -in @('Form','Template')) {
			# Собственная форма или макет — файл есть и в нём нет ExtendedConfigurationObject. Нет файла или
			# не читается — не судим (об отсутствии файла формы говорит проверка 10)
			$fName = $sub.InnerText.Trim()
			if (-not $fName) { continue }
			$fFile = Join-Path (Join-Path $ownDir $nestedFileDirs[$sub.LocalName]) "$fName.xml"
			if (-not (Test-Path -LiteralPath $fFile)) { continue }
			$fDoc = New-Object System.Xml.XmlDocument
			try { $fDoc.Load($fFile) } catch { continue }
			if ($fDoc.SelectSingleNode("//*[local-name()='Properties']/*[local-name()='ExtendedConfigurationObject']")) { continue }
			$keys += "$prefix.$($sub.LocalName).$fName"
			continue
		}
		if ($sub.LocalName -notin @('Attribute','TabularSection','EnumValue','Command')) { continue }
		$nameNode = $sub.SelectSingleNode("*[local-name()='Properties']/*[local-name()='Name']")
		if (-not $nameNode) { continue }
		$k = "$prefix.$($sub.LocalName).$($nameNode.InnerText.Trim())"
		$keys += $k
		if ($sub.LocalName -ne 'TabularSection' -or -not $extIdx.Contains($k)) { continue }
		foreach ($col in $sub.SelectNodes("*[local-name()='ChildObjects']/*[local-name()='Attribute']")) {
			$colName = $col.SelectSingleNode("*[local-name()='Properties']/*[local-name()='Name']")
			if ($colName) { $keys += "$k.Attribute.$($colName.InnerText.Trim())" }
		}
	}
	$srcCi = New-Object System.Collections.Hashtable ([StringComparer]::OrdinalIgnoreCase)
	foreach ($sk in $srcIdx.Keys) { $srcCi[$sk] = $sk }
	$extCi = New-Object System.Collections.Hashtable ([StringComparer]::OrdinalIgnoreCase)
	foreach ($ek in $extIdx.Keys) { $extCi[$ek] = $true }
	foreach ($k in $keys) {
		if ($extCi.ContainsKey($k)) { continue }
		if ($srcCi.ContainsKey($k)) { $result += @{ Own = $k; Src = $srcCi[$k] } }
	}
	return $result
}

if (-not $script:stopped -and $childObjNode) {
	$zeroGuid = "00000000-0000-0000-0000-000000000000"
	$srcRoot = $null
	$srcCfgDoc = $null
	if ($ConfigPath) {
		$srcRoot = Get-SourceConfigRoot
		$srcCfgFile = Join-Path $srcRoot "Configuration.xml"
		if (-not (Test-Path $srcCfgFile)) {
			Report-Warn "18. -ConfigPath '$ConfigPath': Configuration.xml не найден — сверка с конфигурацией-источником пропущена"
			$srcRoot = $null
		} else {
			try {
				$srcCfgDoc = New-Object System.Xml.XmlDocument
				$srcCfgDoc.Load($srcCfgFile)
			} catch {
				Report-Warn "18. -ConfigPath '$ConfigPath': Configuration.xml не читается — сверка с конфигурацией-источником пропущена"
				$srcRoot = $null
			}
		}
	}

	$check18Ok = $true
	$check18Count = 0

	if ($srcRoot) {
		$srcDefLangNode = $srcCfgDoc.SelectSingleNode("//*[local-name()='Configuration']/*[local-name()='Properties']/*[local-name()='DefaultLanguage']")
		$srcDefLang = if ($srcDefLangNode) { $srcDefLangNode.InnerText.Trim() } else { "" }
		$extDefLang = if ($defLang) { $defLang.Trim() } else { "" }
		if ($extDefLang -and $srcDefLang) {
			$check18Count++
			if ($extDefLang -cne $srcDefLang) {
				Report-Error "18. DefaultLanguage расширения `"$defLang`", а у конфигурации-источника `"$srcDefLang`" — платформа загрузит расширение, но не применит («ОсновнойЯзык не совпадает»)"
				$check18Ok = $false
			}
		}
	}

	foreach ($child in $childObjNode.ChildNodes) {
		if ($script:stopped) { break }
		if ($child.NodeType -ne 'Element') { continue }
		$typeName = $child.LocalName
		if (-not $childTypeDirMap.ContainsKey($typeName)) { continue }
		$objName18 = $child.InnerText.Trim()
		if (-not $objName18) { continue }
		$dirName = $childTypeDirMap[$typeName]
		$extIdx = Get-MdIdIndex (Join-Path $configDir $dirName) $typeName $objName18 $true
		if (-not $extIdx -or $extIdx.Count -eq 0) { continue }

		if (-not $srcRoot) {
			foreach ($key in $extIdx.Keys) {
				$check18Count++
				if ($extIdx[$key] -ceq $zeroGuid) {
					Report-Warn "18. ${key}: ExtendedConfigurationObject нулевой — платформа загрузит расширение, но не применит. Создайте расширение и заимствуйте объекты с -ConfigPath"
				}
			}
			continue
		}

		$srcIdx = Get-MdIdIndex (Join-Path $srcRoot $dirName) $typeName $objName18 $false
		if ($null -eq $srcIdx) {
			Report-Error "18. ${typeName}.${objName18}: заимствованного объекта нет в конфигурации-источнике ($dirName/$objName18.xml)"
			$check18Ok = $false
			continue
		}
		foreach ($key in $extIdx.Keys) {
			$check18Count++
			$extId = $extIdx[$key]
			if (-not $srcIdx.Contains($key)) {
				$caseTwin = $null
				foreach ($sk in $srcIdx.Keys) {
					if ([string]::Equals($sk, $key, [StringComparison]::OrdinalIgnoreCase)) { $caseTwin = $sk; break }
				}
				if ($caseTwin) {
					Report-Error "18. ${key}: в конфигурации-источнике имя в другом регистре ($caseTwin) — платформа загрузит расширение, но не применит («контролируемое свойство Имя не совпадает»)"
				} else {
					Report-Error "18. ${key}: заимствованного подобъекта нет в конфигурации-источнике"
				}
				$check18Ok = $false
			} elseif ($extId.ToLowerInvariant() -cne $srcIdx[$key].ToLowerInvariant()) {
				$what = if ($extId -ceq $zeroGuid) { "нулевой" } else { "$extId" }
				Report-Error "18. ${key}: ExtendedConfigurationObject $what, а UUID в конфигурации-источнике $($srcIdx[$key]) — платформа загрузит расширение, но не применит («ОбъектРасширяемойКонфигурации не совпадает»)"
				$check18Ok = $false
			}
			if ($script:stopped) { break }
		}
		if ($script:stopped) { break }
		# Там, где собственных подобъектов данных быть не может, о них уже сказала проверка 10 — остаются
		# формы, команды и макеты (их добавлять можно)
		$dataBanned = $script:ownChildRestricted[$typeName] -eq "Error"
		foreach ($nc in @(Get-OwnNameCollisions (Join-Path (Join-Path $configDir $dirName) "$objName18.xml") "$typeName.$objName18" $extIdx $srcIdx)) {
			if ($dataBanned -and ($nc.Own -split '\.')[2] -notin @('Form','Command','Template')) { continue }
			Report-Error "18. $($nc.Own): собственный подобъект, а в конфигурации-источнике есть незаимствованный подобъект с этим именем ($($nc.Src)) — платформа загрузит расширение, но базу не обновит («Уже существует объект с именем …»)"
			$check18Ok = $false
			if ($script:stopped) { break }
		}
	}

	if (-not $ConfigPath) {
		Out-Line "[INFO]  18. Заимствованные объекты и основной язык против конфигурации-источника не сверялись: не задан -ConfigPath"
	} elseif ($srcRoot -and $check18Ok -and $check18Count -gt 0) {
		Report-OK "18. Source config: $check18Count link(s) agree (DefaultLanguage, ExtendedConfigurationObject)"
	}
}

# --- Check 19: ссылки на объекты, которых нет в расширении ---
# Объект основной конфигурации виден расширению, только если он заимствован (замер 8.3.24/8.3.27):
# - ссылочный тип (реквизит, колонка, константа, измерение, параметр команды, реквизит формы):
#   ниже 8.3.25 — «Неизвестное имя типа», с 8.3.25 работает;
# - ссылка на объект (владельцы, движения, ввод на основании, журнал, состав подсистемы, план
#   счетов регистра, задача БП): ниже 8.3.25 — «Неизвестный объект метаданных», с 8.3.25 грузится,
#   но в рантайме связь пуста;
# - права роли на такой объект платформа выбрасывает;
# - тип определяемого типа, источник подписки, виды субконто плана счетов не грузятся нигде.
# Формы (значения, СКД) и макеты не проверяются — не замерено.
$script:refTypeKind = New-Object System.Collections.Hashtable ([StringComparer]::Ordinal)
foreach ($k in @("Catalog","Document","Enum","ChartOfCharacteristicTypes","ChartOfAccounts","ChartOfCalculationTypes","ExchangePlan","BusinessProcess","Task")) {
	foreach ($s in @("Ref","Object","Selection","List","Manager")) { $script:refTypeKind["$k$s"] = $k }
}
foreach ($k in @("InformationRegister","AccumulationRegister","AccountingRegister","CalculationRegister")) {
	foreach ($s in @("RecordSet","RecordKey","Record","Manager","Selection","List","RecordManager")) { $script:refTypeKind["$k$s"] = $k }
}
foreach ($k in @("DataProcessor","Report")) { $script:refTypeKind["${k}Object"] = $k; $script:refTypeKind["${k}Manager"] = $k }
$script:refTypeKind["ConstantValueManager"] = "Constant"; $script:refTypeKind["ConstantManager"] = "Constant"
$script:refTypeKind["DefinedType"] = "DefinedType"; $script:refTypeKind["Characteristic"] = "ChartOfCharacteristicTypes"
$script:refTypeKind["BusinessProcessRoutePointRef"] = "BusinessProcess"; $script:refTypeKind["DocumentJournalSelection"] = "DocumentJournal"

$refTypeRe = '<v8:(Type|TypeSet)>(?:\w+:)?(\w+)\.([^<.\s]+)</v8:\1>'
$refListRe = '(?s)<(Owners|RegisterRecords|BasedOn|RegisteredDocuments|Content)>(.*?)</\1>'
$refItemRe = '>(\w+)\.([^<.\s]+)</xr:Item>'
$refTagRe = '<(ChartOfAccounts|Task|ExtDimensionTypes)>(\w+)\.([^<.\s]+)</\1>'
$refRightsRe = '<object>\s*<name>(\w+)\.([^<.\s]+)'

# Файлы под каталогом: @(относительный путь через "/", полный путь); сначала файлы, потом
# подкаталоги, имена по Ordinal. Относительный путь собирается из имён, а не вырезается из полного:
# Resolve-Path оставляет короткие имена 8.3 (NSHIRO~1), а перечисление их разворачивает.
function Get-RelFiles {
	param([string]$dir, [string]$rel)
	$out = New-Object System.Collections.ArrayList
	$files = @([System.IO.Directory]::GetFiles($dir) | ForEach-Object { [System.IO.Path]::GetFileName($_) })
	[Array]::Sort($files, [StringComparer]::Ordinal)
	foreach ($n in $files) {
		$r = if ($rel) { "$rel/$n" } else { $n }
		[void]$out.Add(@($r, (Join-Path $dir $n)))
	}
	$dirs = @([System.IO.Directory]::GetDirectories($dir) | ForEach-Object { [System.IO.Path]::GetFileName($_) })
	[Array]::Sort($dirs, [StringComparer]::Ordinal)
	foreach ($d in $dirs) {
		$r = if ($rel) { "$rel/$d" } else { $d }
		foreach ($x in (Get-RelFiles (Join-Path $dir $d) $r)) { [void]$out.Add($x) }
	}
	return ,$out
}

if (-not $script:stopped -and $childObjNode) {
	$refSeen = @{}
	# $where — что ссылается (относительный путь файла), $prop — свойство, $kind.$name — цель
	$reportRef = {
		param([string]$where, [string]$prop, [string]$kind, [string]$name, [string]$level)
		if (-not $childTypeDirMap.ContainsKey($kind)) { return }
		$target = "$kind.$name"
		$script:check19Count++
		if ($script:extObjListed.ContainsKey($target)) { return }
		$key = "$where|$prop|$target"
		if ($refSeen.ContainsKey($key)) { return }
		$refSeen[$key] = $true
		$script:check19Ok = $false
		switch ($level) {
			"type" { Report-Warn "19. ${where}: $prop ссылается на $target, а его нет в расширении — на платформе ниже 8.3.25 не загрузится («Неизвестное имя типа»), с 8.3.25 можно. Заимствуйте $target" }
			"never" { Report-Error "19. ${where}: $prop ссылается на $target, а его нет в расширении — платформа расширение не загрузит. Заимствуйте $target" }
			"rights" { Report-Error "19. ${where}: права на $target, а его нет в расширении — платформа их выбросит. Заимствуйте $target" }
			default { Report-Error "19. ${where}: $prop ссылается на $target, а его нет в расширении — ниже 8.3.25 не загрузится («Неизвестный объект метаданных»), с 8.3.25 загрузится, но связь в рантайме будет пустой. Заимствуйте $target" }
		}
	}
	$script:check19Count = 0
	$script:check19Ok = $true
	$readText = { param([string]$f) try { return [System.IO.File]::ReadAllText($f, [System.Text.Encoding]::UTF8) } catch { return $null } }
	$scanTypes = {
		param([string]$text, [string]$where, [string]$prop, [string]$level)
		foreach ($m in [regex]::Matches($text, $refTypeRe)) {
			$k = $script:refTypeKind[$m.Groups[2].Value]
			if ($k) { & $reportRef $where $prop $k $m.Groups[3].Value $level }
			if ($script:stopped) { return }
		}
	}

	foreach ($child in $childObjNode.ChildNodes) {
		if ($script:stopped) { break }
		if ($child.NodeType -ne 'Element') { continue }
		$typeName = $child.LocalName
		$childName = $child.InnerText
		if ($typeName -eq "Language" -or -not $childTypeDirMap.ContainsKey($typeName)) { continue }
		$objDir = Join-Path $configDir $childTypeDirMap[$typeName]
		$objFile = Join-Path $objDir "$childName.xml"
		$text = & $readText $objFile
		if ($null -eq $text) { continue }
		$where = "$typeName.$childName"

		# Подсистема: состав — у неё и у вложенных подсистем
		$texts = @(,@($where, $text))
		if ($typeName -eq "Subsystem") {
			$subDir = Join-Path $objDir $childName
			if (Test-Path -LiteralPath $subDir) {
				foreach ($e in (Get-RelFiles $subDir "")) {
					$segs = $e[0].Split('/')
					if ($segs.Count -lt 2 -or $segs[-2] -ne "Subsystems" -or -not $e[0].EndsWith(".xml", [StringComparison]::OrdinalIgnoreCase)) { continue }
					$t = & $readText $e[1]
					if ($null -ne $t) { $texts += ,@("$where/$($e[0])", $t) }
				}
			}
		}
		foreach ($pair in $texts) {
			$w = $pair[0]; $t = $pair[1]
			$typeLevel = "type"
			$typeProp = "тип"
			if ($typeName -eq "DefinedType") { $typeLevel = "never"; $typeProp = "Type" }
			elseif ($typeName -eq "EventSubscription") { $typeLevel = "never"; $typeProp = "Source" }
			& $scanTypes $t $w $typeProp $typeLevel
			if ($script:stopped) { break }
			# Движения последовательности не замерены
			$lists = if ($typeName -eq "Sequence") { @() } else { [regex]::Matches($t, $refListRe) }
			foreach ($lm in $lists) {
				foreach ($im in [regex]::Matches($lm.Groups[2].Value, $refItemRe)) {
					& $reportRef $w $lm.Groups[1].Value $im.Groups[1].Value $im.Groups[2].Value "object"
					if ($script:stopped) { break }
				}
				if ($script:stopped) { break }
			}
			foreach ($tm in [regex]::Matches($t, $refTagRe)) {
				$lvl = "object"
				if ($tm.Groups[1].Value -eq "ExtDimensionTypes") { $lvl = "never" }
				& $reportRef $w $tm.Groups[1].Value $tm.Groups[2].Value $tm.Groups[3].Value $lvl
				if ($script:stopped) { break }
			}
		}
		if ($script:stopped) { break }

		# Формы объекта (и общая форма): типы реквизитов и параметров формы
		$formRoot = Join-Path $objDir $childName
		if (Test-Path -LiteralPath $formRoot) {
			foreach ($e in (Get-RelFiles $formRoot "")) {
				$segs = $e[0].Split('/')
				if ($segs.Count -lt 2 -or $segs[-1] -ne "Form.xml" -or $segs[-2] -ne "Ext") { continue }
				$t = & $readText $e[1]
				if ($null -eq $t) { continue }
				# Общая форма — сам объект (Ext/Form.xml), форма объекта — <Объект>/Forms/<Имя>
				$rel = $where
				if ($segs.Count -gt 2) { $rel = "$where/" + ($segs[0..($segs.Count - 3)] -join '/') }
				& $scanTypes $t $rel "тип" "type"
				if ($script:stopped) { break }
			}
		}
		if ($script:stopped) { break }

		if ($typeName -eq "Role") {
			$t = & $readText (Join-Path (Join-Path (Join-Path $objDir $childName) "Ext") "Rights.xml")
			if ($null -ne $t) {
				foreach ($rm in [regex]::Matches($t, $refRightsRe)) {
					& $reportRef $where "права" $rm.Groups[1].Value $rm.Groups[2].Value "rights"
					if ($script:stopped) { break }
				}
			}
		}
	}

	if ($script:check19Ok -and $script:check19Count -gt 0) {
		Report-OK "19. References: $($script:check19Count) reference(s) to objects, all present in the extension"
	}
}

# Built-in language keywords in both spellings. The platform accepts either one in any module
# (pairs taken from the platform string tables), so a module written in English is ordinary
# source, not a broken one: we must read both and emit the spelling we read.
function Get-BslKeywords {
	return @{
		ru = @{
			Async="Асинх"; Proc="Процедура"; EndProc="КонецПроцедуры"
			Func="Функция"; EndFunc="КонецФункции"; Val="Знач"
			Region="Область"; EndRegion="КонецОбласти"
			If="Если"; Then="Тогда"; ElsIf="ИначеЕсли"; Else="Иначе"; EndIf="КонецЕсли"
			# Platform spells the negation "Не"; we emit "НЕ" as this skill always has —
			# the language is case-insensitive, and the lower case would churn every snapshot.
			And="И"; Or="Или"; Not="НЕ"
			Insert="Вставка"; EndInsert="КонецВставки"; Delete="Удаление"; EndDelete="КонецУдаления"
			Before="Перед"; After="После"; Around="Вместо"; Control="ИзменениеИКонтроль"
			Proceed="ПродолжитьВызов"; Return="Возврат"
			# Not a keyword: name of the local the generated Instead-stub declares. Lives here so
			# that the language of emitted text is decided in exactly one place.
			ResultVar="Результат"
			Directives=@("НаКлиенте", "НаСервере", "НаСервереБезКонтекста", "НаКлиентеНаСервереБезКонтекста", "НаКлиентеНаСервере")
		}
		en = @{
			Async="Async"; Proc="Procedure"; EndProc="EndProcedure"
			Func="Function"; EndFunc="EndFunction"; Val="Val"
			Region="Region"; EndRegion="EndRegion"
			If="If"; Then="Then"; ElsIf="ElsIf"; Else="Else"; EndIf="EndIf"
			And="And"; Or="Or"; Not="Not"
			Insert="Insert"; EndInsert="EndInsert"; Delete="Delete"; EndDelete="EndDelete"
			Before="Before"; After="After"; Around="Around"; Control="ChangeAndValidate"
			Proceed="ProceedWithCall"; Return="Return"
			ResultVar="Result"
			Directives=@("AtClient", "AtServer", "AtServerNoContext", "AtClientAtServerNoContext", "AtClientAtServer")
		}
	}
}

# --- Breadcrumb: controlled methods (&ИзменениеИКонтроль) drift is not checked here ---
$extRootDir = Split-Path $resolvedPath -Parent
$ctrlKw = Get-BslKeywords
$ctrlRe = '(?im)^\s*&(?:' + $ctrlKw.ru.Control + '|' + $ctrlKw.en.Control + ')\('
$ctrlCount = 0
foreach ($bslFile in (Get-ChildItem -Path $extRootDir -Recurse -Filter *.bsl -File -ErrorAction SilentlyContinue)) {
	$txt = [System.IO.File]::ReadAllText($bslFile.FullName, [System.Text.Encoding]::UTF8)
	$ctrlCount += ([regex]::Matches($txt, $ctrlRe)).Count
}
if ($ctrlCount -gt 0) {
	Out-Line "[INFO]  Контролируемых методов (&ИзменениеИКонтроль): $ctrlCount — их актуальность здесь не проверяется. Сверьте: /cfe-patch-method -Check -ExtensionPath <ext> -ConfigPath <cf>"
}

# --- Final output ---
& $finalize

if ($script:errors -gt 0) {
	exit 1
}
exit 0
