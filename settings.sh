#!/usr/bin/env bash
# ==============================================================================
# settings.sh - PalWorldSettings.ini 의 OptionSettings 읽기/쓰기
#
#   팰월드 설정은 119개 항목이 `OptionSettings=(K=V,K=V,...)` 한 줄에 들어 있습니다.
#
#   [안전 설계] 전체를 재직렬화하지 않고 '요청받은 키만 정밀 치환'합니다.
#   게임 업데이트로 새 항목이 추가되어도 우리가 모르는 값이 유실되지 않습니다.
#
#   사용법:
#     ./settings.sh --json                     # 전체 설정을 JSON 으로 출력
#     ./settings.sh --get ExpRate              # 값 하나 조회
#     ./settings.sh --set ExpRate=2.0 ServerName="내 서버"
#     ./settings.sh --diff                     # 기본값과 다른 항목만 표시
#     ./settings.sh --reset                    # 게임플레이 값만 기본값 복구
#     ./settings.sh --reset ExpRate Difficulty # 지정한 항목만 복구
#     ./settings.sh --reset --all              # 운영 항목까지 전부 복구 (주의)
# ==============================================================================
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
source ./config.sh

[[ -f "$SETTINGS_INI" ]] || die "설정 파일이 없습니다: $SETTINGS_INI
    서버를 한 번 설치/기동해야 생성됩니다."

MODE="${1:---json}"
shift || true

# 파이썬 구현부를 공유합니다 (파싱 규칙을 한 곳에만 두기 위함).
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
    """괄호/따옴표 안의 콤마는 무시하고 최상위 항목만 분리."""
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

# 기본값(DefaultPalWorldSettings.ini)과 비교하기 위한 사전
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

# 되돌리면 서버 접속·관리가 끊기는 항목들.
# --reset 기본 동작에서는 건드리지 않습니다. 특히 AdminPassword 가 지워지고
# RCONEnabled 가 False 로 돌아가면 안전 종료가 시그널 방식으로 떨어져
# 세이브 유실 위험이 생깁니다. --all 을 줘야만 포함됩니다.
OPERATIONAL_KEYS = {
    "AdminPassword", "ServerPassword", "ServerName", "ServerDescription",
    "RCONEnabled", "RCONPort", "RESTAPIEnabled", "RESTAPIPort",
    "PublicPort", "PublicIP", "Region", "BanListURL",
}

def commit_changes(changes):
    """[(key, old, new)] 를 파일에 반영. 요청한 키만 정밀 치환합니다."""
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

# ------------------------------------------------------------------ 읽기
if mode == "json":
    out = []
    for k, v in items:
        t = kind(v)
        entry = {"key": k, "type": t, "raw": v, "value": unquote(v)}
        if k in defaults:
            entry["default"] = unquote(defaults[k])
            entry["modified"] = defaults[k] != v
        out.append(entry)
    # 비밀번호는 그대로 노출됩니다. 이 출력은 로컬 앱/CLI 전용입니다.
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

# ------------------------------------------------------------------ 쓰기
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

        # 기존 항목의 자료형에 맞춰 값을 정규화합니다.
        # 앱이나 사용자가 형식을 틀려도 파일이 깨지지 않게 하기 위함입니다.
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
        else:  # enum, tuple 은 원문 그대로 사용
            formatted = unquote(newv) if t == "enum" else newv

        if formatted != current[k]:
            changes.append((k, current[k], formatted))
            current[k] = formatted

    sys.exit(commit_changes(changes))

# ------------------------------------------------------------------ 기본값 복구
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
        # 지정한 항목만 복구 (운영 항목이라도 명시했으면 존중합니다)
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
    # 실행 중이면 재시작해야 반영된다는 점을 분명히 알립니다.
    if is_running; then
      warn "서버가 실행 중입니다. 변경된 설정은 재시작 후에 적용됩니다."
      printf '    ./auto_restart.sh    (백업 후 안전하게 재시작)\n'
    fi
    ;;
  -h|--help) sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//' ;;
  *) die "알 수 없는 옵션: $MODE (--json | --get | --set | --diff | --reset)" ;;
esac
