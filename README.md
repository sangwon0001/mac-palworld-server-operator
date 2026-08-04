# Palworld Dedicated Server on macOS (Apple Silicon, Docker 없이)

Apple Silicon 맥북 호스트에서 **Rosetta 2 + Wine 호환 레이어**로 팰월드 전용 서버를
구동·관리하는 스크립트 세트입니다. 가상화(Docker/UTM) 없이 호스트에서 직접 돌립니다.

---

## ⚠️ 먼저 알아야 할 현실적 제약

1. **팰월드는 macOS용 서버 빌드를 제공하지 않습니다.** Windows 빌드를 SteamCMD로 받아
   Wine으로 구동하는 방식이며, Wine은 Rosetta 2 위에서 x86_64로 동작합니다.
   즉 **번역 레이어가 2겹**(Wine: Win32 API → macOS, Rosetta: x86_64 → ARM64)입니다.
2. UE5 데디케이티드 서버라 **크래시·성능 저하 가능성이 실재**합니다. 4~8인 소규모는
   대체로 견디지만, 대규모 인원이나 거대 베이스에서는 불안정할 수 있습니다.
3. **Box64는 해당 없습니다** (ARM Linux용). **Whisky는 개발 중단**되어 제외했습니다.
   또한 공식 WineHQ cask(`wine-stable`, `wine@devel`, `wine@staging`)는 macOS
   Gatekeeper 검사를 통과하지 못해 deprecated 상태이며 **2026-09-01에 비활성화**됩니다.
   → 무료로는 **Gcenx 재패키징 Game Porting Toolkit cask**가 현재 유일하게 깔끔한 경로입니다.
4. 이 스크립트들은 Wine 구현체에 종속되지 않게 설계했습니다. `WINE_BIN` 한 줄만
   바꾸면 어떤 호환 레이어로든 갈아탈 수 있습니다.
5. **Rosetta 2 의존은 피할 수 없습니다.** GPTK의 `wine64`도, Gcenx 순정 빌드
   (`...-osx64.tar.xz`)도, CrossOver도 전부 x86_64 바이너리이고, `PalServer.exe`
   자체가 Windows x86-64입니다. macOS에서 x86→ARM 번역기는 Rosetta 2가 유일합니다
   (리눅스의 FEX/box64 같은 대안 없음). 그래서 GPTK 설치 후
   **"Support Ending for Intel-based Apps"** 알림이 뜨는데, 이는 정상이며 어떤
   Wine을 골라도 동일하게 발생합니다.

> ### ⚠️ 운영 권고: macOS 메이저 업그레이드를 미루세요
>
> Apple은 Rosetta 2를 향후 몇 개 릴리스까지 유지한 뒤 축소할 예정이라고 밝혔습니다.
> **이 맥을 서버로 운영하는 동안 macOS 메이저 버전을 올리면 서버가 조용히 죽을 수
> 있습니다.** 업그레이드 전에는 반드시 `./backup_save.sh`로 세이브를 확보하고,
> 업그레이드 후 `./setup.sh`로 Wine 동작을 먼저 확인하세요.
>
> Rosetta가 끝나는 시점의 근본 대안은 **리눅스 네이티브 서버**입니다. App ID
> 2394010은 리눅스 뎁포를 제공하므로, 저전력 미니 PC나 VPS로 옮기면 번역 레이어
> 없이 구동됩니다. 세이브 데이터는 그대로 호환되며 `./backup_save.sh`로 만든
> tar.gz를 그쪽 `Pal/Saved/`에 풀면 됩니다(설정 파일 경로만
> `Config/WindowsServer/` → `Config/LinuxServer/`로 달라집니다).

> 안정성이 최우선이라면 저전력 미니 PC에 Linux 네이티브 서버를 올리는 편이 낫습니다.
> 이 구성은 "맥북 하나로 지인들과 돌린다"는 목적에 맞춘 것입니다.

---

## 📁 파일 구조

