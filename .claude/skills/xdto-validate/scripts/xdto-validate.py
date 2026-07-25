# xdto-validate v1.0 — Validate a 1C XDTO package (Python port)
# Source: https://github.com/Nikolay-Shirokov/cc-1c-skills
import argparse
import os
import sys

from lxml import etree

sys.stdout.reconfigure(encoding="utf-8")
sys.stderr.reconfigure(encoding="utf-8")

XS_NS = "http://www.w3.org/2001/XMLSchema"
XSI_NS = "http://www.w3.org/2001/XMLSchema-instance"
MD_NS = "http://v8.1c.ru/8.3/MDClasses"

parser = argparse.ArgumentParser(allow_abbrev=False)
parser.add_argument("-PackagePath", "-Path", required=True)
parser.add_argument("-ConfigDir", default="")
parser.add_argument("-Detailed", action="store_true")
parser.add_argument("-MaxErrors", type=int, default=20)
parser.add_argument("-OutFile", default="")
args = parser.parse_args()

package_path = os.path.abspath(args.PackagePath)
detailed = args.Detailed
max_errors = args.MaxErrors
out_file = args.OutFile

# ── reporting ────────────────────────────────────────────────

state = {"errors": 0, "warnings": 0, "ok": 0, "stopped": False}
output = []


def out_line(s):
    output.append(s)


def report_ok(msg):
    state["ok"] += 1
    if detailed:
        out_line(f"[OK]    {msg}")


def report_error(msg):
    state["errors"] += 1
    out_line(f"[ERROR] {msg}")
    if state["errors"] >= max_errors:
        state["stopped"] = True


def report_warn(msg):
    state["warnings"] += 1
    out_line(f"[WARN]  {msg}")


# ── resolve paths ────────────────────────────────────────────

bin_path = None
md_path = None

if os.path.isfile(package_path):
    if os.path.basename(package_path) == "Package.bin":
        bin_path = package_path
        pkg_dir = os.path.dirname(os.path.dirname(package_path))
        if os.path.exists(pkg_dir + ".xml"):
            md_path = pkg_dir + ".xml"
    elif package_path.endswith(".xml"):
        md_path = package_path
        stem = os.path.join(os.path.dirname(package_path),
                            os.path.splitext(os.path.basename(package_path))[0])
        c = os.path.join(stem, "Ext", "Package.bin")
        if os.path.exists(c):
            bin_path = c
elif os.path.isdir(package_path):
    c = os.path.join(package_path, "Ext", "Package.bin")
    if os.path.exists(c):
        bin_path = c
        m = package_path.rstrip("\\/") + ".xml"
        if os.path.exists(m):
            md_path = m

if not bin_path:
    print(f"[ERROR] Не найден Ext/Package.bin для пути: {package_path}")
    sys.exit(1)

file_name = os.path.basename(os.path.dirname(os.path.dirname(bin_path)))

config_dir = args.ConfigDir
if not config_dir:
    # .../XDTOPackages/<Имя>/Ext/Package.bin -> .../XDTOPackages -> корень
    config_dir = os.path.dirname(os.path.dirname(os.path.dirname(os.path.dirname(bin_path))))


def finalize():
    checks = state["ok"] + state["errors"] + state["warnings"]
    if state["errors"] == 0 and state["warnings"] == 0 and not detailed:
        result = f"=== Validation OK: {file_name} ({checks} checks) ==="
    else:
        out_line("")
        out_line(f"=== Result: {state['errors']} errors, {state['warnings']} warnings ({checks} checks) ===")
        result = "\n".join(output)
    print(result)
    if out_file:
        with open(out_file, "w", encoding="utf-8-sig", newline="") as f:
            f.write("\n".join(output))


def local(el):
    return etree.QName(el).localname


# ── 1. well-formedness ───────────────────────────────────────

try:
    doc = etree.parse(bin_path)
except Exception as e:  # noqa: BLE001
    report_error(f"Package.bin не является корректным XML: {e}")
    finalize()
    sys.exit(1)

pkg = doc.getroot()
if local(pkg) != "package":
    report_error(f"Ожидался корневой <package>, найден <{local(pkg)}>")
    finalize()
    sys.exit(1)
report_ok("Package.bin: корректный XML, корень <package>")

target_ns = pkg.get("targetNamespace")
if not target_ns:
    report_error("У <package> не задан targetNamespace")
else:
    report_ok(f"targetNamespace: {target_ns}")

# ── 2. encoding ──────────────────────────────────────────────

with open(bin_path, "rb") as f:
    head = f.read(3)
if head != b"\xef\xbb\xbf":
    report_warn("Package.bin без BOM UTF-8 — платформа пишет файл с BOM")
else:
    report_ok("Кодировка: UTF-8 с BOM")

# ── 3. declarations ──────────────────────────────────────────

imports = []
local_types = set()
global_props = set()

