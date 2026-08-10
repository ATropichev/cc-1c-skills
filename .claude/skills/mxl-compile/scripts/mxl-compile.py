#!/usr/bin/env python3
# mxl-compile v1.22 — Compile 1C spreadsheet from JSON (+write_xml_file/write_utf8_bom: общий эталон записи)
# Source: https://github.com/Nikolay-Shirokov/cc-1c-skills
import argparse
import hashlib
import json
import math
import os
import re
import sys

from lxml import etree

# Регистронезависимый ввод — паритет с PS1: в PowerShell имена параметров и [ValidateSet]
# регистр не различают, в argparse совпадение точное.
class CIDict(dict):
    # Ключи храним КАК ЕСТЬ: часть из них — имена объектов (табличные части, стандартные
    # реквизиты), они попадают в XML. Регистронезависим только поиск. Порядок вставки
    # сохраняется — от него зависит порядок эмиссии.
    def _actual(self, key):
        if not isinstance(key, str) or dict.__contains__(self, key):
            return key
        ci = self.__dict__.get('_ci')
        if ci is None or len(ci) != len(self):
            ci = {k.lower(): k for k in self if isinstance(k, str)}
            self.__dict__['_ci'] = ci
        return ci.get(key.lower(), key)

    def __getitem__(self, key):
        return dict.__getitem__(self, self._actual(key))

    def __contains__(self, key):
        return dict.__contains__(self, self._actual(key))

    def get(self, key, default=None):
        return dict.get(self, self._actual(key), default)

    def pop(self, key, *default):
        return dict.pop(self, self._actual(key), *default)

    def __setitem__(self, key, value):
        # запись по ключу, отличающемуся регистром, обновляет существующий, а не плодит дубль
        dict.__setitem__(self, self._actual(key), value)

def ci_json(obj):
    """Рекурсивно оборачивает разобранный JSON: словари → CIDict, списки обходятся."""
    if isinstance(obj, dict):
        return CIDict((k, ci_json(v)) for k, v in obj.items())
    if isinstance(obj, list):
        return [ci_json(v) for v in obj]
    return obj

def ci_parse_args(parser, argv=None):
    """parse_args по правилам PS: имена параметров и значения choices регистронезависимы."""
    argv = list(sys.argv[1:] if argv is None else argv)
    names = {s.lower(): s for a in parser._actions for s in a.option_strings}
    for i, tok in enumerate(argv):
        if tok.startswith('-') and tok.lower() in names:
            argv[i] = names[tok.lower()]
    # choices — зеркало [ValidateSet]; канонизируем ДО разбора, иначе argparse отвергнет регистр
    choice_map = {}
    for a in parser._actions:
        if a.choices:
            for s in a.option_strings:
                choice_map[s] = {str(c).lower(): c for c in a.choices}
    for i in range(len(argv) - 1):
        m = choice_map.get(argv[i])
        if m and argv[i + 1].lower() in m:
            argv[i + 1] = m[argv[i + 1].lower()]
    return parser.parse_args(argv)



# ============================================================
# Support guard (Ext/ParentConfigurations.bin) — see docs/1c-support-state-spec.md
# Blocks edits of vendor objects "на замке" / read-only configs. Trigger = bin
# present; reaction from .v8-project.json editingAllowedCheck (deny|warn|off,
# default deny). Never throws (except sys.exit on deny) — errors degrade to allow.
# ============================================================

def _sg_root_uuid(xml_path):
    if not os.path.isfile(xml_path):
        return None
    try:
        mx = etree.parse(xml_path).getroot()
        for child in mx:
            if isinstance(child.tag, str) and child.get("uuid"):
                return child.get("uuid")
    except Exception:
        return None
    return None


def _sg_is_external_root(xml_path):
    if not os.path.isfile(xml_path):
        return False
    try:
        mx = etree.parse(xml_path).getroot()
        for child in mx:
            if isinstance(child.tag, str):
                return child.tag.split("}")[-1] in ("ExternalDataProcessor", "ExternalReport")
    except Exception:
        return False
    return False

def _sg_find_v8project(start_dir):
    d = start_dir
    for _ in range(20):
        if not d:
            break
        pj = os.path.join(d, ".v8-project.json")
        if os.path.isfile(pj):
            return pj
        parent = os.path.dirname(d)
        if parent == d:
            break
        d = parent
    return None


def _sg_get_edit_mode(cfg_dir):
    try:
        pj = _sg_find_v8project(os.getcwd()) or _sg_find_v8project(cfg_dir)
        if not pj:
            return "deny"
        proj = json.loads(open(pj, encoding="utf-8-sig").read())
        cfg_full = os.path.normcase(os.path.abspath(cfg_dir)).rstrip("\\/")
        for db in proj.get("databases", []):
            src = db.get("configSrc")
            if src:
                src_full = os.path.normcase(os.path.abspath(src)).rstrip("\\/")
                if cfg_full == src_full or cfg_full.startswith(src_full + os.sep):
                    if db.get("editingAllowedCheck"):
                        return db["editingAllowedCheck"]
        if proj.get("editingAllowedCheck"):
            return proj["editingAllowedCheck"]
        return "deny"
    except Exception:
        return "deny"