```
palworld-server/                     ← 스크립트 (지금 이 폴더)
├── install.sh                 ★ 원클릭 설치 프로그램 (여기서 시작)
├── config.sh                  공통 설정 + 유틸 함수 + RCON 클라이언트
├── config.local.sh.example    개인 설정 템플릿 (복사해서 사용)
├── setup.sh                   0) 사전 요구사항 점검 / 설치 안내
├── install_update.sh          1) SteamCMD 로 서버 설치·업데이트
├── start_server.sh            2) 서버 기동 (nohup / tmux / 포그라운드)
├── stop_server.sh             3) 안전 종료 (RCON → SIGINT → SIGTERM → SIGKILL)
├── backup_save.sh             4) 세이브 백업 (타임스탬프 tar.gz)
├── restore_save.sh            5) 백업 복원 / 타 서버 데이터 이사
├── status.sh                  6) PID·CPU·RAM·포트·접속자 상태 조회
├── auto_restart.sh            7) 백업 후 재시작 (메모리 누수 대응, cron 용)
├── install_cron.sh            8) crontab 자동 등록/해제
├── settings.sh                9) 게임 설정 119개 읽기/쓰기 (앱과 공용)
└── app/                      10) macOS GUI 앱 (SwiftUI)
    ├── Sources/
    │   ├── PalworldServerApp.swift   @main · 메뉴바 + 메인 창
    │   ├── ContentView.swift         대시보드 · 탭 구성
    │   ├── GameSettingsView.swift    게임 설정 편집 화면
    │   ├── SettingsCatalog.swift     119개 항목의 한글 라벨 · 분류 · 입력 범위
    │   ├── ServerController.swift    스크립트 실행 · 상태 폴링 · 설정 적용
    │   ├── RconClient.swift          네이티브 RCON (접속자 · 공지 · 강퇴 · 밴)
    │   └── Models.swift              status.sh --json 대응 모델
    └── build.sh                      Xcode 없이 .app 빌드

~/PalworldServer/                    ← 서버 본체 (자동 생성)
├── PalServer.exe
├── DefaultPalWorldSettings.ini
├── Pal/
│   ├── Binaries/Win64/PalServer-Win64-Shipping.exe
│   └── Saved/
│       ├── Config/WindowsServer/PalWorldSettings.ini   ← 서버 설정
│       └── SaveGames/0/<월드ID>/                        ← 세이브 데이터
├── logs/                      서버 로그 / 운영 로그
└── run/palserver.pid          실행 중 PID

~/palworld_backups/                  ← 백업 보관소 (자동 생성)
└── palworld_backup_YYYYMMDD_HHMMSS.tar.gz

~/.palworld_wine/                    ← Wine 프리픽스 (자동 생성)
```

---

## 🚀 설치 (권장: 원클릭)

```bash
cd ~/Projects/ys-games/palworld-server && ./install.sh
```

의존성 점검·설치 → 서버 다운로드 → 설정 생성 → GUI 앱 빌드·설치까지 한 번에
처리합니다. 주요 성질:

- **멱등성** — 이미 끝난 단계는 건너뜁니다. 중단 후 다시 실행해도 안전합니다.
- **비파괴** — 기존 세이브와 `AdminPassword` 가 설정된 ini 는 절대 덮어쓰지 않습니다.
- **사용자 권한 실행** — Homebrew 는 root 실행을 거부하므로 `sudo` 로 감싸지 않습니다.
  권한이 필요한 단계(Rosetta)만 개별적으로 암호를 요청합니다.

```bash
./install.sh --check     # 설치 상태만 점검 (아무것도 바꾸지 않음)
./install.sh --yes       # 확인 없이 무인 설치
./install.sh --no-app    # CLI 만 설치 (GUI 앱 건너뜀)
```

> **`.pkg` 를 쓰지 않은 이유**: `.pkg` 의 postinstall 은 root 로 실행되는데
> Homebrew 는 root 실행을 거부합니다. 또 5.6GB 다운로드를 설치 마법사 안에 넣으면
> 진행률이 보이지 않고 중단 시 복구도 어렵습니다. GUI 앱만 담은 드래그 앤 드롭
> `.dmg` 도 적절치 않은데, 앱은 이 폴더의 셸 스크립트를 실행하는 구조라
> 앱만 옮기면 동작하지 않기 때문입니다.

---

## 🔧 수동 설치 (단계별)

`install.sh` 가 하는 일을 직접 확인하며 진행하고 싶을 때 씁니다.

### 0단계 — 실행 권한 부여

```bash
cd ~/Projects/ys-games/palworld-server && chmod +x *.sh
```

### 1단계 — 사전 요구사항 점검

