#!/usr/bin/env python3
# mxl-decompile v1.9 — Decompile 1C spreadsheet to JSON
# Source: https://github.com/Nikolay-Shirokov/cc-1c-skills

import argparse
import os
import sys
from collections import OrderedDict
from lxml import etree

# Регистронезависимый ввод — паритет с PS1: в PowerShell имена параметров и [ValidateSet]
# регистр не различают, в argparse совпадение точное.
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


# --- Namespace map ---

NSMAP = {
    "d": "http://v8.1c.ru/8.2/data/spreadsheet",
    "v8": "http://v8.1c.ru/8.1/data/core",
    "v8ui": "http://v8.1c.ru/8.1/data/ui",
    "xsi": "http://www.w3.org/2001/XMLSchema-instance",
}

XSI_NS = "http://www.w3.org/2001/XMLSchema-instance"


def find(node, xpath):
    return node.find(xpath, NSMAP)


def findall(node, xpath):
    return node.findall(xpath, NSMAP)


def text_of(node):
    if node is not None and node.text:
        return node.text
    return None


def to_font_size(raw):
    """Размер шрифта бывает дробным (8.3, 11.3 — в корпусе ERP это треть макетов).
    int() на таком падал, а ps1 ТИХО округлял. Целое держим целым, иначе "10" → "10.0"."""
    s = str(raw).strip() if raw is not None else ''
    if not s:
        return 0
    try:
        d = float(s)
    except (TypeError, ValueError):
        return 0
    return int(d) if d == int(d) else d


def int_of(node, default=0):
    if node is not None and node.text:
        return int(node.text)
    return default


# Custom JSON serializer — компактный, 2-пробельный indent, массивы примитивов inline.
# В отличие от ConvertTo-Json (PS5.1):
#   - не выравнивает ключи объекта по самому длинному
#   - не разворачивает массивы примитивов на отдельные строки
#   - кириллица в UTF-8 (без \uXXXX-escapes)
def convert_string_to_json_literal(s):
    if s is None:
        return 'null'
    out = ['"']
    for ch in s:
        code = ord(ch)
        if code == 0x22:
            out.append('\\"')
        elif code == 0x5C:
            out.append('\\\\')
        elif code == 0x08:
            out.append('\\b')
        elif code == 0x09:
            out.append('\\t')
        elif code == 0x0A:
            out.append('\\n')
        elif code == 0x0C:
            out.append('\\f')
        elif code == 0x0D:
            out.append('\\r')
        elif code < 0x20:
            out.append('\\u%04x' % code)
        else:
            out.append(ch)
    out.append('"')
    return ''.join(out)


def _fmt_number(v):
    if isinstance(v, bool):
        return 'true' if v else 'false'
    if isinstance(v, int):
        return str(v)
    if isinstance(v, float):
        # Invariant culture: '.' decimal sep
        if v == int(v):
            # Preserve float-ness: PS [double] 5.0 → "5"
            # Match PS ToString invariant: 5.0 → "5"
            return str(int(v))
        return repr(v)
    return str(v)


def try_inline_json(obj):
    if obj is None:
        return 'null'
    if isinstance(obj, bool):
        return 'true' if obj else 'false'
    if isinstance(obj, str):
        return convert_string_to_json_literal(obj)
    if isinstance(obj, (int, float)):
        return _fmt_number(obj)
    if isinstance(obj, dict):
        if len(obj) == 0:
            return '{}'
        parts = []
        for k, v in obj.items():
            vs = try_inline_json(v)
            if vs is None:
                return None
            parts.append(convert_string_to_json_literal(str(k)) + ': ' + vs)
        return '{ ' + ', '.join(parts) + ' }'
    if isinstance(obj, (list, tuple)):
        if len(obj) == 0:
            return '[]'
        parts = []
        for it in obj:
            vs = try_inline_json(it)
            if vs is None:
                return None
            parts.append(vs)
        return '[' + ', '.join(parts) + ']'
    return None


