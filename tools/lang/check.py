#!/usr/bin/env python3
"""Check the translation tables (metal/src/main/resources/mcopt/shade/lang/*.json) against the menu's English texts.

  tools/lang/check.py            missing and unused entries of every table; exit 1 if any
  tools/lang/check.py --english  every English text, one JSON string per line (a start for a new table)

The menu's texts are Spanish / English pairs in the Java sources (ShadeLang.t and the ShadeOptions builders); a table maps
the English text, exactly as written (spaces and punctuation too), to the translation. ShadeLang shows the English text for
any entry a table lacks. A text that mixes literals and run-time values is listed as a warning: it can't be checked.
"""
import argparse, json, pathlib, re, sys

ROOT = pathlib.Path(__file__).resolve().parents[2]
JAVA = ROOT / 'metal/src/main/java'
LANG = ROOT / 'metal/src/main/resources/mcopt/shade/lang'

# call -> the 0-based argument positions holding English texts (a String[] literal: each of its items)
BUILDERS = {'pct': (2, 4), 'pctOf': (2, 4), 'pctInt': (2, 4), 'num': (2, 4), 'custom': (2, 4), 'toggle': (2, 4), 'choice': (2, 4, 7)}
PAIRS = {'t': (1,), 'h': (1,), 'header': (1,), 'page': (1, 3)}
CALL = re.compile(r'(?<![\w$])(?:mcopt\.metal\.shade\.)?(?:ShadeLang\.)?(\w+)\s*\(')
STRING = re.compile(r'"((?:[^"\\\n]|\\.)*)"')


def mask(src):
    """src with comments, string and char literals blanked (same length): brackets and commas found in it are code."""
    out = list(src)
    for m in re.finditer(r'//[^\n]*|/\*.*?\*/|"(?:[^"\\\n]|\\.)*"|\'(?:[^\'\\\n]|\\.)*\'', src, re.S):
        for j in range(m.start() + (m.group()[0] in '"\''), m.end() - (m.group()[0] in '"\'')):
            if out[j] != '\n':
                out[j] = ' '
    return ''.join(out)


def args(src, masked, start):
    """The argument texts of the call whose '(' is at start."""
    depth, begin, out = 0, start + 1, []
    for i in range(start, len(src)):
        c = masked[i]
        if c in '([{':
            depth += 1
        elif c in ')]}':
            depth -= 1
            if depth == 0:
                out.append(src[begin:i])
                return out
        elif c == ',' and depth == 1:
            out.append(src[begin:i])
            begin = i + 1
    raise ValueError('unbalanced call at %d' % start)


def literal(expr):
    """The value of a string literal expression ("a" or "a" + "b"), else None."""
    if not re.fullmatch(r'\s*%s(\s*\+\s*%s)*\s*' % (STRING.pattern, STRING.pattern), expr):
        return None
    return ''.join(json.loads('"%s"' % s) for s in STRING.findall(expr))


def english():
    texts, warnings = {}, []
    for path in sorted(JAVA.rglob('*.java')):
        src = path.read_text(encoding='utf-8')
        if 'ShadeLang' not in src and 'ShadeOption' not in src:
            continue
        masked = mask(src)
        for m in CALL.finditer(masked):
            positions = BUILDERS.get(m.group(1)) or PAIRS.get(m.group(1))
            if not positions:
                continue
            a = args(src, masked, m.end() - 1)
            where = '%s:%d' % (path.relative_to(ROOT), src.count('\n', 0, m.start()) + 1)
            for p in positions:
                if p >= len(a):
                    continue
                expr = a[p].strip()
                items = re.fullmatch(r'new\s+String\s*\[\s*\]\s*\{(.*)\}', expr, re.S)
                for e in (args('(' + items.group(1) + ')', mask('(' + items.group(1) + ')'), 0) if items else [expr]):
                    v = literal(e.strip())
                    if v is None and '"' in e:  # (a parameter passed on, e.g. ShadeOption's this.en, is checked where it is given)
                        warnings.append('%s: %s(... %s ...) is not a literal' % (where, m.group(1), e.strip()))
                    elif v is not None and v.strip() and not v.isdigit():
                        texts.setdefault(v, where)
        # String[] constants of {es, en} pairs (ShadeOptions.ON)
        for m in re.finditer(r'String\[\]\s+\w+\s*=\s*\{\s*("(?:[^"\\]|\\.)*")\s*,\s*("(?:[^"\\]|\\.)*")\s*\}', src):
            texts.setdefault(literal(m.group(2)), '%s:%d' % (path.relative_to(ROOT), src.count('\n', 0, m.start()) + 1))
    return texts, warnings


def main():
    p = argparse.ArgumentParser()
    p.add_argument('--english', action='store_true')
    a = p.parse_args()
    texts, warnings = english()
    if a.english:
        for t in texts:
            print(json.dumps(t, ensure_ascii=False))
        return 0
    for w in warnings:
        print('warning:', w)
    bad = 0
    for table in sorted(LANG.glob('*.json')):
        entries = json.loads(table.read_text(encoding='utf-8'))
        for t, where in texts.items():
            if t not in entries:
                bad += 1
                print('%s: missing %s (%s)' % (table.name, json.dumps(t, ensure_ascii=False), where))
        for t in entries:
            if t not in texts:
                bad += 1
                print('%s: unused %s' % (table.name, json.dumps(t, ensure_ascii=False)))
    print('%d English texts, %d problems' % (len(texts), bad))
    return 1 if bad else 0


if __name__ == '__main__':
    sys.exit(main())