```bash
./setup.sh
```

Homebrew / Rosetta 2 / SteamCMD / Wine 설치 여부를 확인하고, 빠진 항목의 설치 명령을
안내합니다. Rosetta와 SteamCMD는 자동 설치할 수 있습니다:

```bash
./setup.sh --install
```

Wine은 용량이 크고 선택지가 갈려 자동 설치하지 않습니다. **무료 권장 경로**는 다음과 같습니다.

```bash
brew tap gcenx/wine && brew install --cask game-porting-toolkit
```

Gcenx가 재패키징한 무료 배포판으로, Apple 개발자 계정·Xcode·x86_64 Homebrew 모두
필요 없습니다. 설치 과정에서 quarantine 속성을 제거하고 ad-hoc 코드서명을 다시 하기
때문에, 공식 WineHQ cask들을 막아버린 Gatekeeper 문제를 피해 갑니다.
`wine64`/`wineserver`를 brew bin에 링크하므로 `detect_wine()`이 자동으로 잡습니다.

유료 대안은 CrossOver입니다(연 구독, 14일 체험판). 서버 성능 자체는 위와 동일하며,
상용 지원과 GUI 관리 도구가 필요할 때만 의미가 있습니다.

```bash
brew install --cask crossover
```

둘 다 실패하면 [Gcenx/macOS_Wine_builds](https://github.com/Gcenx/macOS_Wine_builds/releases)에서
`wine-staging-<버전>-osx64.tar.xz`를 직접 받아 압축을 풀고
`xattr -drs com.apple.quarantine <경로>`를 실행한 뒤 `WINE_BIN`을 지정하세요.

설치 후 경로를 개인 설정에 기록합니다:

```bash
cp config.local.sh.example config.local.sh && open -e config.local.sh
```

`WINE_BIN`과 `RCON_PASSWORD`를 채우세요. RCON 비밀번호는 **안전 종료의 핵심**이라
꼭 설정하는 것을 권장합니다(미설정 시 시그널 종료로 대체됩니다).

### 2단계 — 서버 설치

```bash
./install_update.sh
```

App ID `2394010`의 Windows 뎁포를 `~/PalworldServer`에 내려받습니다.
핵심은 `+@sSteamCmdForcePlatformType windows` 옵션 — 이게 없으면 macOS에서
"해당 플랫폼 빌드 없음"으로 실패합니다. 파일이 손상됐을 때는:

```bash
./install_update.sh --validate
```

### 3단계 — 서버 설정 편집

```bash
open -e ~/PalworldServer/Pal/Saved/Config/WindowsServer/PalWorldSettings.ini
```

RCON을 쓰려면 `OptionSettings=(...)` 안에서 아래 값을 수정하세요.

| 항목 | 값 | 설명 |
|---|---|---|
| `ServerName` | `"내 서버"` | 서버 목록 표시 이름 |
| `AdminPassword` | `"강한비밀번호"` | RCON 인증에 사용 (필수) |
| `RCONEnabled` | `True` | 안전 종료 기능의 전제 |
| `RCONPort` | `25575` | `config.local.sh`의 `RCON_PORT`와 일치 |
| `PublicPort` | `8211` | 게임 포트 |
| `ServerPassword` | `""` | 비우면 누구나 접속 가능 |

`AdminPassword`는 `config.local.sh`의 `RCON_PASSWORD`와 **반드시 같은 값**이어야 합니다.

### 4단계 — 서버 기동

```bash
./start_server.sh
```

nohup 백그라운드로 띄우고 PID를 기록한 뒤, UDP 8211이 실제로 바인딩될 때까지
최대 120초 대기하며 확인합니다. 콘솔을 직접 보고 싶으면:

```bash
./start_server.sh --tmux
```

이후 `tmux attach -t palworld`로 붙고 `Ctrl-b d`로 빠져나옵니다.
기동이 실패한다면 포그라운드로 원인을 확인하세요:

```bash
./start_server.sh --fg
```

### 5단계 — 상태 확인

```bash
./status.sh
```

PID, CPU 점유율, RSS 메모리(누수 감시용 경고 포함), 가동 시간, UDP 8211 바인딩 여부,
RCON 접속자 목록, 세이브 크기, 백업 현황을 한 화면에 보여줍니다.

```bash
./status.sh --watch
```

### 6단계 — 서버 종료

```bash
./stop_server.sh
```

**RCON `Save` → `Shutdown` → SIGINT → SIGTERM → SIGKILL** 순으로 단계적으로
시도합니다. 앞 단계가 성공하면 뒤 단계는 실행하지 않습니다. RCON 경로가 세이브
유실 위험이 가장 낮으므로 `RCON_PASSWORD` 설정을 권장합니다.

```bash
./stop_server.sh --now      # 예고 없이 즉시 저장 후 종료
./stop_server.sh --force    # 응답 없는 프로세스 강제 정리 (세이브 손상 위험)
```

---

## 🖥️ macOS 앱으로 제어하기

터미널 대신 GUI로 쓰고 싶다면 `app/` 의 SwiftUI 앱을 빌드하세요. **Xcode 없이**
Command Line Tools의 `swiftc` 만으로 빌드됩니다.

```bash
cd app && ./build.sh --install
```

`--install` 은 `/Applications` 에 설치합니다. `--run` 은 빌드 후 바로 실행,
옵션 없이 실행하면 `app/build/` 에만 만듭니다.

### 설계

앱은 **서버 제어 로직을 전혀 갖고 있지 않습니다.** 버튼을 누르면 이 폴더의
`.sh` 스크립트를 그대로 실행할 뿐입니다. 덕분에

- 앱에서 한 동작과 터미널에서 한 동작이 완전히 동일합니다.
- cron 자동화는 앱과 무관하게 계속 돕니다.
- 앱을 지워도 서버 운영에 아무 지장이 없습니다.

상태 표시는 `./status.sh --json` 의 기계용 출력을 읽습니다(사람용 출력은 색코드가
섞여 파싱이 취약하므로 분리했습니다).

### 기능

| 화면 | 내용 |
|---|---|
| 메뉴 막대 | 상태 아이콘, CPU/RAM/접속자 요약, 시작·종료·재시작·백업 |
| 메인 창 상단 | 상태 표시등(정지/기동 중/실행 중), PID, 가동 시간, 포트 |
| 지표 카드 | CPU, 메모리(누수 임계치 도달 시 주황/빨강 경고), 접속자, 세이브 크기, 포트/RCON 상태 |
| 제어 | 시작 / 안전 종료 / 재시작 / 지금 백업 (실행 중에는 버튼 비활성화) |
| 백업 | 최근 백업 목록과 복원 (서버 실행 중에는 복원 차단, 실행 전 확인 대화상자) |
| 실행 로그 | 스크립트 출력 실시간 스트리밍 |
| **접속자** | 실시간 목록, 강퇴 · 밴, 전체 공지, 즉시 저장 |
| **게임 설정** | 119개 설정 항목 편집 (아래 참고) |

상태는 3초마다 갱신됩니다.

### 접속자 관리와 네이티브 RCON

접속자 조회·공지·강퇴·밴은 앱이 **Swift 로 직접 구현한 RCON 클라이언트**로 처리합니다
(`app/Sources/RconClient.swift`). 셸 스크립트를 거치지 않는 이유는 속도입니다.

| 경로 | 왕복 시간 |
|---|---|
| 셸 경유 (`bash` + `python3` 기동) | 약 260ms |
| 네이티브 Swift | **약 36ms** |

3초마다 도는 폴링에서 매번 파이썬 인터프리터를 새로 띄우는 건 순수 낭비라,
`status.sh` 는 `--no-rcon` 으로 호출해 프로세스 지표만 받고(0.39초 → 0.14초)
접속자는 네이티브로 조회합니다.

**단, 서버 생명주기는 여전히 스크립트가 담당합니다.** RCON 으로는 꺼진 서버를 켤 수
없고, CPU/RAM/PID 같은 프로세스 지표나 백업·복원·설정 파일도 다룰 수 없습니다.
무엇보다 `stop_server.sh` 의 4단계 폴백(RCON→SIGINT→SIGTERM→SIGKILL)은 RCON 이
먹통일 때를 위한 안전장치라, 앱이 RCON 만으로 흉내 내면 안 됩니다.

> ### ⚠️ 팰월드 서버의 비ASCII 처리 버그
>
> 응답 본문에 한글 등 비ASCII 가 섞이면 서버가 **실제 전송량보다 큰 길이**를 헤더에
> 적어 보내고, 본문 자체도 잘라 보냅니다.
>
> ```
> Info         선언 74 / 실제 58   ⚠   Save         선언 24 / 실제 24  ✔
> Broadcast    선언 54 / 실제 39   ⚠   ShowPlayers  선언 33 / 실제 33  ✔
> ```
>
> 선언 길이를 그대로 믿고 기다리면 오지 않는 바이트를 기다리다 타임아웃이 납니다
> (실측 5초). **한글 닉네임 플레이어가 접속하면 `ShowPlayers` 가 여기에 걸립니다.**
>
> 두 클라이언트(Swift·셸) 모두 선언 길이를 상한으로만 쓰고 패킷 종단(`00 00`)을
> 만나면 즉시 끝내도록 고쳤습니다. 잘린 응답도 종단은 정상적으로 붙여 보내기
> 때문입니다.
>
> 다만 **본문이 잘려 오는 것 자체는 서버 쪽 문제라 고칠 수 없습니다.** 공지는
> 영문·숫자로 쓰는 편이 확실합니다. (공백은 밑줄로 자동 치환됩니다 — 팰월드 RCON 이
> 공백을 인자 구분자로 취급하기 때문입니다.)

### 게임 설정 편집

메인 창의 **게임 설정** 탭에서 `PalWorldSettings.ini` 의 119개 항목을 전부 편집할
수 있습니다.

- **8개 분류** — 서버 / 게임플레이 / 팰 / 플레이어 / 채집·제작 / 베이스캠프·길드 /
  PvP / 기타. 119개 모두에 한글 라벨과 키 이름이 함께 표시됩니다.
- **자료형별 컨트롤** — 참/거짓은 스위치, 배율은 슬라이더 + 숫자 입력,
  난이도·사망 패널티 등은 선택 목록, 비밀번호는 가림 입력.
- **검색** — 한글 이름이나 키 이름으로 바로 찾습니다.
- **모아서 적용** — 편집 즉시 저장하지 않고 변경분을 모았다가 [적용] 시 한 번에
  씁니다. 무엇이 바뀔지 확인 후 적용하며, [되돌리기] 로 버릴 수 있습니다.
- 서버가 실행 중이면 **재시작해야 반영된다는 경고**가 표시됩니다.

CLI로도 같은 작업을 할 수 있습니다.

```bash
./settings.sh --json                    # 전체를 JSON 으로 (앱이 쓰는 것과 동일)
./settings.sh --get ExpRate             # 값 하나 조회
./settings.sh --diff                    # 기본값과 다른 항목만 표시
./settings.sh --set ExpRate=2.0 Difficulty=Casual ServerName="내 서버"
```

> **안전 설계**: 설정 파일 전체를 다시 쓰지 않고 **요청받은 키만 정밀 치환**합니다.
> 전체 재직렬화 방식은 게임 업데이트로 새 항목이 추가됐을 때 우리가 모르는 값을
> 유실시킬 수 있기 때문입니다. 쓰기 전 `PalWorldSettings.ini.bak_<타임스탬프>` 로
> 자동 백업하며, 값의 자료형이 맞지 않으면(예: 숫자 자리에 문자) 파일을 건드리지
> 않고 거부합니다.
>
> `AdminPassword` 를 앱에서 바꾸면 `config.local.sh` 의 `RCON_PASSWORD` 도 같은 값으로
> 바꿔야 안전 종료가 계속 동작합니다.

### 알아둘 점

- 서버는 `nohup` 으로 **launchd에 분리**되므로, 앱을 종료해도 서버는 계속 돕니다.
  (검증: 서버 프로세스의 `PPID = 1`)
- GUI 앱은 로그인 셸을 거치지 않아 `PATH` 가 최소입니다. 앱이 `wine64`/`lsof`/
  `python3` 를 찾을 수 있도록 `PATH` 를 명시적으로 주입합니다.
- 서명은 ad-hoc 입니다. 로컬 빌드라 quarantine 속성이 붙지 않아 Gatekeeper 경고
  없이 실행되지만, 이 `.app` 을 **다른 맥으로 복사하면** 경고가 뜹니다.
  그때는 받는 쪽에서 `xattr -dr com.apple.quarantine "/Applications/Palworld 서버.app"`.
- 스크립트 폴더 위치는 빌드 시 `Info.plist` 에 기록되며, 앱의 설정(⚙️)에서 바꿀 수
  있습니다. 스크립트 폴더를 옮겼다면 여기서 새 경로를 지정하세요.

---

## 💾 백업과 복원

### 백업

```bash
./backup_save.sh
```

- 서버가 켜져 있으면 **RCON `Save`로 메모리의 진행분을 먼저 디스크에 플러시**한 뒤 압축합니다.
- `Pal/Saved/SaveGames/0/` + `PalWorldSettings.ini`를
  `~/palworld_backups/palworld_backup_YYYYMMDD_HHMMSS.tar.gz`로 저장합니다.
- 생성 직후 `tar -tzf`로 **무결성을 검증**합니다. 깨진 아카이브는 즉시 삭제합니다.
- 보존 정책: 14일 초과분 삭제, 단 최신 10개는 무조건 보존.

```bash
./backup_save.sh --list     # 백업 목록
```

### 복원

```bash
./stop_server.sh            # 반드시 서버를 먼저 끕니다
./restore_save.sh --latest  # 가장 최근 백업으로
./restore_save.sh palworld_backup_20260804_050000.tar.gz   # 특정 시점으로
```

복원 직전 현재 상태를 `prerestore_*.tar.gz`로 자동 스냅샷하므로,
잘못 복원해도 되돌아갈 수 있습니다.

### 타 서버에서 이사 오기

다른 서버(윈도우 PC, 호스팅 업체, 리눅스)에서 받은 `Saved` 폴더가 있다면:

```bash
./stop_server.sh
./restore_save.sh --import ~/Downloads/Saved
```

`Saved`, `Saved/SaveGames/0`, `0` 중 어느 경로를 지정해도 알아서 찾아 배치합니다.
최종 배치 위치는 다음과 같습니다.

```
~/PalworldServer/Pal/Saved/SaveGames/0/<월드ID>/
├── Level.sav          월드·베이스·팰 데이터
├── LevelMeta.sav
├── WorldOption.sav
└── Players/
    └── <플레이어UID>.sav
```

수동으로 옮기고 싶다면:

```bash
cp -R ~/Downloads/Saved/SaveGames/0/* ~/PalworldServer/Pal/Saved/SaveGames/0/
```

> **주의 1**: 월드 ID 폴더명(랜덤 16진수)은 **원본 그대로 유지**해야 합니다.
> 이름을 바꾸면 서버가 새 월드로 인식합니다.
>
> **주의 2**: `SaveGames/0/` 아래에 월드 폴더가 **여러 개**면 서버가 어느 것을 쓸지
> 모호해집니다. `PalWorldSettings.ini`의 `DedicatedServerName`에 사용할 월드 ID를
> 명시하거나, 쓰지 않는 폴더는 다른 곳으로 옮기세요.
>
> **주의 3**: 리눅스 서버에서 가져온 세이브는 그대로 호환되지만, 설정 파일 경로는
> `Config/LinuxServer/` → `Config/WindowsServer/`로 달라집니다.

---

## 🔄 메모리 누수 대응 자동 재시작

팰월드 서버는 장시간 가동 시 RSS가 계속 증가하는 알려진 문제가 있습니다.
`auto_restart.sh`는 **백업 → 안전 종료 → (선택)업데이트 → 재기동 → 검증** 순으로
처리하며, **백업이 실패하면 재시작을 중단**합니다.

```bash
./auto_restart.sh                    # 무조건 재시작
./auto_restart.sh --if-over 8192     # RSS 8GB 초과일 때만
./auto_restart.sh --if-empty         # 접속자 0명일 때만 (RCON 필요)
./auto_restart.sh --update           # 재시작하는 김에 서버 업데이트도
./auto_restart.sh --if-over 8192 --if-empty --update   # 조합 가능
```

서버가 이미 죽어 있으면 재시작 대신 **복구 기동**을 수행하므로,
크래시 감시용으로도 쓸 수 있습니다.

### cron 등록

```bash
./install_cron.sh --show      # 등록될 내용 미리보기
./install_cron.sh --install   # 등록
./install_cron.sh --remove    # 해제
```

기본 스케줄:

| 시각 | 동작 |
|---|---|
| 매시 정각 | 세이브 백업 |
| 매일 05:00 | 백업 + 재시작 |
| 매일 06:00 | RSS 8GB 초과 & 접속자 0명일 때만 재시작 |

> **macOS 필수 설정**: cron이 홈 디렉터리에 접근하려면 권한이 필요합니다.
> 시스템 설정 → 개인정보 보호 및 보안 → **전체 디스크 접근 권한** → `/usr/sbin/cron` 추가
> (Finder에서 `Cmd+Shift+G` → `/usr/sbin` → `cron`을 드래그)
>
> 이 설정을 빠뜨리면 cron 작업이 조용히 실패합니다. 등록 후 `~/PalworldServer/logs/cron.log`로
> 실제 동작을 반드시 확인하세요.

---

## 🌐 접속 주소와 외부 접속 설정

지인들에게 알려 줄 주소는 아래 명령으로 한 번에 확인합니다. 앱의 대시보드
**접속 주소** 카드에서도 복사 버튼과 함께 볼 수 있습니다.

```bash
./status.sh --address
```

```
접속 주소
  같은 공유기 안 : 192.168.50.32:8211
  같은 공유기 안 : Sangwons-MacBook-Pro.local:8211  (IP 가 바뀌어도 유지됨)
  외부(인터넷)   : 203.0.113.10:8211
                   공유기에서 UDP 8211 포트포워딩이 되어 있어야 합니다
```

> **`.local` 주소를 권합니다.** 내부 IP는 DHCP 임대가 갱신되거나 다른 공유기에
> 물리면 바뀝니다(이 프로젝트를 만드는 중에도 `192.168.70.138` → `192.168.50.32`로
> 바뀌었습니다). mDNS 호스트명은 같은 망에 있는 한 계속 통하므로 한 번 알려 주면
> 끝입니다.
>
> 공인 IP는 외부 서비스(api.ipify.org)에 요청이 나가므로 **자동으로 조회하지
> 않습니다.** `--address` 를 실행하거나 앱에서 [공인 IP 조회]를 눌렀을 때만
> 가져옵니다.

1. **공유기 포트포워딩**: `UDP 8211` → 맥북의 내부 IP
2. **맥북 IP 고정**: 공유기 DHCP 예약 또는 수동 IP 설정 (재부팅 시 IP가 바뀌면 접속 불가)
3. **macOS 방화벽**: 시스템 설정 → 네트워크 → 방화벽이 켜져 있다면 Wine 프로세스의
   수신 연결을 허용해야 합니다.
4. **절전 방지**: 맥북 뚜껑을 덮거나 잠들면 서버가 멈춥니다.
   ```bash
   caffeinate -dimsu &
   ```
   또는 시스템 설정 → 배터리 → "디스플레이가 꺼져 있을 때 자동으로 잠자기 방지" 활성화.
   (전원 어댑터 연결 상태 권장)

---

## 🔧 문제 해결

| 증상 | 확인할 것 |
|---|---|
| `Wine을 찾지 못했습니다` | `config.local.sh`에 `WINE_BIN` 절대경로 지정 |
| SteamCMD가 플랫폼 오류 | `+@sSteamCmdForcePlatformType windows`가 `+login`보다 앞에 있는지 |
| 기동 후 포트가 안 열림 | `./start_server.sh --fg`로 포그라운드 실행해 Wine 오류 직접 확인 |
| 즉시 크래시 | `./install_update.sh --validate`로 파일 무결성 검증 |
| RCON 인증 실패 | `AdminPassword`(ini)와 `RCON_PASSWORD`(config.local.sh) 일치 여부, `RCONEnabled=True` |
| 다음 기동이 실패 | 유령 프로세스 잔존 → `./stop_server.sh --force` |
| cron이 안 돎 | `/usr/sbin/cron`에 전체 디스크 접근 권한 부여, `logs/cron.log` 확인 |
| 세이브가 안 보임 | 월드 ID 폴더명이 원본과 같은지, `SaveGames/0/`에 폴더가 하나뿐인지 |

로그 위치:

```bash
tail -f ~/PalworldServer/logs/palserver.log      # 서버 로그
tail -f ~/PalworldServer/logs/auto_restart.log   # 자동 재시작 로그
tail -f ~/PalworldServer/logs/operations.log     # 운영 감사 로그
```
