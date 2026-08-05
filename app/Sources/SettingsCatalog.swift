import Foundation

/// A single entry from `settings.sh --json`.
struct GameSetting: Identifiable, Equatable {
    var id: String { key }
    let key: String
    let type: String        // bool | float | int | string | enum | tuple
    let raw: String
    var value: String
    let defaultValue: String?
    let modified: Bool
}

/// Presentation metadata for a setting.
///
/// Palworld exposes 119 settings and many key names are opaque on their own. Common
/// ones get a label, a description and an input range; the rest surface under "Other"
/// with their raw key name. A new key introduced by a game update shows up there
/// automatically and stays editable.
///
/// Labels are stored in Korean because they double as translation keys — see
/// Localization.swift. They are translated at the point of display.
struct SettingMeta {
    let label: String
    let category: Category
    var help: String? = nil
    var range: ClosedRange<Double>? = nil
    var options: [String]? = nil

    enum Category: String, CaseIterable {
        case server     = "서버"
        case gameplay   = "게임플레이"
        case pal        = "팰"
        case player     = "플레이어"
        case gather     = "채집 · 제작"
        case base       = "베이스캠프 · 길드"
        case pvp        = "PvP"
        case other      = "기타"

        var icon: String {
            switch self {
            case .server:   return "server.rack"
            case .gameplay: return "gamecontroller"
            case .pal:      return "pawprint"
            case .player:   return "person"
            case .gather:   return "hammer"
            case .base:     return "house"
            case .pvp:      return "figure.fencing"
            case .other:    return "ellipsis.circle"
            }
        }
    }
}

enum SettingsCatalog {

    /// Default range for rate-style values (0.1x – 5x)
    private static let rate: ClosedRange<Double> = 0.1...5.0

