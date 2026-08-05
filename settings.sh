#!/usr/bin/env bash
# ==============================================================================
# settings.sh - Read and write OptionSettings in PalWorldSettings.ini
#
#   Palworld packs 119 settings into a single `OptionSettings=(K=V,K=V,...)` line.
#
#   [Safety design] Rather than re-serialising the whole line, only the requested
#   keys are rewritten in place. A key added by a future game update is therefore
#   never lost just because this script doesn't know about it.
#
#   Usage:
#     ./settings.sh --json                     # dump all settings as JSON
#     ./settings.sh --get ExpRate              # read one value
#     ./settings.sh --set ExpRate=2.0 ServerName="My Server"
#     ./settings.sh --diff                     # show only what differs from default
#     ./settings.sh --reset                    # reset gameplay values only
#     ./settings.sh --reset ExpRate Difficulty # reset the named keys only
#     ./settings.sh --reset --all              # reset operational keys too (careful)
# ==============================================================================
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
source ./config.sh

[[ -f "$SETTINGS_INI" ]] || die "설정 파일이 없습니다: $SETTINGS_INI
    서버를 한 번 설치/기동해야 생성됩니다."

MODE="${1:---json}"
shift || true

# Shared python implementation, so the parsing rules live in exactly one place.
run_py() {
  local py_mode="$1"; shift
  INI="$SETTINGS_INI" DEFAULT_INI="$DEFAULT_SETTINGS_INI" PY_MODE="$py_mode" \
    python3 - "$@" <<'PY'
import os, re, sys, json

path = os.environ["INI"]
mode = os.environ["PY_MODE"]
raw  = open(path, encoding="utf-8").read()

OPT_RE = re.compile(r'(OptionSettings=\()(.*)(\))', re.S)
m = OPT_RE.search(raw)
if not m:
    print("OptionSettings 블록을 찾지 못했습니다.", file=sys.stderr)
    sys.exit(2)
body = m.group(2)

def split_top(s):
    """Split on top-level commas only, ignoring those inside parens or quotes."""
    out, depth, inq, cur = [], 0, False, ""
    for ch in s:
        if ch == '"':
            inq = not inq
        elif not inq and ch == '(':
            depth += 1
        elif not inq and ch == ')':
            depth -= 1
        if ch == ',' and depth == 0 and not inq:
            out.append(cur); cur = ""
        else:
            cur += ch
    out.append(cur)
    return out

def kind(v):
    if v in ("True", "False"):            return "bool"
    if v.startswith('"'):                 return "string"
    if v.startswith('('):                 return "tuple"
    if re.fullmatch(r'-?\d+\.\d+', v):    return "float"
    if re.fullmatch(r'-?\d+', v):         return "int"
    return "enum"

items = []
for part in split_top(body):
    if '=' not in part:
        continue
    k, v = part.split('=', 1)
    items.append((k.strip(), v.strip()))

# Defaults from DefaultPalWorldSettings.ini, for comparison
defaults = {}
dpath = os.environ.get("DEFAULT_INI", "")
if dpath and os.path.exists(dpath):
    dm = OPT_RE.search(open(dpath, encoding="utf-8").read())
    if dm:
        for part in split_top(dm.group(2)):
            if '=' in part:
                dk, dv = part.split('=', 1)
                defaults[dk.strip()] = dv.strip()

def unquote(v):
    return v[1:-1] if v.startswith('"') and v.endswith('"') else v

# Keys that would cut off access or management if reverted.
# --reset leaves these alone by default: clearing AdminPassword and flipping
# RCONEnabled back to False drops safe shutdown to signals and risks losing the
# save. They are only included with --all.
OPERATIONAL_KEYS = {
    "AdminPassword", "ServerPassword", "ServerName", "ServerDescription",
    "RCONEnabled", "RCONPort", "RESTAPIEnabled", "RESTAPIPort",
    "PublicPort", "PublicIP", "Region", "BanListURL",
}

def commit_changes(changes):
    """Apply [(key, old, new)] to the file, rewriting only those keys."""
    if not changes:
        print("변경할 내용이 없습니다.")
        return 0

    new_body = body
    for k, old, new in changes:
        pattern = re.compile(r'(?<![A-Za-z0-9_])' + re.escape(k) + r'='
                             + re.escape(old) + r'(?=,|\)|$)')
        new_body, n = pattern.subn(f'{k}={new}', new_body, count=1)
        if n != 1:
            print(f"{k} 치환에 실패했습니다. 파일을 수정하지 않았습니다.", file=sys.stderr)
            return 7

    new_raw = raw[:m.start(2)] + new_body + raw[m.end(2):]

    import shutil, datetime
    stamp = datetime.datetime.now().strftime("%Y%m%d_%H%M%S")
    shutil.copy2(path, f"{path}.bak_{stamp}")
    open(path, "w", encoding="utf-8").write(new_raw)

    for k, old, new in changes:
        print(f"  {k}: {old or '(빈값)'} → {new or '(빈값)'}")
    print(f"\n{len(changes)}개 항목 변경. 백업: {os.path.basename(path)}.bak_{stamp}")
    return 0

# ------------------------------------------------------------------ Read
if mode == "json":
    out = []
    for k, v in items:
        t = kind(v)
        entry = {"key": k, "type": t, "raw": v, "value": unquote(v)}
        if k in defaults:
            entry["default"] = unquote(defaults[k])
            entry["modified"] = defaults[k] != v
        out.append(entry)
    # Passwords appear verbatim; this output is for the local app/CLI only.
    print(json.dumps(out, ensure_ascii=False))
    sys.exit(0)

if mode == "get":
    want = sys.argv[1]
    for k, v in items:
        if k.lower() == want.lower():
            print(unquote(v)); sys.exit(0)
    print(f"그런 항목이 없습니다: {want}", file=sys.stderr)
    sys.exit(3)

if mode == "diff":
    rows = [(k, unquote(defaults[k]), unquote(v))
            for k, v in items if k in defaults and defaults[k] != v]
    if not rows:
        print("기본값과 다른 항목이 없습니다.")
    else:
        w = max(len(r[0]) for r in rows)
        for k, d, c in rows:
            print(f"  {k.ljust(w)}  {d or '(빈값)'}  →  {c or '(빈값)'}")
    sys.exit(0)

# ------------------------------------------------------------------ Write
if mode == "set":
    current = {k: v for k, v in items}
    changes = []
    for arg in sys.argv[1:]:
        if '=' not in arg:
            print(f"형식이 잘못됐습니다 (Key=Value): {arg}", file=sys.stderr)
            sys.exit(4)
        k, newv = arg.split('=', 1)
        k = k.strip()
        if k not in current:
            print(f"알 수 없는 항목입니다: {k}", file=sys.stderr)
            sys.exit(5)

        t = kind(current[k])
        newv = newv.strip()

        # Normalise the value to the existing entry's type, so a wrong format from
        # the app or the user cannot corrupt the file.
        if t == "bool":
            low = newv.strip('"').lower()
            if low in ("true", "1", "on", "yes"):    formatted = "True"
            elif low in ("false", "0", "off", "no"): formatted = "False"
            else:
                print(f"{k}: True/False 가 필요합니다 (받은 값: {newv})", file=sys.stderr)
                sys.exit(6)
        elif t == "float":
            bare = unquote(newv)
            try:
                formatted = "%.6f" % float(bare)
            except ValueError:
                print(f"{k}: 숫자가 필요합니다 (받은 값: {newv})", file=sys.stderr); sys.exit(6)
        elif t == "int":
            bare = unquote(newv)
            try:
                formatted = str(int(float(bare)))
            except ValueError:
                print(f"{k}: 정수가 필요합니다 (받은 값: {newv})", file=sys.stderr); sys.exit(6)
        elif t == "string":
            inner = unquote(newv)
            if '"' in inner:
                print(f"{k}: 값에 큰따옴표를 넣을 수 없습니다.", file=sys.stderr); sys.exit(6)
            formatted = f'"{inner}"'
        else:  # enum and tuple are used verbatim
            formatted = unquote(newv) if t == "enum" else newv

        if formatted != current[k]:
            changes.append((k, current[k], formatted))
            current[k] = formatted

    sys.exit(commit_changes(changes))

# ------------------------------------------------------------------ Reset
if mode == "reset":
    if not defaults:
        print("DefaultPalWorldSettings.ini 를 찾을 수 없어 기본값을 알 수 없습니다.",
              file=sys.stderr)
        sys.exit(8)

    args = sys.argv[1:]
    include_all = "--all" in args
    wanted = [a for a in args if not a.startswith("--")]
    current = {k: v for k, v in items}

    if wanted:
        # Only the named keys — an operational key named explicitly is honoured
        targets = []
        for k in wanted:
            if k not in current:
                print(f"알 수 없는 항목입니다: {k}", file=sys.stderr)
                sys.exit(5)
            if k not in defaults:
                print(f"기본값을 알 수 없는 항목입니다: {k}", file=sys.stderr)
                sys.exit(8)
            targets.append(k)
    else:
        targets = [k for k in current if k in defaults]
        if not include_all:
            targets = [k for k in targets if k not in OPERATIONAL_KEYS]

    changes = [(k, current[k], defaults[k])
               for k in targets if current[k] != defaults[k]]

    if not wanted and not include_all:
        skipped = [k for k, v in items
                   if k in OPERATIONAL_KEYS and k in defaults and v != defaults[k]]
        if skipped:
            print("운영 항목은 보호되어 그대로 둡니다 "
                  "(복구하면 접속·관리가 끊길 수 있음):")
            for k in skipped:
                print(f"    {k}")
            print("    → 굳이 되돌리려면 --reset --all\n")

    sys.exit(commit_changes(changes))

print(f"알 수 없는 모드: {mode}", file=sys.stderr)
sys.exit(1)
PY
}

case "$MODE" in
  --json) run_py json ;;
  --get)  [[ $# -ge 1 ]] || die "조회할 항목명을 지정하세요."; run_py get "$@" ;;
  --diff) run_py diff ;;
  --reset)
    run_py reset "$@"
    if is_running; then
      warn "서버가 실행 중입니다. 변경된 설정은 재시작 후에 적용됩니다."
      printf '    ./auto_restart.sh    (백업 후 안전하게 재시작)\n'
    fi
    ;;
  --set)
    [[ $# -ge 1 ]] || die "Key=Value 형식으로 지정하세요."
    run_py set "$@"
    # Make it clear that a running server needs a restart to pick this up.
    if is_running; then
      warn "서버가 실행 중입니다. 변경된 설정은 재시작 후에 적용됩니다."
      printf '    ./auto_restart.sh    (백업 후 안전하게 재시작)\n'
    fi
    ;;
  -h|--help) sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//' ;;
  *) die "알 수 없는 옵션: $MODE (--json | --get | --set | --diff | --reset)" ;;
esac
