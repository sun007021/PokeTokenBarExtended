---
summary: Mobius(Claude·Codex 계정 전환) 기능을 PokeTokenBarExtended 에 통합하는 작업의 설계·단계·불변식.
read_when: mobius 통합 관련 코드를 만질 때, 상류(chattymin/PokeTokenBar) 변경을 가져올 때, 계정 전환·자격증명 경로를 리뷰할 때
---

# Mobius 통합 계획

이 포크는 [chussum/mobius](https://github.com/chussum/mobius) 의 Claude·Codex **계정 자동 전환**
기능을 이 앱(상류 PokeTokenBar 의 포크, 개명 후 **PokeTokenBarExtended**)에 합친다.
기존 PokeTokenBar 기능은 전부 그대로 유지한다.

## 결정 사항 (확정)

| 항목 | 결정 | 이유 |
|---|---|---|
| 산출물 | 개인 포크 (상류 PR 아님) | 상류는 "읽기 전용 관찰자" 성격이라 자격증명 변경 기능은 별도 합의가 필요 |
| 1차 범위 | 핵심 전환만 | 계정 목록·수동/자동 전환·게이지·로그인. Desktop 동시 전환/멀티 Mac 동기화 UI 제외 |
| 데이터 경로 | `~/Library/Application Support/PokeTokenBarExtended/mobius/` | 두 앱 병행 시 파일 경합 방지. 기존 Mobius 데이터는 1회 복사 마이그레이션 |
| 다국어 | **ko·en 만 번역**, 나머지 5개 슬롯은 en 값 | 개인 포크라 상류 기여 계획이 없다(사용자 결정 2026-09-12) |

### 다국어 규칙 (계정 전환 기능 한정)

`L.t(...)` 는 7개 인자가 필수라 슬롯을 비울 수 없다. 이 기능의 새 문자열은 **ko·en 만 제대로 쓰고
ja/es/fr/pt/de 슬롯에는 en 값을 그대로 넣는다.** 그 언어 사용자에게는 계정 탭만 영어로 보이고 나머지
앱은 모국어를 유지한다.

- **기존 PokeTokenBar 문자열은 건드리지 않는다** — 이 규칙은 계정 전환 기능에만 적용된다.
- Phase 4~5 에서 **이미 7개 언어로 번역된 항목은 그대로 둔다.** 되돌리는 건 순수한 손실이고, 각
  슬롯은 독립적으로 읽히므로 혼재는 무해하다.
- **7개 언어 레이아웃 테스트는 유지한다.** en 이 들어간 슬롯은 en 폭으로 측정될 뿐이고, 나중에 진짜
  번역이 들어올 때 폭 회귀를 잡아 준다. 테스트를 ko/en 만 도는 것으로 축소하지 마라.

`L.koEn(ko:en:)`(private) 이 en 을 5개 슬롯에 복제한다. 규칙이 지켜지는지는
`AccountsLocalizationTests` 가 양방향으로 잠근다 — 새 항목은 ja/es/fr/pt/de 가 en 과 같아야 하고,
이미 7개 언어가 든 기존 항목은 en 과 **달라야** 한다(되돌림 방지).

### 비-UI 계층에서 `L` 얻기

이 기능의 문구 대부분은 뷰가 아니라 `AccountsState`(알림·배너)에서 만들어진다. 뷰의
`companion.l` 에 닿을 수 없으므로 **언어 미러**를 둔다 — `UsageStore.localizationLanguage` 와
같은 관례다.

| 자리 | 규칙 |
|---|---|
| 보관 | `AccountsState.localizationLanguage`(기본 `.systemDefault`), 접근자 `private var l: L` |
| 시드 | `AppDelegate.applicationDidFinishLaunching` — `store.localizationLanguage` 바로 옆 |
| 갱신 | `SettingsView` 언어 픽커 setter. **빠뜨리면 언어를 바꿔도 알림·배너만 옛 언어로 남는다** |

★ **`AccountsState.init` 의 두 문구(로드 실패·프로바이더 복구)만 시스템 언어로 렌더된다** —
`MobiusLaunchSequence` 가 `AccountsState` 를 `CompanionStore` 보다 **먼저** 만들고(그 순서는 데이터
보존이라 못 바꾼다) init 은 자기 저장 프로퍼티를 읽을 수도 없다. 손상된 `accounts.json` 에서만
나오는 문구이고, 사용자가 앱 언어를 시스템과 다르게 고른 경우에만 어긋난다 —
`UsageStore` 가 같은 미러에서 감수한 것과 같은 틈이다.

★ **`LoginFlowError`·`DesktopCoordinatorError` 는 `LocalizedError` 가 아니다.**
`errorDescription` 은 언어를 받을 수 없기 때문이다. 사용자 문구는 `L.accountsErrorMessage(_:)` 가
만들고(`SaveTransferError` 와 같은 구조), 그래서 이 에러를 **표시하는 자리는 반드시 그 매핑을
거쳐야 한다** — 그냥 `localizedDescription` 을 쓰면 "The operation couldn't be completed…" 가 그대로
노출되는 조용한 품질 저하가 된다. 회귀 가드는 `AccountsLocalizationTests`.

★ **한글 리터럴 검사가 `Sources/PokeTokenBarExtended/Mobius/` 까지 훑는다**
(`LocalizedUILiteralTests`). 이 계층은 뷰가 아니라 새 문구를 더할 때 `companion.l` 이 눈앞에 없어
리터럴로 되돌아가기 쉽다. 진단 로그(`AppLog.write`/`NSLog`)는 사용자 노출이 아니라 제외하되,
**리터럴이 하나뿐인 줄에서만** 건너뛴다 — 로그와 표시 문구가 한 줄에 섞이면 검사한다.

## 왜 이식이 싼가

`Sources/MobiusCore/` 는 **사용자 노출 문자열이 0개**다(한글은 전부 주석). 의존성은
`Foundation` + `Security` 뿐이고 `Bundle.module`·리소스를 쓰지 않는다. 따라서 엔진 4,100줄과
테스트 290개는 **무수정으로 이식**되고, 비용은 UI 재배치(430pt→360pt)와 다국어에만 발생한다.

## 코드 배치 (상류 rebase 부담 최소화)

Mobius 코드는 격리한다:

```
Sources/MobiusCore/              # 통째 복사. 수정 1곳(appSupport 주입)만 허용
Sources/PokeTokenBarExtended/Mobius/     # AccountsState, LoginFlow, 마이그레이션, 계정 UI
Tests/MobiusCoreTests/           # 통째 복사, 무수정
```

기존 파일 수정은 **4곳으로 제한**한다 — `Package.swift`, `UI/PopoverView.swift`(탭 추가),
`UI/SettingsView.swift`(섹션 1개), `PokeTokenBarExtendedApp.swift`(상태 생성·수명주기). 이 경계를 넘는
변경은 rebase 충돌 비용으로 되돌아온다.

## 데이터 보존 불변식 (깨지면 사용자 진행이 사라진 것처럼 보인다)

1. **앱 이름·번들 ID 를 바꾸면 데이터가 두 갈래로 갈린다 — 바꿀 때는 이전을 함께 낸다.**
   Application Support 디렉터리(도감·사용량 캐시·스프라이트·계정)와 UserDefaults 도메인(설정)이
   통째로 갈린다. 파일은 디스크에 남지만 사용자에겐 "데이터가 날아갔다"로 보인다.
   2026-09-12 에 실제로 바꿨다(`PokeTokenBar` → `PokeTokenBarExtended`,
   `io.github.chattymin.poketokenbar` → `io.github.sun007021.poketokenbarextended`) —
   아래 §개명과 데이터 이전.
2. `AppStatePaths.directory()` · `companion-state.json` · `CompanionState` 스키마에 손대지 않는다.
   Mobius 데이터는 **하위 디렉터리** `mobius/` 에만 쓴다.
3. 새 UserDefaults 키는 `mobius.` 접두사를 붙인다 (상류 키와의 충돌 및 rebase 충돌 예방).
   통합 시점 기준 양쪽 키 충돌은 0개였다 — 접두사는 미래 충돌 예방용이다.
4. **앱 시작 순서**: `LegacyDefaultsDomainMigration.migrateIfNeeded()` →
   `StateDirectoryMigration.migrateIfNeeded()` → `MobiusDataMigration.migrateIfNeeded()` →
   `AccountsState` 생성. 네 단계가 모두 "대상이 이미 있으면(또는 이미 한 번 돌았으면) 건너뛴다"로
   게이트되므로 뒤가 먼저 돌면 앞이 영영 안 돈다 — 아래 '앱 시작 순서' 절.

## 개명과 데이터 이전 (2026-09-12, 사용자 결정)

이 포크는 상류와 이름·정체성을 통째로 분리했다. 그전까지는 §데이터 보존 불변식 1 이
"바꾸지 않는다"였는데, 두 앱이 같은 번들 ID·같은 설치 경로를 공유하는 데서 오는 문제
(상류 zip·cask 가 이 앱을 덮어씀, 같은 자리를 두고 다투는 업데이트 경로)를 없애기로 했다.

### 바꾼 것

| 대상 | 전 | 후 |
|---|---|---|
| SwiftPM 타깃·디렉터리 | `PokeTokenBar` / `PokeTokenBarTests` | `PokeTokenBarExtended` / `PokeTokenBarExtendedTests` |
| 실행파일·`.app`·`CFBundleName` | `PokeTokenBar` | `PokeTokenBarExtended` (공백 없음 — 경로·launchctl 라벨 안정성) |
| `CFBundleDisplayName` | `PokeTokenBar Extended` | 그대로 (사람이 읽는 이름이라 공백 유지) |
| 번들 ID | `io.github.chattymin.poketokenbar` | `io.github.sun007021.poketokenbarextended` |
| LaunchAgent 라벨·plist | `io.github.chattymin.poketokenbar.login` | `io.github.sun007021.poketokenbarextended.login` |
| Application Support | `…/PokeTokenBar/` | `…/PokeTokenBarExtended/` |
| 로그·크래시 마커 | `~/Library/Logs/PokeTokenBar.{log,running,crash.log}` | `…/PokeTokenBarExtended.{log,running,crash.log}` |

로그 파일까지 가른 이유: 개명 **때문에** 두 앱이 공존할 수 있게 됐고, `…​.running` 은 크래시
감지 마커라 공유하면 각 앱이 상대의 수명주기를 자기 크래시로 읽는다.

### 일부러 안 바꾼 것

- **`PTB_STATE_DIR`** — 테스트 다수가 쓰는 환경변수 이름이다. 바꾸면 전수 수정인데 얻는 것이 없다.
- **`PokeTokenBar Local` 자체서명 인증서 이름**(`scripts/create-signing-cert.sh`) — 앱이 아니라
  인증서의 이름이다. 바꾸면 이미 가진 사람이 재발급해야 하고, 재발급은 코드 정체성 변경이라
  Keychain 승인 프롬프트를 한 번 더 부른다.
- **사용자 노출 제품명 문자열**(`[PokeTokenBar] 문제 리포트`, `PokeTokenBar 세이브 파일이 아니에요`
  등 `Localization.swift`) — 표시 이름은 "PokeTokenBar Extended" 라 여전히 읽힌다. 7개 언어
  카피 수정은 별도 결정으로 남긴다.
- **`mobius.` UserDefaults 키 접두사**, `MobiusCore`·`MobiusCoreTests` 타깃 이름.
- **`CONTRIBUTING*.md`·`README.ja.md`** — 상류 파일이라 건드리지 않는다(§상류 변경 가져오기).

### 세 갈래 이전 (첫 실행에 자동)

| # | 대상 | 구현 | 멱등 보장 |
|---|---|---|---|
| A | Application Support 디렉터리 | `StateDirectoryMigration` | 현재 이름의 디렉터리가 이미 있으면 아무것도 안 한다 |
| B | `UserDefaults` 도메인 | `LegacyDefaultsDomainMigration` | 1회 마커 `ptb.legacyDefaultsDomainMigratedV1` + 키별 부재 검사 |
| C | Mobius 계정 데이터 | (A) 가 겸한다 — `mobius/` 는 상태 디렉터리의 **하위**라 함께 따라온다 | (A) 와 같음 |

**(A) 는 체인이다**: `TokenMac` → `PokeTokenBar` → `PokeTokenBarExtended`.
`StateDirectoryMigration.names` 에서 **앞 항목을 지우지 마라** — 그 세대 이후로 앱을 한 번도
안 켠 사용자의 데이터가 영영 도착하지 못한다. 새 이름은 배열 **끝에만** 붙인다. 여러 세대가
동시에 남아 있을 수 있고(각 이전이 "대상이 있으면 건너뛴다"라 원본이 남는다) 그때는 **가장
최근 세대가 이긴다**. 옮기다 실패하면 원본을 그대로 둔다(반쪽 이전보다 낫다).
`AppStatePaths` 는 디렉터리 이름을 이 체인의 마지막 항목에서 가져온다 — 두 곳에 리터럴을
두면 다음 개명에서 조용히 어긋난다.

**(B) 는 덮어쓰지 않고 지우지도 않는다**: 새 도메인에 이미 있는 키는 건너뛰고(사용자가 새 앱에서
먼저 고친 값 보호), 구 도메인은 남긴다(구 번들로 되돌릴 여지). **키를 고르지 않고 전부 옮긴다** —
화이트리스트를 두면 설정을 추가할 때마다 여기를 고쳐야 하고 빠뜨리면 조용히 유실된다.
`NSStatusItem Preferred Position …` 같은 시스템 관리 키도 포함한다: 값의 의미가 "사용자가
메뉴바 아이콘을 끌어다 놓은 자리"이고, 이 도메인에 macOS 가 넣는 키 중 앱 번들 경로나 코드
정체성을 담는 것은 없다. **1회 마커**가 필요한 이유는 부재 검사만으로는 사용자가 새 도메인에서
*지운* 값이 다음 실행에 되살아나기 때문이다.

(B) 는 `MobiusLaunchSequence` 의 **첫** 단계다 — 뒤 단계와 `UsageStore`·`CompanionStore` 가 전부
`UserDefaults` 를 읽는 쪽이라 늦으면 그 실행 내내 설정이 초기값이다(§앱 시작 순서).

회귀 가드는 `Tests/PokeTokenBarExtendedTests/RenameMigrationTests.swift`(15건) +
`MobiusLaunchSequenceTests`(순서 2건). 각 가드는 지키려는 결함을 실제로 주입해 빨간불이 되는
것을 확인하고 넣었다 — 체인에서 `TokenMac` 제거, 체인 역순 순회, 기존 값 덮어쓰기, 1회 마커 제거,
설정 복사를 맨 뒤로, 디렉터리 이름 리터럴 하드코딩.

### 넘어오지 **않는** 것 (첫 실행에 사용자가 겪는 것)

- **로그인 시 실행.** 구 LaunchAgent(`io.github.chattymin.poketokenbar.login`)는 라벨이 달라
  새 앱이 관리하지 못하고, 그 plist 는 구 번들 안에 있어 **새 앱이 해제할 수도 없다**
  (`SMAppService.agent(plistName:)` 는 자기 번들의 `Contents/Library/LaunchAgents` 만 본다).
  구 앱을 지우면 launchd 가 없는 실행파일을 띄우려다 실패할 뿐이라 무해하지만, 그 자리에
  상류 `PokeTokenBar.app` 을 설치하면 **상류가 로그인 때 자동 실행된다.** 정리는 수동이다:
  `launchctl bootout gui/$(id -u)/io.github.chattymin.poketokenbar.login` 후 새 앱 설정에서
  "로그인 시 실행"을 다시 켠다.
- **알림 권한.** macOS 는 번들 ID 단위로 기억한다 — 새 앱이 처음 알림을 낼 때 다시 묻는다.
- **Keychain '항상 허용'.** 지정 요구사항(Designated Requirement)에 번들 ID 가 들어가므로
  (`codesign -d -r-` 로 확인) 구 정체성에 준 승인은 새 앱에 적용되지 않는다 — 아래 §Keychain.
- **로그 이력.** `~/Library/Logs/PokeTokenBar.log` 는 그대로 남고 새 앱은 새 파일에 쓴다.

### Keychain 은 개명의 영향을 받지 않는다 (판단)

- **계정 전환이 쓰는 자격증명은 앱 밖에 있다** — `~/.claude.json`, `~/.claude/.credentials.json`,
  `~/.codex/auth.json`, 그리고 Keychain 항목 `Claude Code-credentials`. 전부 **Claude/Codex CLI 가
  소유**하는 자원이라 앱 이름·번들 ID 와 무관하다. 옮길 것이 없다.
- **이 앱은 자기 Keychain 항목을 만들지 않는다**(`docs/reference/defect-log.md` §자격증명·Keychain
  의 "앱 소유 keychain 항목 금지"). 그래서 개명으로 고아가 되는 항목도 없다.
- **파티션 리스트 도장은 그대로 `apple-tool:`** — `MobiusCore.SystemKeychain` 은 읽기·쓰기를 모두
  `/usr/bin/security` 경유로 하고, 파티션 재도장은 **수정한 프로세스**의 cdhash 로 찍힌다. 우리
  프로세스가 아니라 `security` 가 수정하므로 우리 번들 ID 가 무엇이든 결과가 같다. 개명은 이
  구조에 영향을 주지 않는다(코드 변경 없음).
- **대가는 한 번의 승인 프롬프트뿐** — 호스트 앱 쪽 한도 조회(`OAuthLimitsProvider`·
  `SessionKeyLimitsProvider`·`AntigravityRateLimitsProvider`)는 남의 Keychain 항목을 네이티브
  `SecItemCopyMatching` 으로 읽고, 그 ACL 승인은 코드 정체성에 묶인다. 번들 ID 가 바뀌면 지정
  요구사항이 바뀌므로 첫 읽기에서 **한 번** 다시 묻는다. 서명 인증서는 그대로(Developer ID
  Sunwook Lee)라 그 뒤로는 안정적이다.

## 이식 규칙 (Mobius 가 실패로 배운 것 — 재현 금지)

- **Keychain 쓰기는 반드시 `security` CLI 경유.** 네이티브 `SecItemUpdate` 를 쓰면 macOS 가 파티션
  리스트를 그 앱의 cdhash 로 재도장해, Claude Code·Claude Desktop 의 자격증명 읽기마다 암호창이
  뜬다(되돌리려면 사용자가 직접 파티션을 고쳐야 한다). `SystemKeychain` 의 이 구조를 건드리지 않는 것이
  대응이다. `security dump-keychain` 은 승인창 폭탄이라 어떤 경우에도 실행 금지.
- **토큰의 진실은 Keychain, 이메일은 `~/.claude.json`.** 파일(`.credentials.json`)은 낡을 수 있어
  파일 우선 읽기로 바꾸면 낡은 토큰과 최신 이메일이 짝지어져 라이브 로그인이 오염된다.
- **지속화 struct 에 필드를 추가할 땐 관대한 `init(from:)`** (`decodeIfPresent ?? 기본값`).
  구버전 파일이 `keyNotFound` 로 디코드 실패하면 빈 스토어가 파일을 덮어써 계정이 영구 유실된다.
- **고정 frame `List` 에서 행 삽입+삭제 조합 금지.** 풀 전체를 한 List 의 행으로 두고 primary 는
  `moveDisabled`, 전환은 "행 이동"으로 모델링한다. 안 그러면 primary 전환 시 스크롤 오프셋이
  어긋난 채 방치돼 UI 가 겹쳐 보인다.
- **주기 타이머가 만드는 작업에는 재진입 가드**, 그리고 **스캔 락을 쥔 채 도는 구간의 비용이 입력
  크기에 비례하면 메인 스레드가 그 락을 동기적으로 기다리게 하지 않는다.** 대용량 세션 로그
  환경에서 UI 영구 정지(행)로 나타난 부류다.
- **익명 로그 라인으로 계정 상태를 기록하지 않는다.** Claude 세션 로그 hit 에는 계정 식별자가 없어
  전환 직후 옛 계정의 에러가 새 계정에 박힌다 → 자동 전환이 통째로 죽는다. 판정은 usage API 로 한다.
- **이식한 코드는 호스트 앱의 환경 가드 관례를 따른다.** PTB 는 번들이 아닐 수 있다 — raw 바이너리
  개발 실행(`swift run` / `./.build/debug/PokeTokenBarExtended`)과 `swift test` 가 그 경우다. 알림
  (`UNUserNotificationCenter`)·로그인아이템(`SMAppService`)·프로덕션 로그처럼 **번들을 요구하는 API
  는 `AppEnv.isBundledApp` 뒤에 둔다**. `UNUserNotificationCenter.current()` 는 번들이 아니면 nil 을
  주는 게 아니라 **예외를 던져 프로세스를 죽인다** — Mobius 는 항상 `.app` 이라 이 가드가 없었고,
  이식된 `AccountsState.start()`/`notify()` 가 그대로 넘어와 기능 토글을 켠 raw 바이너리가 시작 즉시
  죽었다. Phase 5~8 에서 새 알림·로그인아이템 코드를 더할 때 같은 게이트를 붙일 것. 회귀 가드는
  `Tests/PokeTokenBarExtendedTests/MobiusBundleGuardTests.swift`(진짜 트리거 호출 2건 + 소스 스캔 1건),
  부류 전체 기록은 `docs/reference/defect-log.md` §알림.

## Phase 1 실측

- **Swift 언어 모드 경계**: 이 패키지는 `swift-tools-version: 6.0` 이지만 `MobiusCore` 타깃만
  `.swiftLanguageMode(.v5)` 로 핀 고정했다. 엔진 4,100줄을 무수정으로 이식하려면 상류(Mobius)와
  같은 언어 모드가 필요했기 때문이다. Phase 3 에서 Swift 6 모드인 호스트 앱 쪽(`@MainActor`
  상태 계층, 예: `AccountsState`)이 v5 로 컴파일된 `MobiusCore` 타입을 actor 경계 너머로 넘길 때
  Sendable 마찰이 예상된다 — v1 대응은 필요한 지점에 `@preconcurrency import MobiusCore` 를
  붙이는 것으로 하고, `MobiusCore` 자체를 Swift 6 모드로 옮기는 것은 별도 후속으로 남긴다.
- **상류의 타이밍 민감 테스트**: `SessionKeySettingsRenderingTests` 는 오프스크린 윈도우를 key 로
  만들고 500ms 고정 대기 후 스크롤 결과를 측정하므로 머신 부하에 따라 실패할 수 있다. Mobius 코드를
  0줄 더한 기준선 커밋에서도 동일하게 재현되므로 이 통합의 회귀가 아니다 — **전체 스위트 판정 시
  이 테스트 1건만 실패하는 것은 통과로 간주한다.**
- ★ **스위트 시간이 수십 분으로 튀면 코드가 아니라 맥이 잔 것이다 — `caffeinate -i swift test` 로
  돌려라.** 방치한 채 배터리로 돌리면 macOS 가 유휴 판정으로 sleep 에 들어가고, 그때 시간 대기
  중이던 테스트가 그 시간만큼 통째로 늘어난다(그리고 **깨어나서 통과한다** — 행이 아니다).
  실측 2026-09-12: 같은 커밋이 40.1s·39.2s 로 돌다가 한 번 **1,186s** 가 나왔고,
  `SwitcherTests.testResaveOnSwitchClearsReauthOfOutgoingAccount` 한 건이 **992.4s** 를 먹었다.
  `pmset -g log` 에 `10:37:54 Entering Sleep … 'Maintenance Sleep' … **994 secs**` 가 그대로
  찍혀 있다(두 번째 sleep 146s 는 `UsageStoreTests` 163s 로 나타났다). 느린 스위트가 **매번
  다른 곳으로 옮겨 다니는 것**이 신호다 — 그때 timed wait 을 쥐고 있던 테스트가 걸릴 뿐이라,
  `sample` 로 잡히는 스택(CFNetwork 등)은 원인이 아니라 그 순간 주차돼 있던 자리다. 이 함정은
  `MobiusCore` 테스트처럼 네트워크·Keychain 을 아예 안 쓰는(`InMemoryKeychain` + 임시 디렉터리)
  스위트에서도 똑같이 나타나므로, **"우리 코드가 뭔가 붙잡고 있다"로 오귀인하기 쉽다.**

## 단계

전부 완료됐다(2026-09-12). 각 단계의 산출물은 `git log --oneline 69ff39b..` 의 `*(mobius)` 커밋들이다
— `69ff39b` 가 이 포크가 갈라져 나온 상류 커밋이다.

- [x] **Phase 0 — 안전망**: 데이터 백업(디렉터리 + UserDefaults), 포크·클론, 기준선 `swift test`
- [x] **Phase 1 — 엔진 이식**: `MobiusCore` + `MobiusCoreTests` 복사, `Package.swift` 배선. **UI 변화 0**
- [x] **Phase 2 — 경로 주입 + 마이그레이션**: `MobiusEnvironment.appSupport` 주입,
      기존 `~/Library/Application Support/Mobius/` → `<상태 디렉터리>/mobius/` 1회 **복사**(이동 아님),
      `secrets/` 0600 권한 보존 검증, 멱등성 테스트
- [x] **Phase 3 — 상태 계층**: `AppState` → `AccountsState`(ObservableObject 유지, sync·update 제거),
      `LoginFlow`·`ToolInventory`·`ClaudeCLI` 이식, 토글 off 면 타이머 미생성
- [x] **Phase 4 — 계정 탭**: `PopoverTab.accounts`, 360pt 카드 리스트 재작성
- [x] **Phase 5 — 설정 섹션**: 자동 전환(Claude/Codex) · 계정 추가 · 게이지 · 미리 전환 · 알림
- [x] **Phase 6 — 안전장치**: 이중 writer 가드(`dev.chussum.mobius` 실행 감지), 전환 시
      `OAuthAccessTokenCache.shared.invalidate()`
      (★ **디스플레이** 슬립은 신호로 쓰지 않기로 했다 — Phase 3b 판단. 메뉴바 애니메이션과 달리
      자동 전환은 정확성 기능이라, 화면만 꺼진 채 `claude`/`codex` 세션이 계속 도는 흔한 상황에서
      틱을 멈추면 소진돼도 전환이 안 되고 사용자는 막힌 CLI 로 돌아온다. 쓴다면 **시스템** 슬립
      (`NSWorkspace.willSleepNotification`/`didWakeNotification`)이어야 하고, 깨어날 때 즉시 1틱을
      돌리는 경로가 함께 필요하다)
- [x] **Phase 7 — 다국어**: 계정 전환 문구 65개를 `L` 로 이관 완료(lproj·`Bundle.module` 금지).
      Phase 3 이 만든 임시 경유지 `Sources/PokeTokenBarExtended/Mobius/MobiusStrings.swift` 는
      호출부가 사라져 **삭제**했다. 항목은 `Localization.swift` 의 `accountsNotify*`(알림)·
      `accountsError*`(배너·실패 사유·에러 매핑) 접두사로 모여 있고, 비-UI 계층이 `L` 을 얻는
      방법은 위 §다국어 규칙 참조
- [x] **Phase 8 — 게이트·빌드**: `test-gate.sh` 화이트리스트 갱신, Developer ID 서명 검증.
      `/Applications` 설치는 사용자 데이터가 걸린 비가역 작업이라 사람이 직접 한다(아래 §운영 주의사항)
- [x] **에너지 최적화 3건**(Phase 8 과 같은 묶음): 이중 writer 감시를 폴링에서 `NSWorkspace`
      실행/종료 알림으로, 엔진 타이머에 wakeup tolerance 부여, `claude`/`codex` 가 하나도 안 돌 때
      세션 로그 스캔을 유휴 주기로 낮춤

## 운영 주의사항

이 포크를 실제로 **쓰는** 사람(= 자기 Mac 에 설치하는 사람)이 알아야 하는 것들. 위 단계 목록이
"무엇을 만들었나"라면 이 절은 "설치하고 유지할 때 무엇이 다른가"다.

### Homebrew cask 는 제거한다 (사용자 결정)

**개명 전** 상류 릴리스를 받는 `poke-token-bar` cask 와 이 포크는 같은 번들 ID·같은 설치
경로를 썼고, cask 를 남겨 두면 `brew upgrade` 한 번에 포크가 상류 빌드로 조용히 덮어써졌다.
개명 이후에는 경로도 번들 ID 도 달라 **덮어쓰기 경로 자체가 사라졌다** — cask 를 남겨 두면
상류 앱이 따로 설치될 뿐이다. 그래도 두 앱을 같이 두면 메뉴바 아이콘이 둘이고 같은 사용량
로그를 둘이 읽으므로, 이 포크만 쓸 생각이면 그대로 지우는 편이 낫다.

```bash
brew uninstall --cask poke-token-bar
```

`--zap` 을 **붙이지 않는다** — `--zap` 은 `~/Library/Application Support/PokeTokenBar` 까지
지운다. 개명 첫 실행 **전**이라면 그 디렉터리가 아직 이 포크의 데이터 원본이라 도감·토큰·계정이
함께 날아가고, 개명 첫 실행 **후**라도 되돌릴 원본이 사라진다. 위 명령은
`/Applications/PokeTokenBar.app` 만 지우고 데이터는 그대로 둔다.

cask 제거는 이제 **유일한 방어가 아니다** — 앱 안의 cask 업그레이드 경로도 코드에서 닫혀 있다
(§상류 릴리스 알림이 떴을 때). cask 를 다시 설치해도 덮어쓰기가 되살아나지 않는다.

### 기존 `Mobius.app` 은 제거한다 (사용자 결정)

두 앱을 동시에 두면 Keychain·`~/.claude.json` 이라는 전역 자원을 양쪽이 스왑해 자격증명이
오염된다(§이중 writer 가드). 가드가 이 앱을 물러나게 만들므로 Mobius.app 이 떠 있는 동안에는
계정 전환이 아예 안 된다 — 남겨 둘 이유가 없다.

계정 데이터는 **이미 복사돼 있다**: Phase 2 의 마이그레이션은 이동이 아니라 복사라
`~/Library/Application Support/PokeTokenBarExtended/mobius/` 에 사본이 있고 원본
`~/Library/Application Support/Mobius/` 도 그대로 남아 있다. 즉 Mobius.app 을 지워도
되돌릴 원본이 남는다.

### 빌드·설치

```bash
CODESIGN_IDENTITY="Developer ID Application: Sunwook Lee (TYN557Y96W)" \
  PTB_REQUIRE_STABLE_SIGN=1 ./scripts/build-app.sh
```

`build-app.sh` 는 마지막에 **실행 중인 앱을 `pkill` 하고 `/Applications` 를 교체한다.** 빌드만
확인하고 싶으면 그 두 줄을 뺀 복사본을 돌려라(설치는 비가역이고 앱이 계정 데이터를 쓰고 있다).

`PTB_REQUIRE_STABLE_SIGN=1` 은 인증서를 못 찾았을 때 ad-hoc 으로 조용히 내려가는 것을 막는다.
ad-hoc 서명은 **리빌드마다 코드 정체성이 바뀌어** Keychain '항상 허용'이 매번 리셋되므로,
계정 전환 기능에서는 고정 서명이 사실상 필수다.

★ **`spctl -a -t exec` 는 이 번들을 거부한다** — `source=Unnotarized Developer ID`. Developer ID
서명은 **공증(notarization)** 까지 받아야 Gatekeeper 정책을 통과한다. 로컬 설치에서는 문제가
되지 않는다: Gatekeeper 의 실행 차단은 **quarantine 속성이 붙은** 번들에만 적용되고, 직접 빌드해
`cp -R` 로 복사한 앱에는 `com.apple.quarantine` 이 붙지 않는다(붙는 건 브라우저·메일 등이 받은
파일이다). **이 번들을 남에게 전달(다운로드 배포)하는 순간** 이야기가 달라진다 — 그때는 공증이
필요하다. 서명 자체는 정상이다: `codesign --verify --strict` 는 `valid on disk` +
`satisfies its Designated Requirement`, 체인은 Apple Root CA 까지 올라가고 secure timestamp 도 있다.

★ 상류 cask 로 설치돼 있던 앱은 **ad-hoc 서명**(`TeamIdentifier=not set`)이다. Developer ID 빌드로
교체하면 코드 정체성이 바뀌므로 첫 Keychain 접근에서 승인 프롬프트가 **한 번** 뜰 수 있다. 그
다음부터는 인증서가 고정이라 다시 뜨지 않는다.

### 버전 표기 — 독자 버전 `1.0.0` (2026-09-15, 사용자 결정)

PokeTokenBar Extended 는 상류와 **별개로 1.0.0 부터** 버전을 매긴다. 옛 표기 `2.5.3+mobius.1`
(상류 기준점 + 포크 빌드 번호)은 은퇴했다. 그 표기는 포크와 상류가 **같은 번들 ID·같은 설치
경로**를 쓰던 시절 둘을 구분하는 유일한 신호였는데, 개명(§개명과 데이터 이전)으로 그 전제가
사라졌다.

| 자리 | 값 |
|---|---|
| `scripts/build-app.sh` | `VERSION="1.0.0"` 한 줄 — 유일한 정의 지점. `CFBundleShortVersionString`·`CFBundleVersion` 둘 다 이 값 |
| 태그 | `vX.Y.Z`, 주석 `PokeTokenBar Extended X.Y.Z` (`release.sh` 가 이 주석으로 자기 태그를 찾는다) |
| 업데이트 배너 | `UpdateChecker.releaseRepo = "sun007021/PokeTokenBarExtended"` — **이 저장소의 릴리스만 본다** |

★ **배너가 상류를 보면 안 된다.** 1.x 에서 상류 2.x 를 보면 늘 "새 버전"이라 배너가 상시로 뜬다.
그래서 "상류 릴리스 알림을 계속 받는다"던 옛 결정도 함께 폐기됐다 — 상류 변경은 사람이 `git fetch
upstream` 으로 확인한다. `UpdateCheckerTests.testChecksThisAppsOwnReleasesBecauseUpstreamVersionsAlwaysLookNewer`
가 전제(2.5.4 > 1.0.0)와 결론(조회 대상)을 함께 잠근다.

★ **옛 `2.5.3+mobius.N` 설치본은 1.0.0 배너를 받지 못한다** — `isNewer("1.0.0", than: "2.5.3+mobius.1")`
은 거짓이다. 그 빌드는 공개 릴리스로 나간 적이 없고(로컬 빌드뿐) 사용자 한 명이라, 1.0.0 DMG 로 한 번
수동 교체하는 것으로 정리한다. 코드로 우회하지 않는다.

`isNewer` 가 `+`(빌드 메타데이터)·`-`(프리릴리스) 뒤를 잘라내는 `precedenceParts` 는 그대로 둔다 —
semver 우선순위 규칙과 같고, 로컬 빌드 표기가 붙어도 판정이 흔들리지 않는다.

`CodexRateLimitsProvider` 가 이 값을 Codex MCP 핸드셰이크의 `clientInfo.version` 으로 보낸다 —
`1.0.0` 은 평범한 semver 라 문제없다.

### 상류 변경 가져오기

`upstream` 리모트는 이미 걸려 있다(`chattymin/PokeTokenBar`). 이 저장소의 `main` 은 이미 origin 에
공개돼 있으므로 rebase(강제 push 필요) 대신 **필요한 커밋만 cherry-pick 하거나 merge** 한다
(v2.5.4 반영 때 #290·#292·#293·#295 만 골라 cherry-pick 했다).

```bash
git fetch upstream
git log --oneline HEAD..upstream/main           # 새 커밋 확인
git merge-tree --write-tree --name-only HEAD upstream/main   # 작업트리 안 건드리고 충돌 미리보기
git cherry-pick <sha>...                        # 또는 git merge upstream/main
./scripts/test-gate.sh
```

★ **상류에서 새로 생긴 파일은 옛 경로로 들어온다.** git 이 개명된 디렉터리로 옮겨 주긴 하지만
(`CONFLICT (file location)` 로 표시) 파일 **내용**의 `@testable import PokeTokenBar` 와
`"Sources/PokeTokenBar/..."` 경로 문자열은 그대로라 컴파일·테스트가 깨진다. 새 파일마다
`PokeTokenBarExtended` 로 바꾼다.

충돌은 §코드 배치 가 정한 4곳(`Package.swift`, `UI/PopoverView.swift`, `UI/SettingsView.swift`,
`PokeTokenBarExtendedApp.swift`)과 `Localization.swift`, 그리고 이 저장소가 고친 스크립트
(`build-app.sh`·`release.sh`·`test-gate.sh`)에서 난다. `build-app.sh` 의 버전은 상류 버전과 무관하니
**이쪽 값을 유지**하고, `test-gate.sh` 는 양쪽 파일 목록을 합친다. `README.md`·`README.ko.md` 는 이
앱의 설치 문서라 이쪽을 유지한다(`README.ja.md` 는 상류 파일 그대로).

상류 앱은 다른 번들 ID·다른 설치 경로의 **별개 앱**이다 — 상류 릴리스를 받아 설치해도 이 앱은
갱신되지 않고 메뉴바 아이콘만 하나 늘어난다.

**자동 덮어쓰기 경로는 코드에서 닫아 두었다** — `UpdateChecker.allowsBrewCaskUpgrade = false`.
`applyUpdate()` 의 brew 분기는 확인창 **하나 없이** 앱을 종료하고 `brew upgrade --cask
poke-token-bar` 로 상류 앱을 설치한다. cask 가 한 번이라도 설치돼 있으면 그 경로가 되살아나므로
코드가 막게 했다(`testForkNeverTakesTheBrewCaskUpgradePath`). 배너의 업데이트 버튼은 이 저장소의
릴리스 페이지를 열 뿐이다.

### 배포 — 서명·공증·DMG (`release.sh`)

절차는 `docs/reference/release-workflow.md` §PokeTokenBar Extended 릴리스. 요지만:
Developer ID 서명(hardened runtime + secure timestamp) → 앱 공증·staple → DMG 생성·서명·공증·staple
→ 태그·push → GitHub Release 에 `PokeTokenBarExtended.dmg` + `.zip` 첨부. README 의 다운로드 링크는
`releases/latest/download/PokeTokenBarExtended.dmg` 라 **자산 파일 이름이 곧 링크**다 — 이름을 바꾸면
링크가 404 가 된다(`release.sh` 문서 검토가 README 에 그 링크가 있는지 본다).

### Mobius 본체(`chussum/mobius`)의 변경을 가져올 때

계정 전환 엔진은 `/Users/sun/orca/mobius` 의 `Sources/MobiusCore/` 를 **무수정 복사**한 것이다
(§왜 이식이 싼가). 본체가 업데이트되면 같은 파일들을 다시 복사하되:

```bash
cp -R /Users/sun/orca/mobius/Sources/MobiusCore/. Sources/MobiusCore/
cp -R /Users/sun/orca/mobius/Tests/MobiusCoreTests/. Tests/MobiusCoreTests/
git diff -- Sources/MobiusCore/MobiusEnvironment.swift   # ← 반드시 확인
```

★ **`Sources/MobiusCore/MobiusEnvironment.swift` 의 `appSupportDirOverride` 는 이 포크의
유일한 수정 지점이라 보존해야 한다** (§코드 배치: "수정 1곳(appSupport 주입)만 허용").
통째로 덮으면 주입이 사라져 계정 데이터가 `~/Library/Application Support/PokeTokenBarExtended/mobius/`
가 아니라 **원본 Mobius.app 의 `…/Mobius/` 로 되돌아간다** — 에러 없이, 두 앱이 같은 파일을
쓰는 상태로. 복사 후 이 한 파일의 diff 를 눈으로 보고 주입을 되살린 뒤 `./scripts/test-gate.sh`
(`MobiusDataMigrationTests`·`MobiusLaunchSequenceTests` 가 경로를 잠근다).

새 파일이 생겼으면 `Package.swift` 는 디렉터리 단위라 손댈 필요가 없지만,
`scripts/test-gate.sh` 의 `LOGIC_CORE` 화이트리스트에 추가할지는 판단한다(커버리지 게이트 대상).

## 앱 시작 순서 (`MobiusLaunchSequence`)

`AppDelegate.applicationDidFinishLaunching` 은 Mobius 초기화를 하드코딩된 호출 줄이 아니라
`MobiusLaunchSequence.run { … }` 로 돈다. 순서가 **한 곳**(`MobiusLaunchSequence.order`)에만
적혀 있어야 테스트가 프로덕션 경로까지 같이 고정할 수 있기 때문이다.

| 순서 | 단계 | 먼저 돌면 잃는 것 |
|---|---|---|
| 1 | `legacyDefaultsDomainCopy` (구 번들 ID 도메인 → 현재 도메인) | 뒤 단계와 `UsageStore`·`CompanionStore` 가 전부 `UserDefaults` 를 **읽는** 쪽 — 늦으면 그 실행 내내 설정이 초기값이다. 특히 `accountStateCreation` 은 `mobius.enabled` 를 읽어 엔진을 켤지 정하므로, 자동 전환을 켜 둔 사용자에게 그 실행에서는 전환이 안 돈다 |
| 2 | `legacyStorageRename` (`TokenMac` → `PokeTokenBar` → `PokeTokenBarExtended`) | `!fileExists(new)` 게이트 — 누가 먼저 `AppStatePaths.directory()` 를 부르면(호출만으로 디렉터리가 **생긴다**) 옛 이름 시절 도감·토큰이 영영 이전 안 됨 |
| 3 | `mobiusDataMigration` (`…/Mobius` → `<상태 디렉터리>/mobius`) | `alreadyMigrated` 판정이 **대상 디렉터리 존재** — `AccountStore` 가 먼저 저장해 `mobius/` 를 만들면 기존 Mobius.app 계정·비밀 스냅샷이 영영 이전 안 됨 |
| 4 | `accountStateCreation` (`AccountsState` + 조건부 `start()`) | — |

`Tests/PokeTokenBarExtendedTests/MobiusLaunchSequenceTests.swift` 가 각 순서를 **실제 파일 연산으로
재생**해 데이터가 실제로 넘어왔는지 본다(순서 단언만으로는 "왜 그 순서인지"를 증명 못 한다).
프로덕션 함수 넷(`LegacyDefaultsDomainMigration.migrateIfNeeded(...)`,
`StateDirectoryMigration.migrateIfNeeded(base:)`, `MobiusDataMigration.migrateIfNeeded(source:)`,
`AppStatePaths.directory()`)을 `PTB_STATE_DIR` 와 임시 suite 두 개로 격리해 그대로 호출한다 —
그 함수들의 `base`/`source`/도메인 이름 파라미터는 **테스트 주입 전용**이고, 함정 당사자인
대상 경로 유도는 일부러 주입하지 않는다. 실제 `~/Library/Application Support` 와 실제
UserDefaults 도메인은 건드리지 않는다.

마이그레이션 실패는 **앱 시작을 막지 않는다** — 계정 전환은 부가 기능인데 거기서 던지면 포켓몬
앱 전체가 못 뜬다. `AppLog` 에 남기고 계속 진행하며, 실패하면 대상 디렉터리가 안 만들어지므로
다음 실행에서 자연히 재시도된다.

## 기능 토글 `mobius.enabled` (기본 꺼짐)

`MobiusFeature.isEnabled` 가 꺼져 있으면 `AccountsState.start()` 를 부르지 않는다. `start()` 가
타이머(3초 틱)·세션 로그 스캔·Keychain 워밍업·알림 권한 요청·`DistributedNotificationCenter`
옵저버의 **유일한** 진입점이므로, 꺼진 상태의 런타임 동작은 기능을 넣기 전과 같다. 객체는
생성되지만 `AccountStore.init` 은 디스크를 읽기만 하고 아무 디렉터리도 만들지 않는다.

수동 확인: `defaults write io.github.sun007021.poketokenbarextended mobius.enabled -bool YES`.
토글 UI 는 Phase 5.

## 상태 계층을 `ObservableObject` 로 두는 이유

호스트 앱은 `@Observable`(Observation), Mobius `AppState` 는 `@Published` 다. 변환하면 diff 가
1,850줄 전체로 번져 위 "이식 규칙" 들이 손상될 위험이 크다. SwiftUI 는 두 시스템의 공존을 허용하므로
`AccountsState` 는 `ObservableObject` 그대로 두고 `.environmentObject` 로 붙인다.

## 알려진 트레이드오프 (v1 에서 감수)

- **로그 스캐너 중복**: 호스트 앱의 `LocalUsageReader` 와 Mobius 의 `SessionLogWatcher` 가 같은
  `~/.claude/projects` · `~/.codex/sessions` 트리를 각자 훑는다. v1 은 각자 캐시·오프셋으로 공존하고,
  Phase 3 에서 유휴 CPU 를 실측해 기준선 대비 +0.5%p 를 넘으면 통합을 앞당긴다.
- **Desktop 동시 전환 코드는 남되 UI 미노출**: `performSwitch`/`reload` 에 얽혀 있어 제거 수술이
  오히려 회귀 위험이다. ★ **[2026-09-12 정정]** 이 항목은 원래 "토글 기본 off 로 잠재운다"고
  적혀 있었는데 **거짓이었다** — 실제 게이트는 `MobiusFeature.desktopSyncInScope`(상수, 아래
  결함 참조)다. 자세한 내용과 왜 "토글 기본 off"가 이 기능에는 통하지 않았는지는 바로 아래
  §Desktop 동시 전환이 "UI 미노출"만으로는 안 잠들어 있었던 결함 참조.
- **두 앱 병행 실행 금지**: Keychain·`~/.claude.json` 은 전역 자원이라 Mobius.app 과 이 앱이 동시에
  스왑하면 자격증명이 오염된다. Phase 6 의 실행 감지 가드가 이를 막는다(아래 '이중 writer 가드').

## Desktop 동시 전환이 "UI 미노출"만으로는 안 잠들어 있었던 결함 (2026-09-12)

**증상**: 사용자가 계정 카드를 눌러 **수동** Claude 전환을 하면 Claude Desktop 이 **경고 없이
종료되고 로그아웃**됐다. 되돌릴 UI도 없었다.

**연쇄**:
1. `MobiusCore/Models.swift` 의 `AccountsFile.init` 기본값 `desktopSyncEnabled: Bool = true` —
   Mobius 본체가 그렇게 설계했다(이 포크의 결정이 아니다). `AccountStore.init(env:keychain:)` 는
   디스크에 accounts.json 이 없으면 `AccountsFile()` 을 그대로 쓰므로, **이 값을 한 번도 만진 적
   없는 사용자도** 이미 `desktopSyncEnabled == true` 다.
2. `AccountsState.performSwitch`(수동 전환)와 `apply`(자동 전환)가 저장된
   `desktopSyncEnabled`/`desktopAutoSwitchEnabled` 만 보고 `switchDesktopIfPossible` 을 불렀다 —
   "1차 범위 밖"이라는 범위 결정이 코드에는 전혀 반영돼 있지 않았다.
3. `setDesktopSync(_:)`/`setDesktopAutoSwitch(_:)` 는 **어떤 View 에서도 호출되지 않는다**(전수
   grep 으로 확인) — 즉 "UI 를 안 붙였다"가 곧 "꺼진 채로 잠들었다"라는 원래 가정은 **이 필드가
   `true` 로 시작하는 순간 성립하지 않는다.** 꺼진 채로 잠드는 건 **기본값이 꺼짐인** 기능뿐이고
   (`desktopAutoSwitchEnabled` 는 기본 `false` 라 실제로 무해했다), 기본값이 켬인 기능은 UI가
   없으면 오히려 **끌 방법이 없어진다.**
4. 실측(이 저장소 사용자의 실제 파일, 읽기 전용으로 확인): `~/Library/Application Support/
   PokeTokenBarExtended/mobius/accounts.json` 에 `desktopSyncEnabled: true` 가 이미 저장돼 있었고,
   `desktop-profiles/`(Desktop 스냅샷) 디렉터리는 존재하지 않았다 — 이 조합이
   `switchDesktopIfPossible` 의 "미캡처 대상으로의 전환" 분기를 타서 `DesktopCoordinator.
   switchDesktop` 이 실행 중이던 Claude Desktop 을 종료 + 로그아웃시킨다(§Keychain 이 아니라
   §hasLiveLogin — 신원 파일 제거이므로 실제 로그아웃이 맞다).

**근본원인 (5-whys)**: "1차 범위 밖 = UI 미노출"이라는 범위 결정을, 코드에는 "UI 콜백이 없다"로만
반영했다. 이 기능은 **기본값이 켬**인 지속화 필드로 게이트되므로, UI 부재는 아무 방어도 아니었다 —
오히려 사용자가 그 값을 되돌릴 방법을 없앴을 뿐이다. 테스트가 이를 못 걸러낸 이유: 기존
`MobiusCoexistenceGuardTests`류 회귀 테스트는 이중 writer 가드처럼 **명시적으로 설계된** 게이트만
검증했고, "범위 결정이 실제로 코드에 반영됐는가"를 확인하는 테스트가 없었다.

**수정**: `MobiusFeature.desktopSyncInScope`(상수, 현재 `false`) 를 `performSwitch`/`apply` 양쪽
호출부의 **첫 조건**으로 추가했다 — 저장된 값·기본값과 완전히 무관하게 호출부 자체를 막는다.
- **왜 기본값을 바꾸거나 마이그레이션으로 끄지 않았나**: 이미 디스크에 `true` 로 저장된 파일은
  기본값을 바꿔도 안 꺼진다(디코더가 저장값을 우선한다). 마이그레이션(1회 강제 `false` 쓰기)도
  고려했지만, 그러면 나중에 이 기능을 UI 와 함께 노출할 때 "마이그레이션이 사용자의 이전 선택을
  지웠다"는 새 문제가 생긴다. 호출부 게이트는 저장값을 **건드리지 않고 무시**하므로 나중에
  상수만 지우면 저장값이 그대로 되살아난다 — 되돌릴 지점이 한 곳(`MobiusFeature.swift`)으로
  분명하다.
- **코드는 지우지 않았다** — `DesktopCoordinator`/`DesktopSwitcher`/`switchDesktopIfPossible` 은
  그대로 남아 있다. 이 기능을 나중에 UI 와 함께 노출하려면 `MobiusFeature.desktopSyncInScope` 를
  지우고(또는 `true` 로 바꾸고) 그 옆에 실제 켬/끔 UI(`setDesktopSync`/`setDesktopAutoSwitch` 를
  부르는 뷰)를 **반드시 함께** 넣을 것 — 이번 결함이 증명하듯 하나만 하면 재발한다.

**부류 스윕 (§결정 사항의 1차 범위 제외 항목이 실제로도 잠들어 있는지)**:

| 제외 항목 | 실제 상태 | 근거 |
|---|---|---|
| Desktop 동시 전환 | ✗ 안 잠들어 있었음(본 결함) | 위 내용 |
| 멀티 Mac 동기화(`SyncEngine`) | ✓ 잠들어 있음 | `SyncEngine(` 생성자 호출이 `Sources/PokeTokenBarExtended/` 전체에 0건 — 타입만 이식되고 아무도 안 씀 |
| 실험실(`labsIndent` 등) | ✓ 잠들어 있음(애초에 없음) | 이 포크 UI에 "실험실" 탭·섹션 자체가 없다 — `AccountSwitchingSettingsSection.swift` 헤더 주석의 "범위 밖" 목록일 뿐, 대응하는 뷰가 없다 |
| Mobius 자체 업데이트 확인(`MobiusCore.UpdateChecker`) | ✓ 잠들어 있음 | `PokeTokenBarExtendedApp.swift` 가 만드는 `UpdateChecker` 는 `Sources/PokeTokenBarExtended/Core/UpdateChecker.swift`(호스트 앱 자신의 업데이트 확인기, PokeTokenBar 상류용)다 — `MobiusCore.UpdateChecker` 를 생성하는 코드는 전수 grep 으로 0건 |
| advisory(임계값 선제 전환) | (해당 없음 — 범위 밖 목록에 없음) | `mobius-integration.md` §결정 사항은 advisory 를 제외하지 않는다. Phase 5 가 실제로 설정 UI(`AccountSwitchingSettingsSection.swift`)를 붙여 놨고 기본값도 꺼짐이라 이 결함의 부류가 아니다 |

**차이의 원인**: Desktop 동시 전환만 다른 셋과 달랐던 이유는 정확히 "지속화 필드의 기본값이
켬이면서 호출부가 그 필드를 직접 읽는다"는 조합 때문이다. `SyncEngine`/`UpdateChecker` 는 **호출
자체가 없어서**(설령 기본값이 켬이어도 아무도 안 부르면 무해), 실험실은 **UI 자체가 없어서**(설정
저장은 됐어도 사용자가 값을 바꿀 창구가 없다는 것과 별개로 코드 경로가 원천적으로 없음),
advisory 는 **기본값이 꺼짐이라서** 각각 안전했다. 이 조합(기본 켬 + 호출부가 직접 읽음 + UI
없음) 자체를 새 기능에 반복하지 않는 것이 재발 방지다.

**회귀 테스트**: `Tests/PokeTokenBarExtendedTests/DesktopSyncScopeTests.swift`.
`desktopSwitchAttemptsForTesting`(테스트 전용 카운터, `switchDesktopIfPossible` 최상단에서
증가)로 그 함수가 **진입조차 안 하는지**를 확인한다 — `DesktopCoordinator` 는 실물
`com.anthropic.claudefordesktop` 번들을 `NSRunningApplication` 으로 건드리므로, 이 테스트는
실제로 그 경로를 태우지 않고 진입 여부만으로 게이트를 증명한다. `testManualSwitchDoesNotAttempt
DesktopSyncWithTheDefaultStoredValue` 가 정확히 이 결함의 재현 조건(디스크에 아무것도 없는 새
`AccountStore` 조차 `desktopSyncEnabled == true`)을 검증한다.

## 이중 writer 가드 (Phase 6)

`MobiusCoexistence` 가 `dev.chussum.mobius`(원본 Mobius.app)의 실행을 감지하면 이 앱의 계정 전환
엔진이 **물러난다.** 조정이 아니라 양보다 — 원본에는 이 협상에 참여할 코드가 없으므로 아는 쪽이
항상 물러나야 한 명만 남는다(`SingleInstance` 와 같은 방향의 결정).

막으려는 사고는 **에러로 나타나지 않는다**: 토큰(Keychain)과 이메일(`~/.claude.json`)이 서로 다른
시점에 갱신되는 찰나를 상대가 읽으면 낡은 토큰과 최신 이메일이 한 프로필에 짝지어지고, 사용자의
라이브 로그인까지 조용히 오염된다(원본 '실패 기록 1').

| 축 | 결정 |
|---|---|
| 감지 | `NSRunningApplication.runningApplications(withBundleIdentifier:)`. 판정은 순수 함수 `isBlocked(by:)` 로 분리했고 `isTerminated` 인스턴스는 세지 않는다 — 세면 Mobius.app 을 종료해도 자동 재개가 영영 안 온다 |
| 주기 | 5초(`AccountsState.externalAppWatchInterval`). **엔진 틱에 얹지 않는다** — 막힌 동안엔 틱이 없어 복구 신호를 줄 주체가 사라진다 |
| 범위 | 마스터 토글이 켜져 있는 동안만. `stop()` 은 감시 타이머까지 걷어 "끄면 아무것도 안 돈다"를 유지한다 |
| 자격증명 경로 | `apply`(자동)·`manualSwitch`/`performSwitch`(수동)·`addAccount` 는 캐시된 플래그가 아니라 **그 자리에서 다시 판정**한다(`externalAppBlocksSwitching`) — 5초 창 안에 상대가 뜨는 경우를 좁힌다 |
| 표시 | 계정 탭 상단 주황 블록 + 설정 섹션 안내 행, 그리고 탭 컨트롤 `.disabled`. 설명 없이 기능만 죽으면 고장으로 읽힌다 |
| 재개 | Mobius.app 이 종료되면 5초 안에 자동(앱 재시작 불필요). 팝오버를 열면 그 자리에서도 재판정한다 |

엔진을 내리는 경로가 둘이 되었으므로(사용자의 `stop()`, 가드의 자동 후퇴) 진행 중 작업의 취소는
`stopEngine()` 한 곳에 모았다 — `AccountsEngineLifecycleTests` 의 Task 필드 스윕도 그 함수를 본다.

감지기는 `AccountsState` 에 주입한다. 진짜 `NSRunningApplication` 조회를 그대로 두면 **개발자
Mac 에 Mobius.app 이 떠 있는지에 따라 스위트 전체가 흔들리므로**, `MobiusTestSupport` 의 기본값은
"안 돌고 있다"이고 가드 자체는 `MobiusCoexistenceGuardTests` 가 양쪽 값을 주입해 검증한다.

### 전환 후 한도 캐시 무효화

`OAuthAccessTokenCache`(호스트 앱 쪽)는 Claude 자격증명을 인메모리로 들고 있어, 계정을 바꿔도
**옛 토큰으로 조회가 성공한다.** 증상은 "한도가 안 나온다"가 아니라 **A 계정 숫자가 B 계정 게이지로
그려지는 것**이라 화면만 봐서는 틀렸다는 걸 알 수 없다(`CredentialSwitchCacheTests` 가 잠근 #227 과
같은 부류).

- **통지 지점**: `AccountsState.onSwitched` — `switcher.switchTo` **성공 직후**. 자동(`apply`)·
  수동(`performSwitch`)이 서로 다른 경로라 **양쪽 모두**에 건다. 실패(throw)하면 부르지 않는다 —
  멀쩡한 토큰을 버리고 재조회를 부르는 것이 이 기능의 유일한 비용이다.
- **결합 위치**: `AppDelegate.wireAccountSwitchToLimits()`. `AccountsState` 와 `UsageStore` 는
  서로를 모르고 둘 다 들고 있는 것은 델리게이트뿐이라, 새 전역 상태 대신 `store.onRefresh` 와 같은
  콜백 관례를 쓴다.
- **프로바이더 구분**: `MobiusSwitchSideEffects.invalidatesClaudeLimitCache` — Codex 한도는
  세션 로그에서 오므로 이 캐시와 무관하다. 안 가르면 Codex 전환마다 헛된 Claude 재조회가 붙는다.
- **재조회**: `UsageStore.refresh()`. 진행 중이면 그쪽이 코얼레싱해 완료 후 1회 더 도므로, 옛
  토큰으로 끝난 조회가 최종값으로 남지 않는다. `refreshLimitTokenFromKeychain()` 은 쓰지 않는다 —
  `allowKeychainPrompt: true` 라 전환 때마다 키체인 승인창을 부를 수 있다.

## Claude 소진 감지 경로 — 로그와 usage API 둘 다 (2026-09-24)

Claude 계정의 한도 소진을 기록하는 경로는 **둘**이고, 둘 다 있어야 자동 전환이 성립한다.
Codex 는 rollout 로그에 `rate_limits` 가 매 턴 in-band 로 실려 이 구분 자체가 없다.

| 경로 | 트리거 | 게이트 | 판정 |
|---|---|---|---|
| 세션 로그 | `~/.claude/projects/**.jsonl` 의 429 라인 | 없음(항상) | 로그 hit 은 **트리거일 뿐** → `verifyAndRecordWindowHit` 이 그 계정의 토큰으로 usage 를 조회해 귀속 검증 |
| usage 폴 | 5분 fresh-sync 블록 | `usagePollIsWorthwhile` = 자동 전환 ON + Claude 계정 2개 이상 | 활성 계정의 토큰으로 조회한 스냅샷 → 오귀인 구조적 불가 |

판정은 **같은 함수**(`HitAttribution.verdict`)가 한다. 규칙을 경로마다 적으면 같은 스냅샷이
"어느 경로로 들어왔느냐"에 따라 다르게 판정된다.

**왜 둘 다 필요한가**: 로그 429 는 사용자가 **요청을 한 번 더 보내야** 찍힌다. 막힌 사용자는
당연히 타이핑을 멈추고, 사용량을 Desktop·웹에서 태웠으면 CLI 로그는 애초에 없다. 로그 하나에만
기대면 5시간 창이 100% 가 돼도 기록이 안 남고, 기록이 없으면 `onTick` 의 자동 전환도 못 돈다
(실측 2026-09-16: usage 캐시엔 `five=100`, 같은 시각 `accounts.json` 엔 `rateLimit` 없음).

**게이트를 advisory 토글에 묶지 않는다.** 한때 이 폴은 `advisoryEffectivelyEnabled`(= "한도 차기
전 미리 전환", **기본 꺼짐**) 뒤에 있었다. 그래서 기본 설정 사용자에게는 100% 소진 전환이
통째로 없었고, 옵션을 켠 사용자만 — 그것도 100% 가 아니라 임계값(95%)에서 — 전환을 받았다.
"원할 때는 안 되고 원하지 않을 때만 된다"가 이 배치의 정확한 증상이다. 소진 기록은 자동 전환의
**최소 동작**이므로 사용자 옵션이 아니라 "전환할 곳이 있는가"로 게이팅한다.

회귀 가드는 판정이 아니라 **진입점**에 건다 — `MobiusUsageExhaustionTests` 는 `tick()` 을 돌려
기록이 실제로 남는지 본다. 판정 함수만 잠그면(`HitAttributionTests` 가 그랬다) 그 함수에 도달하는
경로가 통째로 비어도 전부 초록이다.