    static let meta: [String: SettingMeta] = [
        // ───────────────────────────────────────────────────── Server
        "ServerName": .init(label: "서버 이름", category: .server,
                            help: "서버 목록에 표시되는 이름"),
        "ServerDescription": .init(label: "서버 설명", category: .server),
        "ServerPassword": .init(label: "접속 비밀번호", category: .server,
                                help: "비워 두면 누구나 접속할 수 있습니다"),
        "AdminPassword": .init(label: "관리자 비밀번호", category: .server,
                               help: "RCON 인증에 사용됩니다. 바꾸면 config.local.sh 의 RCON_PASSWORD 도 함께 바꿔야 합니다"),
        "ServerPlayerMaxNum": .init(label: "최대 접속 인원", category: .server,
                                    help: "데디케이티드 서버가 실제로 사용하는 정원입니다 (CoopPlayerMaxNum 아님)",
                                    range: 1...32),
        "PublicPort": .init(label: "게임 포트", category: .server,
                            help: "바꾸면 공유기 포트포워딩도 함께 바꿔야 합니다"),
        "PublicIP": .init(label: "공개 IP", category: .server, help: "보통 비워 둡니다"),
        "RCONEnabled": .init(label: "RCON 사용", category: .server,
                             help: "끄면 안전 종료가 시그널 방식으로 대체됩니다. 켜 두기를 권장합니다"),
        "RCONPort": .init(label: "RCON 포트", category: .server),
        "RESTAPIEnabled": .init(label: "REST API 사용", category: .server),
        "RESTAPIPort": .init(label: "REST API 포트", category: .server),
        "Region": .init(label: "지역", category: .server),
        "bUseAuth": .init(label: "인증 사용", category: .server),
        "bShowPlayerList": .init(label: "플레이어 목록 공개", category: .server),
        "ChatPostLimitPerMinute": .init(label: "분당 채팅 제한", category: .server),
        "CrossplayPlatforms": .init(label: "크로스플레이 플랫폼", category: .server),
        "LogFormatType": .init(label: "로그 형식", category: .server, options: ["Text", "Json"]),
        // The next two are for hosting a co-op world from the game client; a
        // dedicated server ignores them. The bare labels invite the misreading
        // "do I need this on for multiplayer?", hence the explicit help text.
        // Evidence: Pocketpair ships bIsMultiplay=False in the dedicated server
        // package, and capacity comes from ServerPlayerMaxNum (32), not
        // CoopPlayerMaxNum (4).
        "bIsMultiplay": .init(label: "코옵 호스팅 모드 (서버 무관)", category: .server,
                              help: "게임 클라이언트로 직접 호스팅할 때 쓰는 값입니다. "
                                  + "데디케이티드 서버는 무시하므로 False 그대로 두세요. "
                                  + "멀티플레이는 이 값과 무관하게 이미 됩니다."),
        "bEnableVoiceChat": .init(label: "음성 채팅", category: .server),

        // ───────────────────────────────────────────────── Gameplay
        "Difficulty": .init(label: "난이도", category: .gameplay,
                            options: ["None", "Casual", "Normal", "Hard"]),
        "DayTimeSpeedRate": .init(label: "낮 시간 배속", category: .gameplay, range: rate),
        "NightTimeSpeedRate": .init(label: "밤 시간 배속", category: .gameplay, range: rate),
        "ExpRate": .init(label: "경험치 배율", category: .gameplay, range: 0.1...20.0),
        "DeathPenalty": .init(label: "사망 패널티", category: .gameplay,
                              help: "None=없음 · Item=아이템만 · ItemAndEquipment=장비 포함 · All=팰까지",
                              options: ["None", "Item", "ItemAndEquipment", "All"]),
        "bEnableFastTravel": .init(label: "빠른 이동", category: .gameplay),
        "bEnableFastTravelOnlyBaseCamp": .init(label: "빠른 이동은 베이스캠프만", category: .gameplay),
        "bIsStartLocationSelectByMap": .init(label: "시작 위치 직접 선택", category: .gameplay),
        "bEnableInvaderEnemy": .init(label: "습격 이벤트", category: .gameplay),
        "bHardcore": .init(label: "하드코어", category: .gameplay),
        "bPalLost": .init(label: "사망 시 팰 소실", category: .gameplay),
        "AutoSaveSpan": .init(label: "자동 저장 주기(초)", category: .gameplay, range: 30...600),
        "bIsUseBackupSaveData": .init(label: "게임 자체 백업 사용", category: .gameplay),
        "SupplyDropSpan": .init(label: "보급 상자 주기(분)", category: .gameplay),
        "bEnableNonLoginPenalty": .init(label: "미접속 패널티", category: .gameplay),
        "EnablePredatorBossPal": .init(label: "포식자 보스 팰", category: .gameplay),
        "bCharacterRecreateInHardcore": .init(label: "하드코어 캐릭터 재생성", category: .gameplay),
        "bExistPlayerAfterLogout": .init(label: "로그아웃 후 캐릭터 잔류", category: .gameplay),
        "bActiveUNKO": .init(label: "배설물 활성화", category: .gameplay),
        "RandomizerType": .init(label: "랜덤라이저 방식", category: .gameplay,
                                options: ["None", "Region", "All"]),
        "RandomizerSeed": .init(label: "랜덤라이저 시드", category: .gameplay),
        "bIsRandomizerPalLevelRandom": .init(label: "랜덤라이저: 팰 레벨 무작위", category: .gameplay),
        "BlockRespawnTime": .init(label: "리스폰 대기 시간(초)", category: .gameplay),
        "RespawnPenaltyDurationThreshold": .init(label: "리스폰 패널티 기준", category: .gameplay),
        "RespawnPenaltyTimeScale": .init(label: "리스폰 패널티 배율", category: .gameplay, range: rate),

        // ───────────────────────────────────────────────────────── Pals
        "PalCaptureRate": .init(label: "포획 확률 배율", category: .pal, range: rate),
        "PalSpawnNumRate": .init(label: "팰 출현 수 배율", category: .pal, range: rate),
        "PalDamageRateAttack": .init(label: "팰 공격력 배율", category: .pal, range: rate),
        "PalDamageRateDefense": .init(label: "팰 방어력 배율", category: .pal, range: rate),
        "PalStomachDecreaceRate": .init(label: "팰 허기 감소 배율", category: .pal, range: rate),
        "PalStaminaDecreaceRate": .init(label: "팰 스태미나 감소 배율", category: .pal, range: rate),
        "PalAutoHPRegeneRate": .init(label: "팰 체력 회복 배율", category: .pal, range: rate),
        "PalAutoHpRegeneRateInSleep": .init(label: "팰 수면 중 회복 배율", category: .pal, range: rate),
        "PalEggDefaultHatchingTime": .init(label: "알 부화 시간(시간)", category: .pal, range: 0...72),
        "MonsterFarmActionSpeedRate": .init(label: "팰 목장 생산 배율", category: .pal, range: rate),
        "bAllowGlobalPalboxExport": .init(label: "글로벌 팰박스 내보내기", category: .pal),
        "bAllowGlobalPalboxImport": .init(label: "글로벌 팰박스 가져오기", category: .pal),

        // ─────────────────────────────────────────────────── Player
        "PlayerDamageRateAttack": .init(label: "플레이어 공격력 배율", category: .player, range: rate),
        "PlayerDamageRateDefense": .init(label: "플레이어 방어력 배율", category: .player, range: rate),
        "PlayerStomachDecreaceRate": .init(label: "허기 감소 배율", category: .player, range: rate),
        "PlayerStaminaDecreaceRate": .init(label: "스태미나 감소 배율", category: .player, range: rate),
        "PlayerAutoHPRegeneRate": .init(label: "체력 회복 배율", category: .player, range: rate),
        "PlayerAutoHpRegeneRateInSleep": .init(label: "수면 중 회복 배율", category: .player, range: rate),
        "ItemWeightRate": .init(label: "아이템 무게 배율", category: .player, range: rate),
        "bAllowEnhanceStat_Health": .init(label: "스탯 강화: 체력", category: .player),
        "bAllowEnhanceStat_Attack": .init(label: "스탯 강화: 공격", category: .player),
        "bAllowEnhanceStat_Stamina": .init(label: "스탯 강화: 스태미나", category: .player),
        "bAllowEnhanceStat_Weight": .init(label: "스탯 강화: 무게", category: .player),
        "bAllowEnhanceStat_WorkSpeed": .init(label: "스탯 강화: 작업 속도", category: .player),

        // ────────────────────────────────────────────────── Gathering & Crafting
        "CollectionDropRate": .init(label: "채집 획득량 배율", category: .gather, range: rate),
        "CollectionObjectHpRate": .init(label: "채집물 내구도 배율", category: .gather, range: rate),
        "CollectionObjectRespawnSpeedRate": .init(label: "채집물 재생성 배율", category: .gather, range: rate),
        "EnemyDropItemRate": .init(label: "적 드랍 배율", category: .gather, range: rate),
        "WorkSpeedRate": .init(label: "작업 속도 배율", category: .gather, range: rate),
        "DropItemMaxNum": .init(label: "월드 드랍 최대 수", category: .gather),
        "DropItemAliveMaxHours": .init(label: "드랍 유지 시간(시간)", category: .gather, range: 0...24),
        "EquipmentDurabilityDamageRate": .init(label: "장비 내구도 소모 배율", category: .gather, range: rate),
        "ItemCorruptionMultiplier": .init(label: "아이템 부패 배율", category: .gather, range: rate),

        // ────────────────────────────────────────── Base Camp & Guild
        "BaseCampMaxNum": .init(label: "베이스캠프 최대 수", category: .base),
        "BaseCampWorkerMaxNum": .init(label: "캠프당 팰 배치 수", category: .base, range: 1...50),
        "BaseCampMaxNumInGuild": .init(label: "길드당 캠프 수", category: .base, range: 1...10),
        "GuildPlayerMaxNum": .init(label: "길드 최대 인원", category: .base, range: 1...100),
        "CoopPlayerMaxNum": .init(label: "코옵 정원 (서버 무관)", category: .server,
                                  help: "클라이언트 코옵 전용 정원입니다. 데디케이티드 서버의 "
                                      + "정원은 '최대 접속 인원'(ServerPlayerMaxNum) 이 결정합니다.",
                                  range: 1...32),
        "BuildObjectHpRate": .init(label: "건축물 내구도 배율", category: .base, range: rate),
        "BuildObjectDamageRate": .init(label: "건축물 피해 배율", category: .base, range: rate),
        "BuildObjectDeteriorationDamageRate": .init(label: "건축물 노후화 배율", category: .base, range: rate),
        "bBuildAreaLimit": .init(label: "건축 범위 제한", category: .base),
        "MaxBuildingLimitNum": .init(label: "건축물 최대 수", category: .base),
        "bAutoResetGuildNoOnlinePlayers": .init(label: "무접속 길드 자동 해체", category: .base),
        "AutoResetGuildTimeNoOnlinePlayers": .init(label: "길드 해체 기준(시간)", category: .base),
        "GuildRejoinCooldownMinutes": .init(label: "길드 재가입 쿨다운(분)", category: .base),

        // ───────────────────────────────────────────────────────── PvP
        "bIsPvP": .init(label: "PvP 사용", category: .pvp),
        "bEnablePlayerToPlayerDamage": .init(label: "플레이어 간 피해", category: .pvp),
        "bEnableFriendlyFire": .init(label: "아군 피해", category: .pvp),
        "bEnableDefenseOtherGuildPlayer": .init(label: "타 길드원 방어", category: .pvp),
        "bCanPickupOtherGuildDeathPenaltyDrop": .init(label: "타 길드 드랍 습득", category: .pvp),
        "bAdditionalDropItemWhenPlayerKillingInPvPMode":
            .init(label: "PvP 처치 시 추가 드랍", category: .pvp),
        "AdditionalDropItemNumWhenPlayerKillingInPvPMode":
            .init(label: "PvP 추가 드랍 개수", category: .pvp),
        "AdditionalDropItemWhenPlayerKillingInPvPMode":
            .init(label: "PvP 추가 드랍 종류", category: .pvp),
        "bDisplayPvPItemNumOnWorldMap_BaseCamp":
            .init(label: "지도에 PvP 아이템 수 표시(캠프)", category: .pvp),
        "bDisplayPvPItemNumOnWorldMap_Player":
            .init(label: "지도에 PvP 아이템 수 표시(플레이어)", category: .pvp),

        // ─────────────────────────────────────────────── Everything else
        "bAllowClientMod": .init(label: "클라이언트 모드 허용", category: .server),
        "BanListURL": .init(label: "밴 목록 URL", category: .server),
        "bIsShowJoinLeftMessage": .init(label: "접속/퇴장 메시지 표시", category: .server),
        "bEnableAimAssistPad": .init(label: "에임 어시스트(패드)", category: .player),
        "bEnableAimAssistKeyboard": .init(label: "에임 어시스트(키보드)", category: .player),
        "PhysicsActiveDropItemMaxNum": .init(label: "물리 적용 드랍 최대 수", category: .gather,
                                             help: "-1 은 무제한"),
        "DropItemMaxNum_UNKO": .init(label: "배설물 최대 수", category: .gather),
        "bInvisibleOtherGuildBaseCampAreaFX": .init(label: "타 길드 캠프 범위 숨김", category: .base),
        "bEnableBuildingPlayerUIdDisplay": .init(label: "건축물 소유자 표시", category: .base),
        "BuildingNameDisplayCacheTTLSeconds": .init(label: "건축물 이름 캐시(초)", category: .base),
        "MaxGuildsPerFrame": .init(label: "프레임당 길드 처리 수", category: .base),
        "AutoTransferMasterCheckIntervalSeconds":
            .init(label: "길드장 자동 위임 검사 주기(초)", category: .base),
        "AutoTransferMasterThresholdDays":
            .init(label: "길드장 자동 위임 기준(일)", category: .base),
        "VoiceChatMaxVolumeDistance": .init(label: "음성 최대 음량 거리", category: .server),
        "VoiceChatZeroVolumeDistance": .init(label: "음성 무음 거리", category: .server),
        "DenyTechnologyList": .init(label: "금지 기술 목록", category: .gameplay),
        "ServerReplicatePawnCullDistance":
            .init(label: "동기화 컬링 거리", category: .server,
                  help: "낮추면 서버 부하가 줄지만 먼 거리의 팰/플레이어가 늦게 보입니다"),
        "ItemContainerForceMarkDirtyInterval": .init(label: "상자 동기화 주기", category: .other),
        "PlayerDataPalStorageUpdateCheckTickInterval":
            .init(label: "팰 보관함 갱신 주기", category: .other),
    ]

    /// Entries without metadata land in "Other" and use the raw key as the label.
    static func meta(for key: String) -> SettingMeta {
        meta[key] ?? SettingMeta(label: key, category: .other)
    }

    /// Keys that would cut off access or management if reset to defaults.
    /// Excluded from bulk reset; individual reset is allowed since the user named it.
    /// (Must stay in sync with OPERATIONAL_KEYS in settings.sh.)
    static let operationalKeys: Set<String> = [
        "AdminPassword", "ServerPassword", "ServerName", "ServerDescription",
        "RCONEnabled", "RCONPort", "RESTAPIEnabled", "RESTAPIPort",
        "PublicPort", "PublicIP", "Region", "BanListURL",
    ]
}