def convert_to_compact_json(obj, depth=0, indent_unit='  ', line_limit=400):
    indent = indent_unit * depth
    child_indent = indent_unit * (depth + 1)

    if obj is None:
        return 'null'
    if isinstance(obj, bool):
        return 'true' if obj else 'false'
    if isinstance(obj, str):
        return convert_string_to_json_literal(obj)
    if isinstance(obj, (int, float)):
        return _fmt_number(obj)

    # Try inline для объектов и массивов с объектами — если помещается в lineLimit с учётом текущего indent.
    is_container = isinstance(obj, (dict, list, tuple))
    if is_container:
        inline_attempt = try_inline_json(obj)
        if inline_attempt is not None and (len(indent) + len(inline_attempt)) <= line_limit:
            return inline_attempt

    if isinstance(obj, dict):
        if len(obj) == 0:
            return '{}'
        parts = []
        for k, v in obj.items():
            val = convert_to_compact_json(v, depth + 1, indent_unit, line_limit)
            parts.append(child_indent + convert_string_to_json_literal(str(k)) + ': ' + val)
        return "{\n" + ",\n".join(parts) + "\n" + indent + "}"
    if isinstance(obj, (list, tuple)):
        if len(obj) == 0:
            return '[]'
        parts = [child_indent + convert_to_compact_json(it, depth + 1, indent_unit, line_limit) for it in obj]
        return "[\n" + ",\n".join(parts) + "\n" + indent + "]"
    return convert_string_to_json_literal(str(obj))


# --- Main ---