for n in pkg:
    if not isinstance(n.tag, str):
        continue
    ln = local(n)
    if ln == "import":
        imports.append(n.get("namespace"))
    elif ln in ("objectType", "valueType"):
        local_types.add(n.get("name"))
    elif ln == "property" and n.get("name"):
        global_props.add(n.get("name"))

# ── 4. duplicate type names ──────────────────────────────────

seen = set()
for n in pkg:
    if not isinstance(n.tag, str) or local(n) not in ("objectType", "valueType"):
        continue
    nm = n.get("name")
    if not nm:
        report_error(f"<{local(n)}> без атрибута name")
        continue
    if nm in seen:
        report_error(f"Дублирующееся имя типа: {nm}")
    else:
        seen.add(nm)
if local_types:
    report_ok(f"{len(local_types)} тип(ов), имена уникальны")

# ── 5. type references resolve ───────────────────────────────

used_namespaces = set()
any_type_props = []
REF_ATTRS = ("type", "base", "ref", "itemType")


def resolve_ref(el, attr, raw):
    if not raw:
        return
    if raw.startswith("{"):
        close = raw.find("}")
        if close < 0:
            report_error(f'Некорректная нотация Кларка в {attr}="{raw}"')
            return
        ns = raw[1:close]
        loc = raw[close + 1:]
    else:
        parts = raw.split(":")
        if len(parts) == 2:
            ns = el.nsmap.get(parts[0])
            loc = parts[1]
            if not ns:
                report_error(f'Префикс "{parts[0]}" не объявлен: {attr}="{raw}" (тип {local(el)})')
                return
        else:
            ns = None
            loc = parts[0]

    if ns in (XS_NS, XSI_NS):
        if loc == "anyType":
            any_type_props.append(el)
        return
    if ns == target_ns:
        if attr == "ref":
            if loc not in global_props:
                report_error(f'ref="{raw}" не разрешается: в пакете нет глобального свойства "{loc}"')
        elif loc not in local_types:
            report_error(f'{attr}="{raw}" не разрешается: в пакете нет типа "{loc}"')
        return
    if ns:
        used_namespaces.add(ns)
        if ns not in imports:
            report_error(f'{attr}="{raw}" ссылается на "{ns}", но <import namespace="{ns}"/> не объявлен')


node_count = 0
for el in pkg.iter():
    if not isinstance(el.tag, str):
        continue
    node_count += 1
    for a in REF_ATTRS:
        if el.get(a) is not None:
            resolve_ref(el, a, el.get(a))
    if el.get("memberTypes"):
        for m in el.get("memberTypes").split():
            resolve_ref(el, "memberTypes", m)
    if state["stopped"]:
        break
if not state["stopped"]:
    report_ok(f"{node_count} узлов: ссылки на типы разрешаются")

if state["stopped"]:
    finalize()
    sys.exit(1)

# ── 6. silent degradation to xs:anyType ──────────────────────

if any_type_props and imports:
    names = [p.get("name") for p in any_type_props if p.get("name")]
    shown = ", ".join(names[:5])
    report_warn(
        f'Свойств с type="xs:anyType": {len(any_type_props)} при объявленных импортах ({shown}). '
        "Возможна тихая деградация: при импорте XML-схемы платформа заменяет неразрешённый "
        "чужой тип на anyType без ошибки"
    )

# ── 7. unused imports ────────────────────────────────────────

for imp in imports:
    if imp not in used_namespaces:
        report_warn(f'<import namespace="{imp}"/> объявлен, но ни один тип из этого пространства имён не используется')
if imports and state["warnings"] == 0:
    report_ok(f"{len(imports)} импорт(ов) — все используются")

# ── 8. nillable on attribute-form properties ─────────────────

nill_attrs = [p.get("name") for p in pkg.iter()
              if isinstance(p.tag, str) and local(p) == "property"
              and p.get("form") == "Attribute" and p.get("nillable") == "true"]
if nill_attrs:
    report_warn(
        f'Свойств с nillable="true" и form="Attribute": {len(nill_attrs)} ({", ".join(nill_attrs[:5])}). '
        "Спецификация XSD не допускает nillable у атрибутов — экспорт XML-схемы в Конфигураторе их потеряет"
    )

# ── 9. facet consistency ─────────────────────────────────────