def assert_edit_allowed(target_path, require):
    try:
        rp = os.path.abspath(target_path)
        # Autonomous external object (EPF/ERF): never part of a config on support (issue #39).
        if _sg_is_external_root(rp):
            return
        elem_uuid = _sg_root_uuid(rp)
        cfg_dir = None
        bin_path = None
        d = rp if os.path.isdir(rp) else os.path.dirname(rp)
        for _ in range(12):
            if not d:
                break
            if _sg_is_external_root(d + ".xml"):
                return
            if not elem_uuid:
                elem_uuid = _sg_root_uuid(d + ".xml")
            if not cfg_dir:
                cand = os.path.join(d, "Ext", "ParentConfigurations.bin")
                if os.path.exists(cand) or os.path.exists(os.path.join(d, "Configuration.xml")):
                    cfg_dir = d
                    bin_path = cand
            if elem_uuid and cfg_dir:
                break
            parent = os.path.dirname(d)
            if parent == d:
                break
            d = parent
        if not elem_uuid and cfg_dir:
            elem_uuid = _sg_root_uuid(os.path.join(cfg_dir, "Configuration.xml"))
        if not bin_path or not os.path.exists(bin_path):
            return
        data = open(bin_path, "rb").read()
        if len(data) <= 32:
            return
        if data[:3] == b"\xef\xbb\xbf":
            data = data[3:]
        text = data.decode("utf-8", "replace")
        h = re.match(r"\{6,(\d+),(\d+),", text)
        if not h:
            return
        g = int(h.group(1))
        k = int(h.group(2))
        if k == 0:
            return
        best = None
        if elem_uuid:
            for m in re.finditer(r"([0-2]),0," + re.escape(elem_uuid.lower()), text):
                f1 = int(m.group(1))
                if best is None or f1 < best:
                    best = f1
        blocked = False
        code = ""
        reason = ""
        if g == 1:
            blocked = True
            code = "capability-off"
            reason = "возможность изменения конфигурации выключена (вся конфигурация read-only)"
        elif require == "removed":
            if best is not None and best != 2:
                blocked = True
                code = "not-removed"
                reason = "объект не снят с поддержки — удаление сломает обновления"
        else:
            if best is not None and best == 0:
                blocked = True
                code = "locked"
                reason = "объект на замке — редактирование сломает обновления"
        if not blocked:
            return
        mode = _sg_get_edit_mode(cfg_dir)
        if mode == "off":
            return
        if mode == "warn":
            sys.stderr.write(f"[support-guard] ПРЕДУПРЕЖДЕНИЕ: {reason}. Цель: {rp}\n")
            return
        head = "[support-guard] Редактирование отклонено: это объект типовой конфигурации на поддержке поставщика, прямое редактирование молча сломает будущие обновления."
        cfe = "Рекомендуемый путь: внести доработку в расширение (навыки cfe-borrow / cfe-patch-method) — состояние поддержки менять не нужно, обновления вендора сохраняются."
        off_note = "Снять проверку для этой базы: editingAllowedCheck = warn|off в .v8-project.json."
        if code == "capability-off":
            state = f"Состояние: у всей конфигурации выключена возможность изменения (режим read-only «из коробки») — поэтому объект «{rp}» редактировать нельзя."
            fix = (
                "Либо снять защиту явно (навык support-edit, два шага):\n"
                f'  1. support-edit -Path "{cfg_dir}" -Capability on — включить возможность изменения (объекты пока остаются на замке);\n'
                f'  2. support-edit -Path "{rp}" -Set editable — открыть этот объект для редактирования.\n'
                "  Изменение применяется в базу полной загрузкой выгрузки и обходит механизм обновлений вендора."
            )
        elif code == "not-removed":
            state = f"Состояние: объект «{rp}» на поддержке (не снят с поддержки) — его удаление разорвёт обновления вендора."
            fix = (
                "Либо сначала снять объект с поддержки, затем удалять:\n"
                f'  support-edit -Path "{rp}" -Set off-support — объект уходит из-под обновлений, после этого удаление безопасно.'
            )
        else:
            state = f"Состояние: объект «{rp}» на замке (возможность изменения конфигурации включена, но сам объект не редактируется)."
            fix = (
                "Либо разрешить редактирование этого объекта (навык support-edit, выбрать одно):\n"
                f'  support-edit -Path "{rp}" -Set editable — редактировать и дальше получать обновления вендора (возможны конфликты слияния);\n'
                f'  support-edit -Path "{rp}" -Set off-support — снять с поддержки: обновления по объекту больше не приходят.'
            )
        sys.stderr.write(head + "\n" + state + "\n" + cfe + "\n" + fix + "\n" + off_note + "\n")
        sys.exit(1)
    except SystemExit:
        raise
    except Exception:
        return


def esc_xml(s):
    # Эскейп ЗНАЧЕНИЯ АТРИБУТА: & < > и кавычка — внутри "..." литеральная " невалидна.
    return s.replace('&', '&amp;').replace('<', '&lt;').replace('>', '&gt;').replace('"', '&quot;')


def esc_xml_text(s):
    """Экранирование ТЕКСТА элемента: только & < > . Кавычки платформа в тексте не экранирует
    (92142 сырых кавычки на корпус, ни одной &quot;); &quot; она принимает, но нормализует обратно."""
    return s.replace('&', '&amp;').replace('<', '&lt;').replace('>', '&gt;')


def write_utf8_bom(path, content):
    # newline='' — без трансляции: иначе текстовый режим Python дал бы CRLF на Windows
    # и LF на macOS, то есть вывод навыка зависел бы от ОС.
    with open(path, 'w', encoding='utf-8-sig', newline='') as f:
        f.write(content)



def detect_format_version(d):
    while d:
        # Автономная внешняя обработка/отчёт: своего Configuration.xml у неё нет, версию несёт
        # корень самой обработки. Без этого форма и макет внутри обработки 2.21 писались бы 2.17.
        ext_path = d + ".xml"
        if os.path.isfile(ext_path):
            with open(ext_path, "r", encoding="utf-8-sig") as f:
                ext_head = f.read(2000)
            if re.search(r'<(ExternalDataProcessor|ExternalReport)[ >]', ext_head):
                m = re.search(r'<MetaDataObject[^>]+version="(\d+\.\d+)"', ext_head)
                if m:
                    return m.group(1)
        cfg_path = os.path.join(d, "Configuration.xml")
        if os.path.isfile(cfg_path):
            with open(cfg_path, "r", encoding="utf-8-sig") as f:
                head = f.read(2000)
            m = re.search(r'<MetaDataObject[^>]+version="(\d+\.\d+)"', head)
            if m:
                return m.group(1)
        parent = os.path.dirname(d)
        if parent == d:
            break
        d = parent
    return "2.17"


def format_rank(ver):
    """"2.20" → 220, "2.9" → 209. Строковое сравнение неверно ("2.9" > "2.17")."""
    m = re.match(r'^(\d+)\.(\d+)$', ver or '')
    return int(m.group(1)) * 100 + int(m.group(2)) if m else 0


def to_font_size(raw):
    """Размер шрифта бывает дробным (8.3, 11.3). int() на таком падал, ps1 ТИХО округлял.
    Целое держим целым, иначе "10" превратилось бы в "10.0"."""
    s = str(raw).strip() if raw is not None else ''
    if not s:
        return 0
    try:
        d = float(s)
    except (TypeError, ValueError):
        return 0
    return int(d) if d == int(d) else d


def parse_col_value(val):
    """Позиция колонки как целое, иначе None. Аналог [int]::TryParse в ps1:
    целое из JSON приходит int, "3" — строкой, 3.0 — float (ps1 печатает такое как "3")."""
    if isinstance(val, bool) or val is None:
        return None
    if isinstance(val, int):
        return val
    if isinstance(val, float):
        return int(val) if val.is_integer() else None
    try:
        return int(str(val).strip())
    except (TypeError, ValueError):
        return None