def main():
    sys.stdout.reconfigure(encoding="utf-8")
    sys.stderr.reconfigure(encoding="utf-8")
    parser = argparse.ArgumentParser(description="Decompile 1C spreadsheet to JSON", allow_abbrev=False)
    parser.add_argument("-TemplatePath", "-Path", required=True, help="Path to Template.xml")
    parser.add_argument("-OutputPath", default=None, help="Output JSON path (stdout if omitted)")
    args = ci_parse_args(parser)

    template_path = args.TemplatePath
    output_path = args.OutputPath

    # --- 1. Load and parse XML ---

    if not os.path.isfile(template_path):
        print(f"File not found: {template_path}", file=sys.stderr)
        sys.exit(1)

    parser_xml = etree.XMLParser(remove_blank_text=False)
    tree = etree.parse(template_path, parser_xml)
    root = tree.getroot()

    # --- 2. Extract font palette ---

    raw_fonts = []
    for f_node in findall(root, "d:font"):
        raw_fonts.append({
            "Face": f_node.get("faceName", ""),
            "Size": to_font_size(f_node.get("height", "0")),
            "Bold": f_node.get("bold") == "true",
            "Italic": f_node.get("italic") == "true",
            "Underline": f_node.get("underline") == "true",
            "Strikeout": f_node.get("strikeout") == "true",
        })

    # --- 3. Extract line palette ---

    raw_lines = []
    for l_node in findall(root, "d:line"):
        raw_lines.append({"Width": int(l_node.get("width", "0"))})

    # --- 4. Extract format palette ---

    raw_formats = []
    for fmt_node in findall(root, "d:format"):
        fmt = {
            "FontIdx": -1,
            "LB": -1, "TB": -1, "RB": -1, "BB": -1,
            "Width": 0, "Height": 0,
            "HA": "", "VA": "",
            "Wrap": False, "FillType": "", "DataFormat": "",
        }

        n = find(fmt_node, "d:font")
        if n is not None and n.text:
            fmt["FontIdx"] = int(n.text)
        n = find(fmt_node, "d:leftBorder")
        if n is not None and n.text:
            fmt["LB"] = int(n.text)
        n = find(fmt_node, "d:topBorder")
        if n is not None and n.text:
            fmt["TB"] = int(n.text)
        n = find(fmt_node, "d:rightBorder")
        if n is not None and n.text:
            fmt["RB"] = int(n.text)
        n = find(fmt_node, "d:bottomBorder")
        if n is not None and n.text:
            fmt["BB"] = int(n.text)

        n = find(fmt_node, "d:width")
        if n is not None and n.text:
            fmt["Width"] = int(n.text)
        n = find(fmt_node, "d:height")
        if n is not None and n.text:
            fmt["Height"] = int(n.text)

        n = find(fmt_node, "d:horizontalAlignment")
        if n is not None and n.text:
            fmt["HA"] = n.text
        n = find(fmt_node, "d:verticalAlignment")
        if n is not None and n.text:
            fmt["VA"] = n.text

        n = find(fmt_node, "d:textPlacement")
        if n is not None and n.text == "Wrap":
            fmt["Wrap"] = True

        n = find(fmt_node, "d:fillType")
        if n is not None and n.text:
            fmt["FillType"] = n.text

        n = find(fmt_node, "d:format/v8:item/v8:content")
        if n is not None and n.text:
            fmt["DataFormat"] = n.text

        raw_formats.append(fmt)

    def get_format(idx):
        if idx <= 0 or idx > len(raw_formats):
            return None
        return raw_formats[idx - 1]

    # --- 5. Extract columns and default width ---

    # Колоночная раскладка («индивидуальная ширина колонок» для группы строк) — элемент <columns>.
    # Их бывает несколько: раскладка БЕЗ <id> — умолчание (ровно одна в каждом макете корпуса),
    # остальные адресуются GUID из <id>, на который ссылаются строки (<row><columnsID>) и
    # области (<area><columnsID>). Раньше читался только первый <columns> — отсюда терялись
    # ширины и вылезал columns: 0.

    default_fmt_idx = 0
    n = find(root, "d:defaultFormatIndex")
    if n is not None and n.text:
        default_fmt_idx = int(n.text)

    default_width = 10
    if default_fmt_idx > 0:
        def_fmt = get_format(default_fmt_idx)
        if def_fmt and def_fmt["Width"] > 0:
            default_width = def_fmt["Width"]

    def read_column_set(node):
        by_idx = {}
        for ci in findall(node, "d:columnsItem"):
            by_idx[int_of(find(ci, "d:index"))] = int_of(find(ci, "d:column/d:formatIndex"))
        # Карта ширин (1-based колонка → ширина), только отличные от умолчания.
        widths = OrderedDict()
        for col0 in sorted(by_idx.keys()):
            fmt = get_format(by_idx[col0])
            if fmt and fmt["Width"] > 0 and fmt["Width"] != default_width:
                widths[str(col0 + 1)] = fmt["Width"]
        id_node = find(node, "d:id")
        size_node = find(node, "d:size")
        return {
            "Id": (text_of(id_node) or None) if id_node is not None else None,
            "Size": int_of(size_node) if size_node is not None else 0,
            "Widths": widths,
        }

    column_sets = [read_column_set(cn) for cn in findall(root, "d:columns")]

    default_set = next((c for c in column_sets if not c["Id"]), None)
    if default_set is None and column_sets:
        default_set = column_sets[0]
    total_columns = default_set["Size"] if default_set else 0
    col_width_map = default_set["Widths"] if default_set else OrderedDict()

    # --- 6. Extract merges ---

    merge_map = {}
    for m_node in findall(root, "d:merge"):
        r = int_of(find(m_node, "d:r"))
        c = int_of(find(m_node, "d:c"))
        w = int_of(find(m_node, "d:w"))
        h_node = find(m_node, "d:h")
        h = int_of(h_node) if h_node is not None else 0
        merge_map[f"{r},{c}"] = {"W": w, "H": h}

    # --- 7. Extract named items ---

    # Захватываем области ВСЕХ типов. Раньше здесь стоял `if area_type != "Rows": continue`,
    # из-за чего терялись Rectangle и Columns — а они есть у 61% макетов корпуса.
    named_areas = []
    for ni_node in findall(root, "d:namedItem"):
        xsi_type = ni_node.get(f"{{{XSI_NS}}}type", "")
        if xsi_type != "NamedItemCells":
            continue

        area_node = find(ni_node, "d:area")
        if area_node is None:
            continue

        def coord(tag, node=area_node):
            n = find(node, "d:" + tag)
            return int_of(n) if n is not None else -1

        named_areas.append({
            "Name": text_of(find(ni_node, "d:name")) or "",
            "Type": text_of(find(area_node, "d:type")) or "",
            "BeginRow": coord("beginRow"),
            "EndRow": coord("endRow"),
            "BeginCol": coord("beginColumn"),
            "EndCol": coord("endColumn"),
        })

    # --- 8. Extract rows ---

    row_data = {}
    # Языки, на которых в макете вообще есть текст. Порядок — первого появления.
    doc_langs = OrderedDict()
    for ri_node in findall(root, "d:rowsItem"):
        row_idx = int_of(find(ri_node, "d:index"))
        row_node = find(ri_node, "d:row")

        index_to = row_idx
        it_node = find(ri_node, "d:indexTo")
        if it_node is not None and it_node.text:
            index_to = int(it_node.text)

        row_fmt_idx = 0
        fmt_node = find(row_node, "d:formatIndex")
        if fmt_node is not None and fmt_node.text:
            row_fmt_idx = int(fmt_node.text)

        is_empty = False
        empty_node = find(row_node, "d:empty")
        if empty_node is not None and empty_node.text == "true":
            is_empty = True

        cells = []
        if not is_empty:
            col = -1
            for c_group in findall(row_node, "d:c"):
                i_node = find(c_group, "d:i")
                if i_node is not None and i_node.text:
                    col = int(i_node.text)
                else:
                    col += 1

                c_content = find(c_group, "d:c")
                if c_content is None:
                    continue

                cell_fmt_idx = 0
                f_node = find(c_content, "d:f")
                if f_node is not None and f_node.text:
                    cell_fmt_idx = int(f_node.text)

                param = None
                p_node = find(c_content, "d:parameter")
                if p_node is not None and p_node.text:
                    param = p_node.text

                detail = None
                d_node = find(c_content, "d:detailParameter")
                if d_node is not None and d_node.text:
                    detail = d_node.text

                # Текст ячейки платформа хранит по элементу на язык. Раньше брался ПЕРВЫЙ, и всё
                # остальное терялось — в корпусе ERP 98% макетов держат текст и под ru, и под en.
                # Здесь собираем «язык → текст» как есть; свернётся в строку позже, когда станет
                # известен набор языков всего макета (get_dsl_text).
                text = None
                has_text = False
                items = findall(c_content, "d:tl/v8:item")
                if items:
                    by_lang = OrderedDict()
                    for it in items:
                        lang_node = find(it, "v8:lang")
                        content_node = find(it, "v8:content")
                        lang = (text_of(lang_node) or '') if lang_node is not None else ''
                        by_lang[lang] = (text_of(content_node) or '') if content_node is not None else ''
                        doc_langs[lang] = True
                    text = by_lang
                    # Единственный пустой русский текст содержимым не считается — такая ячейка
                    # уходит в заполнители строки.
                    has_text = not (len(by_lang) == 1 and by_lang.get('ru') == '')

                cells.append({
                    "Col": col,
                    "FormatIdx": cell_fmt_idx,
                    "Param": param,
                    "Detail": detail,
                    "Text": text,
                    "HasText": has_text,
                })

        # Ссылка строки на колоночную раскладку; пусто = раскладка по умолчанию.
        cid_node = find(row_node, "d:columnsID")
        row_columns_id = text_of(cid_node) if cid_node is not None else None

        for r in range(row_idx, index_to + 1):
            row_data[r] = {
                "FormatIdx": row_fmt_idx,
                "Cells": cells,
                "Empty": is_empty,
                "ColumnsId": row_columns_id,
            }

    # Языки текстов макета и языки, объявленные в конфигурации, — разные вещи: у типовых они
    # не совпадают. Строкой пишем текст, одинаковый на ВСЁМ наборе языков макета; остальное —
    # объектом.
    text_languages = list(doc_langs.keys())

    def get_dsl_text(by_lang):
        if not isinstance(by_lang, dict):
            return by_lang
        if len(by_lang) != len(text_languages):
            return by_lang
        common = None
        for lang in text_languages:
            if lang not in by_lang:
                return by_lang
            if common is None:
                common = by_lang[lang]
            elif by_lang[lang] != common:
                return by_lang
        return common

    # --- 9. Build style key (ignoring fillType) ---

    def get_border_desc(fmt):
        if not fmt:
            return {"Border": "none", "Thick": False}

        lb = fmt["LB"] >= 0
        tb = fmt["TB"] >= 0
        rb = fmt["RB"] >= 0
        bb = fmt["BB"] >= 0

        if not lb and not tb and not rb and not bb:
            return {"Border": "none", "Thick": False}

        thick = False
        for b_idx in [fmt["LB"], fmt["TB"], fmt["RB"], fmt["BB"]]:
            if b_idx >= 0 and b_idx < len(raw_lines) and raw_lines[b_idx]["Width"] >= 2:
                thick = True
                break

        if lb and tb and rb and bb:
            return {"Border": "all", "Thick": thick}

        sides = []
        if tb:
            sides.append("top")
        if bb:
            sides.append("bottom")
        if lb:
            sides.append("left")
        if rb:
            sides.append("right")

        return {"Border": ",".join(sides), "Thick": thick}

    def get_style_key(fmt):
        if not fmt:
            return "empty"
        fi = fmt["FontIdx"] if fmt["FontIdx"] >= 0 else 0
        bd = get_border_desc(fmt)
        return f"f={fi}|b={bd['Border']}|bw={bd['Thick']}|ha={fmt['HA']}|va={fmt['VA']}|wr={fmt['Wrap']}|df={fmt['DataFormat']}"

    # --- 10. Name fonts ---

    font_names = {}
    font_defs = OrderedDict()

    if len(raw_fonts) > 0:
        font_names[0] = "default"
        font_defs["default"] = raw_fonts[0]

    def get_font_key(f):
        return f"{f['Face']}|{f['Size']}|{f['Bold']}|{f['Italic']}|{f['Underline']}|{f['Strikeout']}"

    font_key_map = {}
    if len(raw_fonts) > 0:
        font_key_map[get_font_key(raw_fonts[0])] = "default"

    for i in range(1, len(raw_fonts)):
        f = raw_fonts[i]
        df = raw_fonts[0]

        # Dedup: if identical font already named, reuse
        f_key = get_font_key(f)
        if f_key in font_key_map:
            font_names[i] = font_key_map[f_key]
            continue

        name = None

        if f["Face"] == df["Face"] and f["Size"] == df["Size"]:
            if f["Bold"] and not df["Bold"] and not f["Italic"] and not f["Underline"] and not f["Strikeout"]:
                name = "bold"
            elif f["Italic"] and not df["Italic"] and not f["Bold"]:
                name = "italic"
            elif f["Underline"] and not df["Underline"] and not f["Bold"] and not f["Italic"]:
                name = "underline"
        elif f["Face"] == df["Face"] and f["Size"] > df["Size"] and f["Bold"]:
            name = "header"
        elif f["Face"] == df["Face"] and f["Size"] < df["Size"]:
            name = "small"

        if not name:
            parts = []
            if f["Face"] and f["Face"] != df["Face"]:
                parts.append(f["Face"].lower())
            parts.append(str(f["Size"]))
            if f["Bold"]:
                parts.append("bold")
            if f["Italic"]:
                parts.append("italic")
            if f["Underline"]:
                parts.append("underline")
            if f["Strikeout"]:
                parts.append("strikeout")
            name = "-".join(parts)

        base_name = name
        suffix = 2
        while name in font_defs:
            name = f"{base_name}{suffix}"
            suffix += 1

        font_names[i] = name
        font_defs[name] = f
        font_key_map[f_key] = name

    # --- 11. Collect and name styles ---

    style_keys = OrderedDict()
    format_to_style_key = {}

    for rd in row_data.values():
        for cell in rd["Cells"]:
            fmt = get_format(cell["FormatIdx"])
            if not fmt:
                continue
            key = get_style_key(fmt)
            if key not in style_keys:
                style_keys[key] = fmt
            format_to_style_key[cell["FormatIdx"]] = key

    def name_style(fmt):
        if not fmt:
            return "default"
        parts = []

        fi = fmt["FontIdx"] if fmt["FontIdx"] >= 0 else 0
        if fi in font_names and font_names[fi] != "default":
            parts.append(font_names[fi])

        bd = get_border_desc(fmt)
        if bd["Border"] != "none":
            if bd["Border"] == "all":
                parts.append("bordered")
            else:
                parts.append(f"border-{bd['Border']}")

        if fmt["HA"] == "Center":
            parts.append("center")
        elif fmt["HA"] == "Right":
            parts.append("right")
        if fmt["VA"] == "Center":
            parts.append("vcenter")
        elif fmt["VA"] == "Top":
            parts.append("vtop")
        if fmt["Wrap"]:
            parts.append("wrap")
        if fmt["DataFormat"]:
            parts.append("fmt")

        if len(parts) == 0:
            return "default"
        return "-".join(parts)

    style_names = OrderedDict()
    style_defs = OrderedDict()

    for key in style_keys:
        fmt = style_keys[key]
        name = name_style(fmt)

        base_name = name
        suffix = 2
        while name in style_defs:
            name = f"{base_name}{suffix}"
            suffix += 1

        style_names[key] = name

        s_def = OrderedDict()
        fi = fmt["FontIdx"] if fmt["FontIdx"] >= 0 else 0
        if fi in font_names and font_names[fi] != "default":
            s_def["font"] = font_names[fi]
        if fmt["HA"]:
            a_map = {"Left": "left", "Center": "center", "Right": "right"}
            a = a_map.get(fmt["HA"])
            if a:
                s_def["align"] = a
        if fmt["VA"]:
            va_map = {"Top": "top", "Center": "center"}
            a = va_map.get(fmt["VA"])
            if a:
                s_def["valign"] = a
        bd = get_border_desc(fmt)
        if bd["Border"] != "none":
            s_def["border"] = bd["Border"]
            if bd["Thick"]:
                s_def["borderWidth"] = "thick"
        if fmt["Wrap"]:
            s_def["wrap"] = True
        if fmt["DataFormat"]:
            s_def["format"] = fmt["DataFormat"]

        style_defs[name] = s_def

    def get_style_name(fmt_idx):
        key = format_to_style_key.get(fmt_idx)
        if key and key in style_names:
            return style_names[key]
        return "default"

    def to_positional_cells(cells):
        """Позиционная запись списка ячеек: позиция берётся из порядка, `col` не пишется.
        Применяем, когда первая ячейка стоит в колонке 1 — иначе список начнётся с череды None
        и станет длиннее объектного. Ячейка, у которой кроме текста или параметра ничего нет,
        пишется строкой; span раскрывается маркерами ">"; прочее — объектным элементом без col."""
        if not cells or int(cells[0].get("col", 0)) != 1:
            return cells
        out = []
        expected = 1
        for c in cells:
            col = int(c.get("col", 0))
            if col < expected:
                return cells   # перекрытие — позиционно не выразить
            while expected < col:
                out.append(None)
                expected += 1
            span = int(c.get("span", 1) or 1)
            keys = [k for k in c if k not in ("col", "span")]
            plain_text = len(keys) == 1 and keys[0] == "text" and isinstance(c["text"], str)
            plain_param = len(keys) == 1 and keys[0] == "param"
            if plain_text:
                out.append(c["text"])
            elif plain_param:
                out.append("{%s}" % c["param"])
            else:
                obj = OrderedDict((k, v) for k, v in c.items() if k != "col")
                out.append(obj)
            # span раскрываем маркерами — кроме объектного элемента, он несёт span сам.
            if (plain_text or plain_param) and span > 1:
                out.extend([">"] * (span - 1))
            expected = col + span
        return out

    # --- 12. Build areas ---

    # Сетка нарезается на блоки: непересекающиеся области типа Rows задают границы, строки вне
    # них становятся БЕЗЫМЯННЫМИ блоками. Раньше строки вне областей просто терялись — в корпусе
    # такие дыры у 34% макетов, а макетов вовсе без Rows-областей 21%.
    # Всё, что блоком не выражается (области не-Rows и пересекающиеся Rows), уходит в namedAreas
    # координатами. Правило детерминированное — иначе раундтрип поехал бы.

    max_row_idx = max(row_data.keys()) if row_data else -1

    def row_columns_id(r):
        rd = row_data.get(r)
        return rd["ColumnsId"] if rd else None

    def uniform_column_set(frm, to):
        """Область годится в качестве области-диапазона, только если у всех её строк ОДНА
        раскладка: иначе её пришлось бы резать, а имя резать нельзя."""
        first = row_columns_id(frm)
        return all(row_columns_id(r) == first for r in range(frm + 1, to + 1))

    block_areas = []
    overlay_areas = []
    claimed = set()
    for a in sorted(named_areas, key=lambda x: (x["BeginRow"], x["EndRow"])):
        fits = a["Type"] == "Rows" and a["BeginRow"] >= 0 and a["EndRow"] >= a["BeginRow"]
        if fits:
            for r in range(a["BeginRow"], a["EndRow"] + 1):
                if r in claimed:
                    fits = False
                    break
        if fits:
            fits = uniform_column_set(a["BeginRow"], a["EndRow"])
        if fits:
            claimed.update(range(a["BeginRow"], a["EndRow"] + 1))
            block_areas.append(a)
        else:
            overlay_areas.append(a)

    def split_gap_by_column_set(frm, to):
        """Безымянный промежуток режем на куски с одной раскладкой: границы наборов не
        совпадают с границами именованных областей."""
        out = []
        if to < frm:
            return out
        run_start = frm
        run_id = row_columns_id(frm)
        for r in range(frm + 1, to + 1):
            cid = row_columns_id(r)
            if cid != run_id:
                out.append({"Name": None, "BeginRow": run_start, "EndRow": r - 1, "ColumnsId": run_id})
                run_start, run_id = r, cid
        out.append({"Name": None, "BeginRow": run_start, "EndRow": to, "ColumnsId": run_id})
        return out

    # Области в порядке строк + безымянные заполнители дыр.
    blocks = []
    cursor = 0
    for a in sorted(block_areas, key=lambda x: x["BeginRow"]):
        if a["BeginRow"] > cursor:
            blocks.extend(split_gap_by_column_set(cursor, a["BeginRow"] - 1))
        blocks.append({"Name": a["Name"], "BeginRow": a["BeginRow"], "EndRow": a["EndRow"],
                       "ColumnsId": row_columns_id(a["BeginRow"])})
        cursor = a["EndRow"] + 1
    if cursor <= max_row_idx:
        blocks.extend(split_gap_by_column_set(cursor, max_row_idx))

    dsl_areas = []

    for area in blocks:
        area_rows = []

        for global_row in range(area["BeginRow"], area["EndRow"] + 1):
            rd = row_data.get(global_row)

            if not rd or rd["Empty"]:
                area_rows.append(OrderedDict())
                continue

            dsl_row = OrderedDict()

            # Row height
            if rd["FormatIdx"] > 0:
                row_fmt = get_format(rd["FormatIdx"])
                if row_fmt and row_fmt["Height"] > 0:
                    dsl_row["height"] = row_fmt["Height"]

            # Separate content cells from gap-fill cells
            content_cells = []
            gap_cells = []

            for cell in rd["Cells"]:
                has_content = cell["Param"] or cell["HasText"]
                has_merge = f"{global_row},{cell['Col']}" in merge_map

                if has_content or has_merge:
                    content_cells.append(cell)
                else:
                    gap_cells.append(cell)

            # Detect rowStyle
            row_style_name = None
            row_style_key = None

            if len(gap_cells) > 0:
                gap_keys = {}
                for gc in gap_cells:
                    fmt = get_format(gc["FormatIdx"])
                    gap_keys[get_style_key(fmt)] = True

                if len(gap_keys) == 1:
                    row_style_key = list(gap_keys.keys())[0]
                    if row_style_key in style_names:
                        row_style_name = style_names[row_style_key]

            if row_style_name and row_style_name != "default":
                dsl_row["rowStyle"] = row_style_name

            # Build cell list
            dsl_cells = []

            for cell in sorted(content_cells, key=lambda c: c["Col"]):
                dsl_cell = OrderedDict()
                dsl_cell["col"] = cell["Col"] + 1

                # Span/rowspan from merge
                mk = f"{global_row},{cell['Col']}"
                if mk in merge_map:
                    m = merge_map[mk]
                    if m["W"] > 0:
                        dsl_cell["span"] = m["W"] + 1
                    if m["H"] > 0:
                        dsl_cell["rowspan"] = m["H"] + 1

                # Style
                cell_fmt = get_format(cell["FormatIdx"])
                cell_style_key = get_style_key(cell_fmt)

                if row_style_key and cell_style_key == row_style_key:
                    pass  # Inherits rowStyle
                else:
                    # Стиль пишем, только когда он отличается от того, что подставит компилятор:
                    # без rowStyle умолчание и есть "default", поэтому такой ключ — шум (56% ячеек).
                    # А при заданном rowStyle стиль "default" писать ОБЯЗАТЕЛЬНО: раньше здесь было
                    # `not row_style_name`, и такая ячейка теряла стиль вовсе — при обратной сборке
                    # она наследовала rowStyle.
                    sn = get_style_name(cell["FormatIdx"])
                    if sn != "default" or row_style_name:
                        dsl_cell["style"] = sn

                # Content
                fill_type = cell_fmt["FillType"] if cell_fmt else ""

                if cell["Param"]:
                    dsl_cell["param"] = cell["Param"]
                    if cell["Detail"]:
                        dsl_cell["detail"] = cell["Detail"]
                elif fill_type == "Template" and cell["HasText"]:
                    dsl_cell["template"] = get_dsl_text(cell["Text"])
                elif cell["HasText"]:
                    dsl_cell["text"] = get_dsl_text(cell["Text"])

                dsl_cells.append(dsl_cell)

            if len(dsl_cells) > 0:
                dsl_row["cells"] = to_positional_cells(dsl_cells)
            # Самая короткая из применимых форм: если у строки нет своих свойств, а список ячеек
            # позиционный — строка пишется просто массивом, без ключа cells.
            if (len(dsl_row) == 1 and "cells" in dsl_row
                    and any(el is None or isinstance(el, str) for el in dsl_row["cells"])):
                area_rows.append(dsl_row["cells"])
            else:
                area_rows.append(dsl_row)

        # Compress consecutive empty rows ({}) into { empty = N }
        compressed_rows = []
        empty_run = 0
        for r in area_rows:
            if len(r) == 0:
                empty_run += 1
            else:
                if empty_run > 0:
                    if empty_run == 1:
                        compressed_rows.append(OrderedDict())
                    else:
                        compressed_rows.append(OrderedDict([("empty", empty_run)]))
                    empty_run = 0
                compressed_rows.append(r)
        if empty_run > 0:
            if empty_run == 1:
                compressed_rows.append(OrderedDict())
            else:
                compressed_rows.append(OrderedDict([("empty", empty_run)]))

        dsl_block = OrderedDict()
        # Область без имени — просто кусок сетки, ключ name у неё не пишем.
        if area["Name"]:
            dsl_block["name"] = area["Name"]
        # Ссылка на колоночную раскладку по имени из columnSets — как style у ячейки на styles.
        # Умолчание (раскладка без id) не пишем.
        if area.get("ColumnsId"):
            dsl_block["columnSet"] = area["ColumnsId"]
        dsl_block["rows"] = compressed_rows
        dsl_areas.append(dsl_block)

    # --- 13. Compress columnWidths ---

    compressed_widths = OrderedDict()
    if len(col_width_map) > 0:
        # Group columns by width
        width_to_cols = {}
        for col_str, width in col_width_map.items():
            width_to_cols.setdefault(width, []).append(col_str)

        for width, cols in width_to_cols.items():
            cols_sorted = sorted(cols, key=lambda x: int(x))

            ranges = []
            range_start = cols_sorted[0]
            range_prev = cols_sorted[0]

            for i in range(1, len(cols_sorted)):
                if int(cols_sorted[i]) == int(range_prev) + 1:
                    range_prev = cols_sorted[i]
                else:
                    if range_start == range_prev:
                        ranges.append(range_start)
                    else:
                        ranges.append(f"{range_start}-{range_prev}")
                    range_start = cols_sorted[i]
                    range_prev = cols_sorted[i]

            if range_start == range_prev:
                ranges.append(range_start)
            else:
                ranges.append(f"{range_start}-{range_prev}")

            for rng in ranges:
                compressed_widths[rng] = width

    # --- 14. Build fonts output ---

    fonts_out = OrderedDict()
    for name, f in font_defs.items():
        f_out = OrderedDict()
        f_out["face"] = f["Face"]
        f_out["size"] = f["Size"]
        if f["Bold"]:
            f_out["bold"] = True
        if f["Italic"]:
            f_out["italic"] = True
        if f["Underline"]:
            f_out["underline"] = True
        if f["Strikeout"]:
            f_out["strikeout"] = True
        fonts_out[name] = f_out

    # --- 15. Assemble result ---

    result = OrderedDict()
    result["columns"] = total_columns
    result["defaultWidth"] = default_width
    if len(compressed_widths) > 0:
        result["columnWidths"] = compressed_widths
    # Набор языков объявляем, только если он отличается от умолчания компилятора (один ru).
    if text_languages and text_languages != ['ru']:
        result["textLanguages"] = text_languages

    # Remove empty "default" style
    if "default" in style_defs and len(style_defs["default"]) == 0:
        del style_defs["default"]

    # Remove unused styles
    used_styles = set()
    for a in dsl_areas:
        for r in a["rows"]:
            # Строка может быть массивом (короткая форма) — у неё нет ключа cells, и без этой
            # ветки стиль, использованный только внутри такой строки, вырезался как «неиспользуемый».
            if isinstance(r, list):
                cell_list = r
            else:
                if "rowStyle" in r:
                    used_styles.add(r["rowStyle"])
                cell_list = r.get("cells") or []
            # Список ячеек может быть позиционным: строки, None и маркеры стиля не несут,
            # стиль бывает только у объектного элемента.
            for c in cell_list:
                if isinstance(c, dict) and "style" in c:
                    used_styles.add(c["style"])
    to_remove = [s for s in style_defs if s not in used_styles]
    for s in to_remove:
        del style_defs[s]

    result["fonts"] = fonts_out
    result["styles"] = style_defs

    # Колоночные раскладки помимо умолчания: ключ — идентификатор из макета, на него ссылаются
    # области. Содержимое раскладку не опознаёт (в корпусе полно наборов с одинаковым
    # содержимым и разными id), поэтому склейки по содержимому нет.
    extra_sets = [c for c in column_sets if c["Id"]]
    if extra_sets:
        sets_out = OrderedDict()
        for cs in extra_sets:
            entry = OrderedDict([("columns", cs["Size"])])
            if cs["Widths"]:
                entry["columnWidths"] = cs["Widths"]
            sets_out[cs["Id"]] = entry
        result["columnSets"] = sets_out

    result["areas"] = dsl_areas

    # Именованные области, не выразимые блоком, — координатами. Тип не пишем: он выводится
    # из указанных осей (как в ТабличныйДокумент.Область()). DSL 1-based, XML 0-based.
    if overlay_areas:
        na_out = []
        for a in overlay_areas:
            entry = OrderedDict([("name", a["Name"])])
            if a["BeginRow"] >= 0:
                entry["rows"] = (f'{a["BeginRow"] + 1}-{a["EndRow"] + 1}'
                                 if a["EndRow"] > a["BeginRow"] else a["BeginRow"] + 1)
            if a["BeginCol"] >= 0:
                entry["cols"] = (f'{a["BeginCol"] + 1}-{a["EndCol"] + 1}'
                                 if a["EndCol"] > a["BeginCol"] else a["BeginCol"] + 1)
            na_out.append(entry)
        result["namedAreas"] = na_out

    # --- 16. Convert to JSON ---

    json_str = convert_to_compact_json(result)

    # --- 17. Output ---

    if output_path:
        abs_path = os.path.join(os.getcwd(), output_path) if not os.path.isabs(output_path) else output_path
        with open(abs_path, "w", encoding="utf-8", newline="") as fh:
            fh.write(json_str)
        print(f"[OK] Decompiled: {output_path}")
    else:
        print(json_str)

    print(f"     Areas: {len(named_areas)}, Rows: {len(row_data)}, Columns: {total_columns}", file=sys.stderr)
    print(f"     Fonts: {len(font_defs)}, Styles: {len(style_defs)}, Merges: {len(merge_map)}", file=sys.stderr)


if __name__ == "__main__":
    main()