facet_checked = 0
for t in pkg.iter():
    if not isinstance(t.tag, str) or local(t) not in ("valueType", "typeDef"):
        continue
    if local(t) == "typeDef" and t.get(f"{{{XSI_NS}}}type") == "ObjectType":
        continue
    facet_checked += 1
    nm = t.get("name") or "(анонимный тип)"

    if t.get("length") and (t.get("minLength") or t.get("maxLength")):
        report_error(f"{nm} : length несовместим с minLength/maxLength")
    min_l, max_l = t.get("minLength"), t.get("maxLength")
    if min_l and max_l and int(min_l) > int(max_l):
        report_error(f"{nm} : minLength ({min_l}) больше maxLength ({max_l})")
    td, fd = t.get("totalDigits"), t.get("fractionDigits")
    if td and fd and int(fd) > int(td):
        report_error(f"{nm} : fractionDigits ({fd}) больше totalDigits ({td})")
    ws = t.get("whiteSpace")
    if ws and ws not in ("preserve", "replace", "collapse"):
        report_error(f'{nm} : недопустимое whiteSpace="{ws}"')
    var = t.get("variety")
    if var and var not in ("Atomic", "List", "Union"):
        report_error(f'{nm} : недопустимое variety="{var}"')
    if var == "List" and t.get("itemType") is None:
        report_warn(f'{nm} : variety="List" без itemType')
    if state["stopped"]:
        break
if facet_checked and not state["stopped"]:
    report_ok(f"{facet_checked} простых тип(ов): фасеты согласованы")

if state["stopped"]:
    finalize()
    sys.exit(1)

# ── 10. property form / bounds ───────────────────────────────

for p in pkg.iter():
    if not isinstance(p.tag, str) or local(p) != "property":
        continue
    form = p.get("form")
    if form and form not in ("Element", "Attribute", "Text"):
        report_error(f'Свойство "{p.get("name")}": недопустимое form="{form}"')
    ub = p.get("upperBound")
    if ub and ub != "-1" and int(ub) < 1:
        report_error(f'Свойство "{p.get("name")}": upperBound="{ub}" (допустимы -1 или число ≥ 1)')
    lb = p.get("lowerBound")
    if lb and ub and ub != "-1" and int(lb) > int(ub):
        report_error(f'Свойство "{p.get("name")}": lowerBound ({lb}) больше upperBound ({ub})')
    if p.get("name") is None and p.get("ref") is None:
        report_error("Свойство без name и без ref")
    if state["stopped"]:
        break
if not state["stopped"]:
    report_ok("Свойства: form и кратности корректны")

# ── 11. metadata object ──────────────────────────────────────

if md_path:
    md = etree.parse(md_path)
    md_name = md.find(f".//{{{MD_NS}}}XDTOPackage/{{{MD_NS}}}Properties/{{{MD_NS}}}Name")
    md_ns = md.find(f".//{{{MD_NS}}}XDTOPackage/{{{MD_NS}}}Properties/{{{MD_NS}}}Namespace")
    if md_name is None:
        report_error("В объекте метаданных не задано <Name>")
    elif (md_name.text or "") != file_name:
        report_error(f'<Name>{md_name.text}</Name> не совпадает с именем каталога "{file_name}"')
    else:
        report_ok(f"Объект метаданных: Name = {md_name.text}")
    if md_ns is not None and (md_ns.text or "") != target_ns:
        report_error(f"<Namespace>{md_ns.text}</Namespace> не совпадает с targetNamespace пакета ({target_ns})")
    elif md_ns is not None:
        report_ok("Namespace объекта метаданных совпадает с targetNamespace")
else:
    report_warn("Файл объекта метаданных <Имя>.xml не найден рядом с каталогом пакета")

# ── 12. registration + namespace uniqueness ──────────────────

config_xml = os.path.join(config_dir, "Configuration.xml")
if os.path.exists(config_xml):
    cfg = etree.parse(config_xml)
    registered = any((e.text or "") == file_name
                     for e in cfg.iterfind(f".//{{{MD_NS}}}Configuration/{{{MD_NS}}}ChildObjects/{{{MD_NS}}}XDTOPackage"))
    if registered:
        report_ok("Зарегистрирован в Configuration.xml")
    else:
        report_error(f"<XDTOPackage>{file_name}</XDTOPackage> отсутствует в ChildObjects файла "
                     "Configuration.xml — платформа пакет не увидит")

    pkg_root = os.path.join(config_dir, "XDTOPackages")
    if os.path.isdir(pkg_root):
        clash = []
        for other in sorted(os.listdir(pkg_root)):
            if other == file_name:
                continue
            ob = os.path.join(pkg_root, other, "Ext", "Package.bin")
            if not os.path.exists(ob):
                continue
            try:
                if etree.parse(ob).getroot().get("targetNamespace") == target_ns:
                    clash.append(other)
            except Exception:  # noqa: BLE001
                pass
        if clash:
            report_error(f'targetNamespace "{target_ns}" уже занят пакет(ами): {", ".join(clash)}. '
                         "Платформа не допускает два пакета с одним пространством имён")
        else:
            report_ok("targetNamespace уникален в конфигурации")
else:
    report_warn(f"Configuration.xml не найден ({config_dir}) — проверки регистрации и уникальности namespace пропущены")

finalize()
sys.exit(1 if state["errors"] > 0 else 0)
