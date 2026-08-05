# epf-init v1.3 — Init 1C external data processor scaffold
# Source: https://github.com/Nikolay-Shirokov/cc-1c-skills
param(
	[Parameter(Mandatory)]
	[string]$Name,

	[string]$Synonym = $Name,

	[string]$SrcDir = "src"
)

$ErrorActionPreference = "Stop"
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
[Console]::InputEncoding = [System.Text.Encoding]::UTF8

$uuid1 = [guid]::NewGuid().ToString()
$uuid2 = [guid]::NewGuid().ToString()
$uuid3 = [guid]::NewGuid().ToString()
$uuid4 = [guid]::NewGuid().ToString()

$xml = @"
<?xml version="1.0" encoding="UTF-8"?>
<MetaDataObject xmlns="http://v8.1c.ru/8.3/MDClasses" xmlns:app="http://v8.1c.ru/8.2/managed-application/core" xmlns:cfg="http://v8.1c.ru/8.1/data/enterprise/current-config" xmlns:cmi="http://v8.1c.ru/8.2/managed-application/cmi" xmlns:ent="http://v8.1c.ru/8.1/data/enterprise" xmlns:lf="http://v8.1c.ru/8.2/managed-application/logform" xmlns:style="http://v8.1c.ru/8.1/data/ui/style" xmlns:sys="http://v8.1c.ru/8.1/data/ui/fonts/system" xmlns:v8="http://v8.1c.ru/8.1/data/core" xmlns:v8ui="http://v8.1c.ru/8.1/data/ui" xmlns:web="http://v8.1c.ru/8.1/data/ui/colors/web" xmlns:win="http://v8.1c.ru/8.1/data/ui/colors/windows" xmlns:xen="http://v8.1c.ru/8.3/xcf/enums" xmlns:xpr="http://v8.1c.ru/8.3/xcf/predef" xmlns:xr="http://v8.1c.ru/8.3/xcf/readable" xmlns:xs="http://www.w3.org/2001/XMLSchema" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance" version="2.17">
	<ExternalDataProcessor uuid="$uuid1">
		<InternalInfo>
			<xr:ContainedObject>
				<xr:ClassId>c3831ec8-d8d5-4f93-8a22-f9bfae07327f</xr:ClassId>
				<xr:ObjectId>$uuid2</xr:ObjectId>
			</xr:ContainedObject>
			<xr:GeneratedType name="ExternalDataProcessorObject.$Name" category="Object">
				<xr:TypeId>$uuid3</xr:TypeId>
				<xr:ValueId>$uuid4</xr:ValueId>
			</xr:GeneratedType>
		</InternalInfo>
		<Properties>
			<Name>$Name</Name>
			<Synonym>
				<v8:item>
					<v8:lang>ru</v8:lang>
					<v8:content>$Synonym</v8:content>
				</v8:item>
			</Synonym>
			<Comment/>
			<DefaultForm/>
			<AuxiliaryForm/>
		</Properties>
		<ChildObjects/>
	</ExternalDataProcessor>
</MetaDataObject>
"@

$rootFile = Join-Path $SrcDir "$Name.xml"
$processorDir = Join-Path $SrcDir $Name

if (Test-Path $rootFile) {
	Write-Error "Файл уже существует: $rootFile"
	exit 1
}

if (-not (Test-Path $SrcDir)) {
	New-Item -ItemType Directory -Path $SrcDir -Force | Out-Null
}
$extDir = Join-Path $processorDir "Ext"
New-Item -ItemType Directory -Path $extDir -Force | Out-Null

$enc = New-Object System.Text.UTF8Encoding($true)
# Канон выгрузки Конфигуратора: CRLF в разделителях строк, без перевода в конце
# файла. Скелет собирается here-string'ами, а .ps1 хранится с LF — отсюда LF и
# смешанный EOL. Нормализация здесь безопасна: многострочных текстовых узлов в
# скелете нет. Модули .bsl и текстовые макеты через эту функцию НЕ пишутся.
function Write-XmlFile([string]$path, [string]$text, $encoding) {
	$t = ($text -replace "`r`n", "`n") -replace "`n", "`r`n"
	[System.IO.File]::WriteAllText($path, $t.TrimEnd("`r", "`n"), $encoding)
}

Write-XmlFile (Resolve-Path $SrcDir | Join-Path -ChildPath "$Name.xml") $xml $enc

# --- Модуль объекта ---

$moduleBsl = @"
#Область ОписаниеПеременных

#КонецОбласти

#Область ПрограммныйИнтерфейс

#КонецОбласти

#Область СлужебныеПроцедурыИФункции

#КонецОбласти
"@

$modulePath = Join-Path $extDir "ObjectModule.bsl"
# Модуль пишем в каноне платформы: CRLF в разделителях строк (корпус: 2643 CRLF,
# чисто-LF 0 из 3001). Хвостовой перевод НЕ навязываем — у платформы он
# неканоничен (1235 модулей с ним, 766 без). Шаблон берёт переводы строк из
# самого скрипта, а он в репозитории хранится с LF.
$moduleBsl = ($moduleBsl -replace "`r`n", "`n") -replace "`n", "`r`n"
[System.IO.File]::WriteAllText($modulePath, $moduleBsl, $enc)

Write-Host "[OK] Создана обработка: $rootFile"
Write-Host "     Каталог: $processorDir"
Write-Host "     Модуль:  $modulePath"