def main():
    sys.stdout.reconfigure(encoding="utf-8")
    sys.stderr.reconfigure(encoding="utf-8")
    parser = argparse.ArgumentParser(description='Compile 1C spreadsheet from JSON', allow_abbrev=False)
    parser.add_argument('-JsonPath', type=str, required=True)
    parser.add_argument('-OutputPath', type=str, required=True)
    args = ci_parse_args(parser)

    # --- Detect XML format version ---
    # У корня <document> нет атрибута version, поэтому версию берём из конфигурации, в дерево
    # которой пишем макет. Вне конфигурации (автономный .xml, исходники EPF) остаётся 2.17.
    out_path_resolved = args.OutputPath if os.path.isabs(args.OutputPath) else os.path.join(os.getcwd(), args.OutputPath)
    format_version = detect_format_version(os.path.dirname(out_path_resolved))

    # --- 1. Load and validate JSON ---
    json_path = args.JsonPath
    if not os.path.exists(json_path):
        print(f"File not found: {json_path}", file=sys.stderr)
        sys.exit(1)

    with open(json_path, 'r', encoding='utf-8-sig') as f:
        defn = ci_json(json.load(f))

    # Проверяем НАЛИЧИЕ ключа, а не истинность значения: `columns: 0` — осмысленная величина
    # (раскладка по умолчанию пустая, все строки живут в именованных раскладках), а пустой
    # список областей встречается у макета без строк. Прежняя проверка объявляла и то
    # и другое отсутствующим.
    if 'columns' not in defn or defn.get('columns') is None:
        print("Required field 'columns' is missing", file=sys.stderr)
        sys.exit(1)
    if 'areas' not in defn or defn.get('areas') is None:
        print("Required field 'areas' is missing", file=sys.stderr)
        sys.exit(1)

    total_columns = int(defn['columns'])
    default_width = int(defn['defaultWidth']) if defn.get('defaultWidth') else 10

    # --- 2. Build font palette ---
    font_map = {}   # name -> 0-based index
    font_entries = []  # list of dicts

    def add_font(name, font_def):
        face = font_def.get('face', 'Arial') if font_def else 'Arial'
        size = to_font_size(font_def.get('size', 10)) if font_def else 10
        bold = 'true' if font_def and font_def.get('bold') is True else 'false'
        italic = 'true' if font_def and font_def.get('italic') is True else 'false'
        underline = 'true' if font_def and font_def.get('underline') is True else 'false'
        strikeout = 'true' if font_def and font_def.get('strikeout') is True else 'false'

        idx = len(font_entries)
        font_map[name] = idx
        font_entries.append({
            'Face': face,
            'Size': size,
            'Bold': bold,
            'Italic': italic,
            'Underline': underline,
            'Strikeout': strikeout,
        })

    # Add user-defined fonts
    has_default = False
    if defn.get('fonts'):
        for fname, fdef in defn['fonts'].items():
            if fname == 'default':
                has_default = True
            add_font(fname, fdef)

    # Ensure default font exists
    if not has_default:
        add_font('default', {'face': 'Arial', 'size': 10})

    # --- 3. Determine line palette ---
    has_thin_borders = False
    has_thick_borders = False

    if defn.get('styles'):
        for sname, sval in defn['styles'].items():
            if sval.get('border') and sval['border'] != 'none':
                if sval.get('borderWidth') == 'thick':
                    has_thick_borders = True
                else:
                    has_thin_borders = True

    thin_line_index = -1
    thick_line_index = -1
    line_count = 0
    if has_thin_borders:
        thin_line_index = line_count
        line_count += 1
    if has_thick_borders:
        thick_line_index = line_count
        line_count += 1

    # --- 4. Parse column width specs ---
    def parse_column_spec(spec):
        cols = []
        for part in spec.split(','):
            part = part.strip()
            m = re.match(r'^(\d+)-(\d+)$', part)
            if m:
                from_col = int(m.group(1))
                to_col = int(m.group(2))
                for i in range(from_col, to_col + 1):
                    cols.append(i)
            else:
                cols.append(int(part))
        return cols

    # --- 4a. Auto-calculate defaultWidth from page format ---
    page_targets = {
        'A4-landscape': 780,
        'A4-portrait': 540,
    }

    page_name = None
    target_width = None
    if defn.get('page'):
        page_name = str(defn['page'])

        if re.match(r'^\d+$', page_name):
            target_width = int(page_name)
        elif page_name in page_targets:
            target_width = page_targets[page_name]
        else:
            print(f"WARNING: Unknown page format '{page_name}'. Known: {', '.join(page_targets.keys())}, or a number.", file=sys.stderr)

        if target_width:
            total_units = 0.0
            absolute_sum = 0
            specified_cols = {}

            if defn.get('columnWidths'):
                for prop_name, prop_value in defn['columnWidths'].items():
                    val = str(prop_value)
                    cols = parse_column_spec(prop_name)
                    for c in cols:
                        specified_cols[int(c)] = True
                        m = re.match(r'^([0-9.]+)x$', val)
                        if m:
                            total_units += float(m.group(1))
                        else:
                            absolute_sum += int(val)

            for c in range(1, total_columns + 1):
                if c not in specified_cols:
                    total_units += 1.0

            if total_units > 0:
                default_width = round((target_width - absolute_sum) / total_units)

    # Build column width map: 1-based col -> width
    def build_col_width_map(widths):
        out = {}
        if widths:
            for prop_name, prop_value in widths.items():
                val = str(prop_value)
                m = re.match(r'^([0-9.]+)x$', val)
                width = round(float(m.group(1)) * default_width) if m else int(val)
                for c in parse_column_spec(prop_name):
                    out[c] = width
        return out

    col_width_map = build_col_width_map(defn.get('columnWidths'))

    # Колоночные раскладки: документные columns/columnWidths — раскладка по умолчанию (в XML
    # элемент <columns> БЕЗ <id>, он всегда идёт первым). Дополнительные объявляются в
    # columnSets, ключ — идентификатор, на него ссылается область ключом columnSet.
    # Склейки по содержимому нет: в корпусе полно раскладок с одинаковым содержимым и разными
    # идентификаторами, поэтому опознаёт раскладку только идентификатор.
    def to_layout_id(name):
        """Платформа хранит идентификатор раскладки как UUID и другой не принимает. Имя,
        полученное декомпиляцией, уже UUID — оставляем как есть, иначе раундтрип перестал бы
        совпадать. Читаемое имя автора превращаем в UUID ДЕТЕРМИНИРОВАННО (из хэша имени),
        чтобы повторная компиляция давала тот же файл."""
        if re.match(r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-'
                    r'[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$', name):
            return name
        # UUID версии 3 (имя + MD5, RFC 4122): биты версии и варианта проставляются, иначе это
        # не UUID, а просто шестнадцатеричная строка нужной формы.
        b = bytearray(hashlib.md5(name.encode('utf-8')).digest())
        b[6] = (b[6] & 0x0F) | 0x30   # версия 3
        b[8] = (b[8] & 0x3F) | 0x80   # вариант RFC 4122
        h = b.hex()
        return f'{h[0:8]}-{h[8:12]}-{h[12:16]}-{h[16:20]}-{h[20:32]}'

    column_layouts = [{'Id': None, 'Name': None, 'Size': total_columns, 'Widths': col_width_map}]
    for set_name, cs in (defn.get('columnSets') or {}).items():
        size = int(cs['columns']) if cs.get('columns') is not None else total_columns
        column_layouts.append({
            'Id': to_layout_id(set_name),
            'Name': set_name,
            'Size': size,
            'Widths': build_col_width_map(cs.get('columnWidths')),
        })

    # --- 5. Style resolver ---
    def resolve_style(style_name, fill_type):
        font_idx = font_map.get('default', 0)
        lb = -1; tb = -1; rb = -1; bb = -1
        ha = ''; va = ''; nf = ''
        wrap = False

        if style_name and defn.get('styles'):
            style = defn['styles'].get(style_name)
            if style:
                # Font
                if style.get('font') and style['font'] in font_map:
                    font_idx = font_map[style['font']]

                # Borders
                if style.get('border') and style['border'] != 'none':
                    line_idx = thick_line_index if style.get('borderWidth') == 'thick' else thin_line_index
                    for side in style['border'].split(','):
                        side = side.strip()
                        if side == 'all':
                            lb = line_idx; tb = line_idx; rb = line_idx; bb = line_idx
                        elif side == 'left':
                            lb = line_idx
                        elif side == 'top':
                            tb = line_idx
                        elif side == 'right':
                            rb = line_idx
                        elif side == 'bottom':
                            bb = line_idx

                # Alignment
                if style.get('align'):
                    align_map = {'left': 'Left', 'center': 'Center', 'right': 'Right'}
                    ha = align_map.get(style['align'], '')
                if style.get('valign'):
                    valign_map = {'top': 'Top', 'center': 'Center'}
                    va = valign_map.get(style['valign'], '')

                # Wrap
                if style.get('wrap') is True:
                    wrap = True

                # Number format
                if style.get('format'):
                    nf = style['format']

        return {
            'FontIdx': font_idx,
            'LB': lb, 'TB': tb, 'RB': rb, 'BB': bb,
            'HA': ha, 'VA': va,
            'Wrap': wrap,
            'FillType': fill_type,
            'NumberFormat': nf,
        }

    # --- 6. Format palette builder ---
    format_registry = {}   # key -> props
    format_order = []       # ordered keys for index assignment

    def get_format_key(font_idx=-1, lb=-1, tb=-1, rb=-1, bb=-1, ha='', va='',
                       wrap=False, fill_type='', number_format='', width=-1, height=-1):
        return f'f={font_idx}|lb={lb}|tb={tb}|rb={rb}|bb={bb}|ha={ha}|va={va}|wr={wrap}|ft={fill_type}|nf={number_format}|w={width}|h={height}'

    def register_format(key, props):
        if key not in format_registry:
            format_registry[key] = props
            format_order.append(key)
        # Return 1-based index
        return format_order.index(key) + 1

    # 6a. Default width format
    default_format_key = get_format_key(width=default_width)
    default_format_index = register_format(default_format_key, {'Width': default_width})

    # 6b. Column width formats — по одной карте на каждую колоночную раскладку
    for layout in column_layouts:
        fmap = {}  # 1-based col -> format index
        for col in sorted(layout['Widths']):
            w = layout['Widths'][col]
            fmap[int(col)] = register_format(get_format_key(width=w), {'Width': w})
        layout['FormatMap'] = fmap
    col_format_map = column_layouts[0]['FormatMap']

    # 6c. Helper: determine fillType from cell content
    def get_fill_type(cell):
        """Text НЕ эмитим: платформа его практически не пишет — на выборке корпуса 344 981
        текстовая ячейка из 348 023 (99,1%) ссылается на формат БЕЗ fillType. Наличие <tl>
        и так означает текст. Parameter и Template платформа пишет — их оставляем."""
        if cell.get('param'):
            return 'Parameter'
        if cell.get('template'):
            return 'Template'
        return ''

    # Helper: register a cell format and return its index
    def register_cell_format(style_name, fill_type):
        resolved = resolve_style(style_name, fill_type)
        key = get_format_key(
            font_idx=resolved['FontIdx'],
            lb=resolved['LB'], tb=resolved['TB'], rb=resolved['RB'], bb=resolved['BB'],
            ha=resolved['HA'], va=resolved['VA'],
            wrap=resolved['Wrap'], fill_type=resolved['FillType'],
            number_format=resolved['NumberFormat'])
        props = {
            'FontIdx': resolved['FontIdx'],
            'LB': resolved['LB'], 'TB': resolved['TB'],
            'RB': resolved['RB'], 'BB': resolved['BB'],
            'HA': resolved['HA'], 'VA': resolved['VA'],
            'Wrap': resolved['Wrap'],
            'FillType': resolved['FillType'],
            'NumberFormat': resolved['NumberFormat'],
        }
        return register_format(key, props)

    # --- 5.5. Шорткат строк: строка-массив ячеек ---
    # Та же форма, что у макетов СКД (skd-compile): позиция ячейки = индекс в массиве,
    # ">" продолжает ячейку слева, "|" — ячейку сверху, null — пустая колонка,
    # "{Имя}" — параметр. Разворачиваем в обычную строку с явными col/span/rowspan,
    # поэтому весь код ниже про шорткат не знает.

    def expand_shorthand_row(row, area_name, row_idx, open_by_col, max_cols):
        cells = []
        placed = {}      # 1-based col -> ячейка, занимающая колонку в ЭТОЙ строке
        extended = []    # ячейки, чей rowspan уже нарастили в этой строке (span>1 даёт несколько "|")
        last = None      # последняя реальная ячейка слева — цель для ">"

        for idx, el in enumerate(row, start=1):
            if idx > max_cols:
                print(f'Row exceeds \'columns\' ({max_cols}): area "{area_name}",'
                      f' row {row_idx}', file=sys.stderr)
                sys.exit(1)

            if el is None:
                last = None
                continue

            if isinstance(el, str) and el == '>':
                if last is None:
                    print(f'Row shorthand: \'>\' has no cell to the left: area "{area_name}",'
                          f' row {row_idx}, cell {idx}', file=sys.stderr)
                    sys.exit(1)
                last['span'] = int(last.get('span', 1)) + 1
                placed[idx] = last
                continue

            if isinstance(el, str) and el == '|':
                above = open_by_col.get(idx)
                if above is None:
                    print(f'Row shorthand: \'|\' has no cell above: area "{area_name}",'
                          f' row {row_idx}, cell {idx}', file=sys.stderr)
                    sys.exit(1)
                if not any(above is e for e in extended):
                    above['rowspan'] = int(above.get('rowspan', 1)) + 1
                    extended.append(above)
                placed[idx] = above
                last = None
                continue

            if isinstance(el, str):
                cell = CIDict()
                cell['col'] = idx
                cell['span'] = 1
                m = re.match(r'^\{(.+)\}$', el)
                if m:
                    cell['param'] = m.group(1)
                else:
                    cell['text'] = el
            else:
                # Объектный элемент — обычная ячейка mxl, позиция берётся из индекса.
                if 'col' in el:
                    print(f'Row shorthand: cell object must not carry \'col\': area "{area_name}",'
                          f' row {row_idx}, cell {idx}', file=sys.stderr)
                    sys.exit(1)
                cell = el
                cell['col'] = idx
                if not cell.get('span'):
                    cell['span'] = 1

            cells.append(cell)
            placed[idx] = cell
            last = cell

        # Колонки, не занятые в этой строке, теряют «ячейку сверху».
        open_by_col.clear()
        open_by_col.update(placed)

        out = CIDict()
        out['cells'] = cells
        return out

    # Карту занятых колонок ведём и по объектным строкам: "|" продолжает ту ячейку,
    # которая реально стоит выше, независимо от того, какой формой её записали.
    def update_open_by_col(row, open_by_col):
        placed = {}
        for cell in (row.get('cells') or []):
            # Ячейки без col (строка с автопотоком) на этом шаге ещё не разложены — позиция
            # станет известна позже, поэтому «ячейку сверху» они не дают, и "|" под такой
            # строкой честно скажет, что сверху ничего нет.
            if cell.get('col') is None:
                continue
            col = int(cell['col'])
            span = int(cell.get('span', 1))
            for c in range(col, col + span):
                placed[c] = cell
        open_by_col.clear()
        open_by_col.update(placed)

    for area in defn['areas']:
        area_name = area.get('name', '')
        # Ширина сетки берётся из раскладки области: у каждой она своя.
        area_max_cols = total_columns
        if area.get('columnSet'):
            lay = next((x for x in column_layouts if x['Name'] == str(area['columnSet'])), None)
            if lay:
                area_max_cols = int(lay['Size'])
        open_by_col = {}
        expanded_rows = []
        for row_idx, row in enumerate(area.get('rows', []), start=1):
            if isinstance(row, list):
                expanded_rows.append(expand_shorthand_row(row, area_name, row_idx, open_by_col, area_max_cols))
            else:
                expanded_rows.append(row)
                if row.get('empty'):
                    open_by_col.clear()
                else:
                    update_open_by_col(row, open_by_col)
        area['rows'] = expanded_rows

    # Pre-register all formats from areas
    for area in defn['areas']:
        for row in area.get('rows', []):
            # Skip empty row placeholder
            if row.get('empty'):
                continue

            # Row height format
            if row.get('height'):
                h_key = get_format_key(height=int(row['height']))
                register_format(h_key, {'Height': int(row['height'])})

            # rowStyle gap-fill format
            if row.get('rowStyle'):
                register_cell_format(row['rowStyle'], '')

            # Explicit cell formats
            if row.get('cells'):
                for cell in row['cells']:
                    cell_style = cell.get('style') or row.get('rowStyle') or 'default'
                    ft = get_fill_type(cell)
                    register_cell_format(cell_style, ft)

    # --- 7. Generate XML ---
    lines = []

    # 7a. Header
    lines.append('<?xml version="1.0" encoding="UTF-8"?>')
    doc_ns_decl = ('xmlns="http://v8.1c.ru/8.2/data/spreadsheet" xmlns:style="http://v8.1c.ru/8.1/data/ui/style"'
                   ' xmlns:v8="http://v8.1c.ru/8.1/data/core" xmlns:v8ui="http://v8.1c.ru/8.1/data/ui"'
                   ' xmlns:xs="http://www.w3.org/2001/XMLSchema" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance"')
    # 2.21 (8.5) добавила в шапку пространство палитры. Вставляем НА МЕСТО (перед style):
    # платформа держит объявления по алфавиту, дописать в конец нельзя.
    if format_rank(format_version) >= 221:
        doc_ns_decl = doc_ns_decl.replace(
            ' xmlns:style=',
            ' xmlns:pal="http://v8.1c.ru/8.1/data/ui/colors/palette" xmlns:style=')
    lines.append(f'<document {doc_ns_decl}>')

    # 7b. Language settings
    lines.append('\t<languageSettings>')
    lines.append('\t\t<currentLanguage>ru</currentLanguage>')
    lines.append('\t\t<defaultLanguage>ru</defaultLanguage>')
    lines.append('\t\t<languageInfo>')
    lines.append('\t\t\t<id>ru</id>')
    lines.append('\t\t\t<code>\u0420\u0443\u0441\u0441\u043a\u0438\u0439</code>')
    lines.append('\t\t\t<description>\u0420\u0443\u0441\u0441\u043a\u0438\u0439</description>')
    lines.append('\t\t</languageInfo>')
    lines.append('\t</languageSettings>')

    # 7c. Columns
    # Раскладка по умолчанию идёт первой и без <id> — так их хранит платформа.
    for layout in column_layouts:
        lines.append('\t<columns>')
        if layout['Id']:
            lines.append(f'\t\t<id>{layout["Id"]}</id>')
        lines.append(f'\t\t<size>{layout["Size"]}</size>')

        # Emit columnsItem for columns with non-default widths
        for col in sorted(layout['FormatMap'].keys()):
            fmt_idx = layout['FormatMap'][col]
            col_idx = col - 1  # Convert to 0-based
            lines.append('\t\t<columnsItem>')
            lines.append(f'\t\t\t<index>{col_idx}</index>')
            lines.append('\t\t\t<column>')
            lines.append(f'\t\t\t\t<formatIndex>{fmt_idx}</formatIndex>')
            lines.append('\t\t\t</column>')
            lines.append('\t\t</columnsItem>')

        lines.append('\t</columns>')

    # 7d. Rows -- main generation loop
    global_row = 0
    merges = []
    named_items = []
    active_rowspans = []  # list of {ColStart, ColEnd, StartLocalRow, EndLocalRow}

    for area in defn['areas']:
        area_start_row = global_row
        area_name = area.get('name', '')
        active_rowspans = []
        local_row = 0
        # Ссылка области на колоночную раскладку — её получают все строки области.
        # Раскладка адресуется ИМЕНЕМ из columnSets — инлайновой формы в этом DSL нет ни у чего
        # (стиль и шрифт тоже только по имени). Иначе сообщение включало бы сериализованный
        # объект, а он у портов выглядит по-разному.
        if isinstance(area.get('columnSet'), (dict, list)):
            print(f'\'columnSet\' must be a name declared in columnSets, got an object:'
                  f' area "{area.get("name", "")}"', file=sys.stderr)
            sys.exit(1)
        area_column_set_name = str(area.get('columnSet') or '')
        area_column_set = ''
        area_layout = column_layouts[0]
        if area_column_set_name:
            area_layout = next((x for x in column_layouts if x['Name'] == area_column_set_name), None)
            if area_layout is None:
                print(f'Unknown \'columnSet\': "{area_column_set_name}" is not declared in columnSets',
                      file=sys.stderr)
                sys.exit(1)
            area_column_set = area_layout['Id']
        # Ширина сетки — у КАЖДОЙ раскладки своя, поэтому позиции колонок сверяем с ней,
        # а не с документным columns (у макетов с раскладками умолчание бывает и пустым).
        area_columns = int(area_layout['Size'])

        for row in area.get('rows', []):
            # Empty row placeholder: emit N empty rows
            if row.get('empty'):
                count = int(row['empty'])
                for ei in range(count):
                    lines.append('\t<rowsItem>')
                    lines.append(f'\t\t<index>{global_row}</index>')
                    lines.append('\t\t<row>')
                    lines.append('\t\t\t<empty>true</empty>')
                    lines.append('\t\t</row>')
                    lines.append('\t</rowsItem>')
                    global_row += 1
                    local_row += 1
                continue

            # Build set of columns occupied by rowspans from previous rows
            rowspan_occupied = {}
            for rs in active_rowspans:
                if local_row > rs['StartLocalRow'] and local_row <= rs['EndLocalRow']:
                    for c in range(rs['ColStart'], rs['ColEnd'] + 1):
                        rowspan_occupied[c] = True

            row_has_content = False
            row_cells = []

            # Determine row height format
            row_format_idx = 0
            if row.get('height'):
                h_key = get_format_key(height=int(row['height']))
                if h_key in format_registry:
                    row_format_idx = format_order.index(h_key) + 1

            if row.get('cells') and len(row['cells']) > 0:
                row_has_content = True

                # Прощающий ввод: строка, в которой НИ У ОДНОЙ ячейки нет col, раскладывается
                # слева направо с учётом span и rowspan сверху. Канон один и он в документации —
                # col обязателен; здесь мы лишь спасаем естественный DSL вместо тихой порчи
                # (в ps1 $null -> [int]0 -> Col = -1). Смешанную строку не угадываем: это опечатка.
                positioned = [c for c in row['cells']
                              if 'col' in c and c.get('col') is not None and str(c.get('col')) != '']
                if len(positioned) == 0:
                    cursor = 1
                    for cell in row['cells']:
                        col_span = int(cell.get('span', 1))
                        while any(c in rowspan_occupied for c in range(cursor, cursor + col_span)):
                            cursor += 1
                        if cursor + col_span - 1 > area_columns:
                            print(f'Row exceeds \'columns\' ({area_columns}): area "{area_name}",'
                                  f' row {local_row + 1}', file=sys.stderr)
                            sys.exit(1)
                        cell['col'] = cursor
                        cursor += col_span
                elif len(positioned) != len(row['cells']):
                    print(f'Cell without \'col\' mixed with positioned cells: area "{area_name}",'
                          f' row {local_row + 1}', file=sys.stderr)
                    sys.exit(1)

                # Позиция обязана быть в 1..columns: до этой проверки нечисловой или нулевой col
                # ронял py голым KeyError/ValueError, а ps1 молча писал Col = -1.
                for cell_idx, cell in enumerate(row['cells'], start=1):
                    col_parsed = parse_col_value(cell.get('col'))
                    if col_parsed is None or col_parsed < 1 or col_parsed > area_columns:
                        print(f'Invalid \'col\' value "{cell.get("col")}": area "{area_name}",'
                              f' row {local_row + 1}, cell {cell_idx}', file=sys.stderr)
                        sys.exit(1)

                # Build set of occupied columns (1-based)
                occupied_cols = dict(rowspan_occupied)
                for cell in row['cells']:
                    col_start = int(cell['col'])
                    col_span = int(cell.get('span', 1))
                    for c in range(col_start, col_start + col_span):
                        occupied_cols[c] = True

                # Generate explicit cells
                for cell in row['cells']:
                    col_start = int(cell['col'])
                    col_span = int(cell.get('span', 1))
                    rowspan = int(cell.get('rowspan', 1))
                    cell_style = cell.get('style') or row.get('rowStyle') or 'default'
                    ft = get_fill_type(cell)
                    fmt_idx = register_cell_format(cell_style, ft)

                    cell_info = {
                        'Col': col_start - 1,  # 0-based
                        'FormatIdx': fmt_idx,
                        'Param': cell.get('param'),
                        'Detail': cell.get('detail'),
                        'Text': cell.get('text'),
                        'Template': cell.get('template'),
                    }
                    row_cells.append(cell_info)

                    # Track rowspan for subsequent rows
                    if rowspan > 1:
                        active_rowspans.append({
                            'ColStart': col_start,
                            'ColEnd': col_start + col_span - 1,
                            'StartLocalRow': local_row,
                            'EndLocalRow': local_row + rowspan - 1,
                        })

                    # Collect merge
                    if col_span > 1 or rowspan > 1:
                        merge = {'R': global_row, 'C': col_start - 1, 'W': col_span - 1}
                        if rowspan > 1:
                            merge['H'] = rowspan - 1
                        merges.append(merge)

                # Generate gap-fill cells for rowStyle
                if row.get('rowStyle'):
                    gap_fmt_idx = register_cell_format(row['rowStyle'], '')
                    for c in range(1, total_columns + 1):
                        if c not in occupied_cols:
                            row_cells.append({
                                'Col': c - 1,
                                'FormatIdx': gap_fmt_idx,
                                'Param': None,
                                'Detail': None,
                                'Text': None,
                                'Template': None,
                            })

                # Sort cells by column
                row_cells.sort(key=lambda x: x['Col'])

            elif row.get('rowStyle'):
                # Row with only rowStyle, no explicit cells
                row_has_content = True
                gap_fmt_idx = register_cell_format(row['rowStyle'], '')
                for c in range(1, total_columns + 1):
                    if c in rowspan_occupied:
                        continue
                    row_cells.append({
                        'Col': c - 1,
                        'FormatIdx': gap_fmt_idx,
                        'Param': None,
                        'Detail': None,
                        'Text': None,
                        'Template': None,
                    })

            # Emit rowsItem
            lines.append('\t<rowsItem>')
            lines.append(f'\t\t<index>{global_row}</index>')
            lines.append('\t\t<row>')

            if area_column_set:
                lines.append(f'\t\t\t<columnsID>{area_column_set}</columnsID>')

            if row_format_idx > 0:
                lines.append(f'\t\t\t<formatIndex>{row_format_idx}</formatIndex>')

            if not row_has_content:
                lines.append('\t\t\t<empty>true</empty>')
            else:
                for cell_info in row_cells:
                    lines.append('\t\t\t<c>')
                    lines.append(f'\t\t\t\t<i>{cell_info["Col"]}</i>')
                    lines.append('\t\t\t\t<c>')
                    lines.append(f'\t\t\t\t\t<f>{cell_info["FormatIdx"]}</f>')

                    if cell_info['Param']:
                        lines.append(f'\t\t\t\t\t<parameter>{cell_info["Param"]}</parameter>')
                        if cell_info['Detail']:
                            lines.append(f'\t\t\t\t\t<detailParameter>{cell_info["Detail"]}</detailParameter>')

                    if cell_info['Text']:
                        lines.append('\t\t\t\t\t<tl>')
                        lines.append('\t\t\t\t\t\t<v8:item>')
                        lines.append('\t\t\t\t\t\t\t<v8:lang>ru</v8:lang>')
                        lines.append(f'\t\t\t\t\t\t\t<v8:content>{esc_xml_text(cell_info["Text"])}</v8:content>')
                        lines.append('\t\t\t\t\t\t</v8:item>')
                        lines.append('\t\t\t\t\t</tl>')

                    if cell_info['Template']:
                        lines.append('\t\t\t\t\t<tl>')
                        lines.append('\t\t\t\t\t\t<v8:item>')
                        lines.append('\t\t\t\t\t\t\t<v8:lang>ru</v8:lang>')
                        lines.append(f'\t\t\t\t\t\t\t<v8:content>{esc_xml_text(cell_info["Template"])}</v8:content>')
                        lines.append('\t\t\t\t\t\t</v8:item>')
                        lines.append('\t\t\t\t\t</tl>')

                    lines.append('\t\t\t\t</c>')
                    lines.append('\t\t\t</c>')

            lines.append('\t\t</row>')
            lines.append('\t</rowsItem>')

            local_row += 1
            global_row += 1

        area_end_row = global_row - 1
        # Блок без имени — просто кусок сетки: строки, не принадлежащие ни одной именованной
        # области (в корпусе таких дыр 34%, а макетов вовсе без Rows-областей — 21%).
        # Имя на блоке — сахар: разворачиваем его в обычную именованную область типа Rows.
        if area_name:
            named_items.append({
                'Name': area_name,
                'BeginRow': area_start_row,
                'EndRow': area_end_row,
                'BeginCol': -1,
                'EndCol': -1,
            })

    total_row_count = global_row

    # 7d-bis. Именованные области, заданные координатами (namedAreas).
    # Нужны для всего, что блоком не выражается: области не-Rows и пересекающиеся Rows.
    # Ось, которую не указали, означает «вся» — так же устроен ТабличныйДокумент.Область().

    def to_area_range(spec, axis, where):
        """Диапазон — та же грамматика, что у columnWidths: число или "N-M". Список через
        запятую для области бессмыслен: область непрерывна, платформа разрывную не хранит."""
        if spec is None:
            return None
        s = str(spec).strip()
        if s == '':
            return None
        if ',' in s:
            print(f'namedAreas: \'{axis}\' must be a single number or range, got list "{s}": {where}',
                  file=sys.stderr)
            sys.exit(1)
        m = re.match(r'^(\d+)\s*-\s*(\d+)$', s)
        if m:
            frm, to = int(m.group(1)), int(m.group(2))
        elif re.match(r'^\d+$', s):
            frm = to = int(s)
        else:
            print(f'namedAreas: invalid \'{axis}\' value "{s}": {where}', file=sys.stderr)
            sys.exit(1)
        # Платформа трактует 0 как 1 (см. описание Область()) — принимаем так же.
        if frm < 1:
            frm = 1
        if to < frm:
            print(f'namedAreas: \'{axis}\' range is reversed "{s}": {where}', file=sys.stderr)
            sys.exit(1)
        return (frm, to)

    def from_r1c1(s):
        """Прощающий ввод: платформенный адрес "R1C1:R2C2" — модель, пишущая код на встроенном
        языке, естественно потянется за ним. В документацию не выносим."""
        s = s.strip()
        m = re.match(r'^R(\d+)(?:C(\d+))?(?::R(\d+)(?:C(\d+))?)?$', s, re.IGNORECASE)
        if not m:
            m2 = re.match(r'^C(\d+)(?::C(\d+))?$', s, re.IGNORECASE)
            if not m2:
                return None
            c1 = int(m2.group(1))
            c2 = int(m2.group(2)) if m2.group(2) else c1
            return (None, (c1, c2))
        r1 = int(m.group(1))
        r2 = int(m.group(3)) if m.group(3) else r1
        cols = None
        if m.group(2):
            c1 = int(m.group(2))
            c2 = int(m.group(4)) if m.group(4) else c1
            cols = (c1, c2)
        return ((r1, r2), cols)

    for na_idx, na in enumerate(defn.get('namedAreas') or [], start=1):
        na_name = str(na.get('name') or '')
        where = f'namedAreas[{na_idx}]' + (f' "{na_name}"' if na_name else '')
        if not na_name:
            print(f'namedAreas: \'name\' is required: {where}', file=sys.stderr)
            sys.exit(1)
        rows = to_area_range(na.get('rows'), 'rows', where)
        cols = to_area_range(na.get('cols'), 'cols', where)
        if not rows and not cols:
            addr = None
            for k in ('area', 'at', 'address'):
                if na.get(k):
                    addr = str(na.get(k))
                    break
            if addr:
                parsed = from_r1c1(addr)
                if parsed is None:
                    print(f'namedAreas: invalid address "{addr}": {where}', file=sys.stderr)
                    sys.exit(1)
                rows, cols = parsed
        if not rows and not cols:
            print(f'namedAreas: at least one of \'rows\'/\'cols\' is required: {where}', file=sys.stderr)
            sys.exit(1)
        # DSL 1-based, XML 0-based; отсутствующая ось помечается -1.
        named_items.append({
            'Name': na_name,
            'BeginRow': rows[0] - 1 if rows else -1,
            'EndRow': rows[1] - 1 if rows else -1,
            'BeginCol': cols[0] - 1 if cols else -1,
            'EndCol': cols[1] - 1 if cols else -1,
        })

    # 7e. Scalar metadata
    lines.append(f'\t<templateMode>true</templateMode>')
    lines.append(f'\t<defaultFormatIndex>{default_format_index}</defaultFormatIndex>')
    lines.append(f'\t<height>{total_row_count}</height>')
    lines.append(f'\t<vgRows>{total_row_count}</vgRows>')

    # 7f. Merges
    for m in merges:
        lines.append('\t<merge>')
        lines.append(f'\t\t<r>{m["R"]}</r>')
        lines.append(f'\t\t<c>{m["C"]}</c>')
        if m.get('H'):
            lines.append(f'\t\t<h>{m["H"]}</h>')
        lines.append(f'\t\t<w>{m["W"]}</w>')
        lines.append('\t</merge>')

    # 7g. Named items
    # Платформа хранит именованные элементы ОТСОРТИРОВАННЫМИ по имени: на выборке 541 макета
    # с несколькими элементами иного порядка нет ни разу. Сортировка регистронезависимая и
    # ординальная (в ps1 поэтому нельзя Sort-Object — он сортирует по текущей культуре).
    # NB: имён с «ё» в выборке не встретилось, этот случай не проверен.
    for ni in sorted(named_items, key=lambda x: str(x['Name']).lower()):
        # Тип области выводится из указанных осей, как в ТабличныйДокумент.Область():
        # нет колонок → полоса строк, нет строк → полоса колонок, обе → прямоугольник.
        has_rows = int(ni['BeginRow']) >= 0
        has_cols = int(ni.get('BeginCol', -1)) >= 0
        area_type = 'Rectangle' if (has_rows and has_cols) else ('Columns' if has_cols else 'Rows')
        lines.append('\t<namedItem xsi:type="NamedItemCells">')
        lines.append(f'\t\t<name>{ni["Name"]}</name>')
        lines.append('\t\t<area>')
        lines.append(f'\t\t\t<type>{area_type}</type>')
        lines.append(f'\t\t\t<beginRow>{ni["BeginRow"]}</beginRow>')
        lines.append(f'\t\t\t<endRow>{ni["EndRow"]}</endRow>')
        lines.append(f'\t\t\t<beginColumn>{ni.get("BeginCol", -1)}</beginColumn>')
        lines.append(f'\t\t\t<endColumn>{ni.get("EndCol", -1)}</endColumn>')
        lines.append('\t\t</area>')
        lines.append('\t</namedItem>')

    # 7h. Line palette
    if has_thin_borders:
        lines.append('\t<line width="1" gap="false">')
        lines.append('\t\t<v8ui:style xsi:type="v8ui:SpreadsheetDocumentCellLineType">Solid</v8ui:style>')
        lines.append('\t</line>')
    if has_thick_borders:
        lines.append('\t<line width="2" gap="false">')
        lines.append('\t\t<v8ui:style xsi:type="v8ui:SpreadsheetDocumentCellLineType">Solid</v8ui:style>')
        lines.append('\t</line>')

    # 7i. Font palette
    for fe in font_entries:
        lines.append(f'\t<font faceName="{fe["Face"]}" height="{fe["Size"]}" bold="{fe["Bold"]}" italic="{fe["Italic"]}" underline="{fe["Underline"]}" strikeout="{fe["Strikeout"]}" kind="Absolute" scale="100"/>')

    # 7j. Format palette
    for key in format_order:
        fmt = format_registry[key]
        lines.append('\t<format>')

        if fmt.get('FontIdx') is not None and fmt.get('FontIdx', -1) >= 0:
            lines.append(f'\t\t<font>{fmt["FontIdx"]}</font>')
        if fmt.get('LB') is not None and fmt.get('LB', -1) >= 0:
            lines.append(f'\t\t<leftBorder>{fmt["LB"]}</leftBorder>')
        if fmt.get('TB') is not None and fmt.get('TB', -1) >= 0:
            lines.append(f'\t\t<topBorder>{fmt["TB"]}</topBorder>')
        if fmt.get('RB') is not None and fmt.get('RB', -1) >= 0:
            lines.append(f'\t\t<rightBorder>{fmt["RB"]}</rightBorder>')
        if fmt.get('BB') is not None and fmt.get('BB', -1) >= 0:
            lines.append(f'\t\t<bottomBorder>{fmt["BB"]}</bottomBorder>')
        if fmt.get('Width'):
            lines.append(f'\t\t<width>{fmt["Width"]}</width>')
        if fmt.get('Height'):
            lines.append(f'\t\t<height>{fmt["Height"]}</height>')
        if fmt.get('HA'):
            lines.append(f'\t\t<horizontalAlignment>{fmt["HA"]}</horizontalAlignment>')
        if fmt.get('VA'):
            lines.append(f'\t\t<verticalAlignment>{fmt["VA"]}</verticalAlignment>')
        if fmt.get('Wrap') is True:
            lines.append('\t\t<textPlacement>Wrap</textPlacement>')
        if fmt.get('FillType'):
            lines.append(f'\t\t<fillType>{fmt["FillType"]}</fillType>')
        if fmt.get('NumberFormat'):
            lines.append('\t\t<format>')
            lines.append('\t\t\t<v8:item>')
            lines.append('\t\t\t\t<v8:lang>ru</v8:lang>')
            lines.append(f'\t\t\t\t<v8:content>{esc_xml_text(fmt["NumberFormat"])}</v8:content>')
            lines.append('\t\t\t</v8:item>')
            lines.append('\t\t</format>')

        lines.append('\t</format>')

    # 7k. Close document
    lines.append('</document>')

    # --- 8. Write output ---
    out_path = args.OutputPath
    if not os.path.isabs(out_path):
        out_path = os.path.join(os.getcwd(), out_path)

    assert_edit_allowed(out_path, "editable")

    out_dir = os.path.dirname(out_path)
    if out_dir and not os.path.exists(out_dir):
        os.makedirs(out_dir, exist_ok=True)

    content = '\r\n'.join(lines)
    write_utf8_bom(out_path, content)

    # --- 9. Summary ---
    print(f"[OK] Compiled: {args.OutputPath}")
    if defn.get('page'):
        print(f"     Page: {page_name} -> target {target_width}, defaultWidth={default_width}")
    print(f"     Areas: {len(named_items)}, Rows: {total_row_count}, Columns: {total_columns}")
    print(f"     Fonts: {len(font_entries)}, Lines: {line_count}, Formats: {len(format_registry)}")
    print(f"     Merges: {len(merges)}")


if __name__ == '__main__':
    main()
