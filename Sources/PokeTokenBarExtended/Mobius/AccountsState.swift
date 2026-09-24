import AppKit
import SwiftUI
import Combine
import UserNotifications
// MobiusCore is pinned to the Swift 5 language mode (see Package.swift) while this target is
// Swift 6. No `@preconcurrency` is needed at that boundary: the engine already annotates the types
// this file hands across concurrency domains (`SessionLogWatcher`, `AccountStore`, `Switcher`,
// `ClaudeConfigIO` … are `Sendable` / `@unchecked Sendable`), so plain import type-checks clean.
import MobiusCore

enum MenuStatus { case primaryActive, fallbackActive, allExhausted, unknown }

/// Mobius's `AppState`, ported in as the account-switching state layer.
///
/// Deliberately still an `ObservableObject` while the rest of the app uses `@Observable`:
/// converting would spread the diff across the whole file and endanger the behaviour Mobius's
/// failure log was written around. SwiftUI supports both observation systems side by side.
///
/// Nothing runs on construction — `start()` installs the tick timer, the external-change observer
/// and the notification-permission request; `stop()` tears them down again.
@MainActor
final class AccountsState: ObservableObject {
    @Published private(set) var file = AccountsFile()
    /// 푸터 에러 배너. 5분 지나면 tick이 자동 소거한다 — 스스로 사라지지 않아
    /// 옛 에러(예: 취소한 로그인)가 영구 잔류하던 것 방지(사용자 요청).
    @Published var lastError: String? {
        didSet { lastErrorAt = lastError == nil ? nil : Date() }
    }
    private var lastErrorAt: Date?
    static let lastErrorTTL: TimeInterval = 5 * 60
    @Published private(set) var usage: [UUID: UsageSnapshot] = [:]
    // 수동 전환 낙관적 표시 — 클릭 즉시 이 계정을 활성으로 보여주고(스무스), 실제 refresh+스왑은
    // 백그라운드에서. 완료되면 nil로 정착(실제 activeAccountID가 인계).
    @Published private(set) var pendingSwitchID: UUID?
    /// 진행 중인 수동 전환 태스크 — `manualSwitch(to:)` 의 재진입 가드 겸 `stop()` 취소 대상.
    /// `pendingSwitchID` 와 항상 같이 세팅/해제된다(둘 다 같은 `defer` 가 담당). 두 계정을
    /// 빠르게 연속 클릭하면 독립된 두 태스크가 경합해 나중에 끝난 쪽이 이겨 사용자가 마지막에
    /// 누른 계정과 최종 활성이 달라질 수 있었다 — `desktopSwitchTask` 와 같은 패턴으로 막는다.
    private var manualSwitchTask: Task<Void, Never>?
    private var usageTask: Task<Void, Never>?
    // 비활성 codex 게이지 프로브 — 단일 플라이트 핸들 + 순수 조회기. 게이지 전용(마킹 없음).
    private var codexUsageTask: Task<Void, Never>?
    private let codexProber = CodexUsageProber()
    // 비활성 codex 계정의 만료 access 토큰 refresh(게이지 전용) — 회전본은 credential lock 안에서
    // 활성 재확인·신원 검증 후 원자 저장한다. 활성 계정은 절대 refresh하지 않는다.
    private let codexRefresher = CodexTokenRefresher()
    // transient(네트워크/5xx) 실패 시 팝오버마다 회전 시도가 반복되지 않게 하는 계정당 재시도 쿨다운.
    private var lastCodexRefreshAttemptAt: [UUID: Date] = [:]
    // refresh_token_invalidated/invalid_grant(죽은 토큰) 계정의 긴 백오프 — 죽은 토큰은 어차피 401
    // 이므로 이 시각 전까지 refresh/probe를 아예 건너뛴다(게이지는 마지막 값에 둔다).
    private var codexRefreshDeadUntil: [UUID: Date] = [:]
    static let codexDeadRefreshCooldown: TimeInterval = 24 * 3600
    private var usageCacheLoaded = false
    private static let usageCacheKey = "mobius.usageCacheV1"

    // 폴백 로그인 검증. 네트워크 refresh는 **자동 폴백 전환 직전에만**(호출 빈도 최소 → 블락 위험↓).
    // 팝오버에서는 네트워크 0 로컬 검사(빈/만료 refresh 토큰 즉시 플래그)만 한다.
    private var fallbackLocalTask: Task<Void, Never>?
    lazy var fallbackChecker = FallbackAuthChecker(store: store)

    /// 마지막 성공 스냅샷 복원 — 비활성 계정은 저장 토큰이 만료되어(수 시간) 조회가 401로
    /// 실패할 수 있는데, 그때 빈 게이지 대신 마지막 값을 보여준다. 초기화 시각은 절대
    /// 시각이라 지나면 표기가 자연히 사라지고, 계정이 다시 활성화되면 값도 갱신된다.
    private func loadUsageCacheIfNeeded() {
        guard !usageCacheLoaded else { return }
        usageCacheLoaded = true
        guard let data = UserDefaults.standard.data(forKey: Self.usageCacheKey),
              let dict = try? JSONDecoder().decode([UUID: UsageSnapshot].self, from: data)
        else { return }
        for (id, snap) in dict where usage[id] == nil { usage[id] = snap }
    }

    private func saveUsageCache() {
        let ids = Set(store.file.accounts.map(\.id))
        let pruned = usage.filter { ids.contains($0.key) }
        if let data = try? JSONEncoder().encode(pruned) {
            UserDefaults.standard.set(data, forKey: Self.usageCacheKey)
        }
    }
    /// 게이지 캐시 유효 시간 — 팝오버를 자주 여닫아도 이 간격보다 잦게 조회하지 않는다
    private let usageStaleness: TimeInterval = 240

    // MARK: 배지(인증 의심) — 무상태 세션활동×토큰만료 판정 (AuthSuspicion)

    /// 알림을 이미 보낸 의심 계정 id — **알림 중복만** 막는 최소 영속 집합이다(의심 조건
    /// 자체는 무상태라 저장하지 않는다). 재시작해도 같은 에피소드에 다시 알리지 않고,
    /// 회복(조건 해제)하면 제거돼 다음 재발엔 다시 알린다.
    private var notifiedSuspects: Set<UUID> = []
    private var notifiedSuspectsLoaded = false
    private static let notifiedSuspectsKey = "mobius.authSuspectNotifiedV1"

    private func loadNotifiedSuspectsIfNeeded() {
        guard !notifiedSuspectsLoaded else { return }
        notifiedSuspectsLoaded = true
        guard let data = UserDefaults.standard.data(forKey: Self.notifiedSuspectsKey),
              let ids = try? JSONDecoder().decode(Set<UUID>.self, from: data) else { return }
        notifiedSuspects = ids
    }

    /// 변경 시에만 저장 — 현재 계정 id로 필터해 삭제된 계정의 잔재를 정리한다.
    private func saveNotifiedSuspects() {
        let ids = Set(store.file.accounts.map(\.id))
        notifiedSuspects = notifiedSuspects.filter { ids.contains($0) }
        if let data = try? JSONEncoder().encode(notifiedSuspects) {
            UserDefaults.standard.set(data, forKey: Self.notifiedSuspectsKey)
        }
    }

    /// 활성 계정의 저장 스냅샷 access 만료 시각 캐시 — 한 계정만 담는다(활성). 값싼 절반이
    /// 매 틱 호출해도 파일을 다시 읽지 않도록, 캐시가 비었거나 다른 계정 키일 때만 계산·캐싱.
    /// 5분 fresh sync마다 invalidate돼 다음 조회가 갱신된 스냅샷으로 재계산된다.
    private var expiryCache: (id: UUID, expiry: Date?)?

    private func cachedStoredExpiry(for id: UUID) -> Date? {
        if let c = expiryCache, c.id == id { return c.expiry }
        let exp = (try? store.secret(for: id)).flatMap { UsageFetcher.expiresAt(from: $0.keychainBlob) }
        expiryCache = (id, exp)
        return exp
    }

    private func invalidateExpiryCache() { expiryCache = nil }

    /// 배지 값싼 절반 — **IO 0**(Keychain·네트워크 없음, 만료 캐시 + 워처 인메모리 활동만).
    /// 로그인 플로우 가드 **아래**에서 매 틱 돈다. 활성 Claude가 없으면 배지를 비운다.
    /// 조건이 안 성립하면 배지·알림 기록에서 빼고(재발 시 다시 알림), 이미 플래그면
    /// 라이브 재검증 없이 유지한다(승격은 5분 블록의 라이브 절반이 fresh sync 뒤에만).
    private func recomputeBadgeCheap(now: Date) {
        loadNotifiedSuspectsIfNeeded()
        guard let active = store.file.active(of: .claude) else {
            if !authSuspect.isEmpty { authSuspect = [] }
            return
        }
        // 배지는 활성 계정 전용 신호 — 활성이 바뀌면 옛 계정의 잔여 배지를 정리한다.
        let stale = authSuspect.subtracting([active.id])
        if !stale.isEmpty { authSuspect.subtract(stale) }

        let holds = AuthSuspicion.cheapConditionsHold(
            lastActivityAt: watcher.lastActivity,
            storedExpiresAt: cachedStoredExpiry(for: active.id), now: now)
        guard holds else {
            if authSuspect.contains(active.id) { authSuspect.remove(active.id) }
            if notifiedSuspects.contains(active.id) {
                notifiedSuspects.remove(active.id); saveNotifiedSuspects()
            }
            return
        }
        // 조건 성립 — 이미 플래그면 여기서 끝(라이브 재검증은 5분 블록에서만).
        // 아직 미플래그면 아무것도 안 하고 종료(승격은 라이브 절반이 fresh sync 뒤에).
    }

    /// 배지 라이브 절반 — 이번 사이클에 **fresh sync가 성사된 뒤에만** 호출한다.
    /// 값싼 조건을 갱신된 캐시로 재확인하고, 여전히 성립하면 저장 secret을 직접 읽어(파일
    /// 읽기 — subprocess 아님) confirmed로 최종 판정한다. 참이면 배지에 넣고, 알림은
    /// notified 집합에 없을 때만 1회 보내고 집합에 추가·저장한다.
    private func recomputeBadgeLive(now: Date) {
        loadNotifiedSuspectsIfNeeded()
        guard let active = store.file.active(of: .claude) else { return }
        guard AuthSuspicion.cheapConditionsHold(
            lastActivityAt: watcher.lastActivity,
            storedExpiresAt: cachedStoredExpiry(for: active.id), now: now) else { return }
        // confirmed = 신선도 단언: 방금 동기화된 그 스냅샷을 그대로 읽는다(독립 라이브 읽기 아님).
        let liveExpiry = (try? store.secret(for: active.id))
            .flatMap { UsageFetcher.expiresAt(from: $0.keychainBlob) }
        guard AuthSuspicion.confirmed(liveExpiresAt: liveExpiry, now: now) else { return }
        authSuspect.insert(active.id)
        if !notifiedSuspects.contains(active.id) {
            notifiedSuspects.insert(active.id)
            saveNotifiedSuspects()
            notify(title: l.accountsNotifyAuthSuspectTitle,
                   body: l.accountsNotifyAuthSuspectBody(active.nickname))
        }
    }

    /// 앱 언어 미러 — 알림·에러 문구를 만드는 자리가 뷰가 아니라서 `companion.l` 에 닿지
    /// 못한다. 단일 소스는 `CompanionStore.language` 이고, `UsageStore.localizationLanguage`
    /// 와 **같은 관례**로 기동 시 1회 시드 + 언어 설정 변경 시 갱신한다
    /// (`AppDelegate.applicationDidFinishLaunching`, `SettingsView` 의 언어 픽커).
    /// 재시드 전 기본값은 시스템 언어라 실행 순서와 무관하게 안전하다.
    var localizationLanguage: AppLanguage = .systemDefault
    /// 뷰의 `companion.l` 에 대응하는 이 계층의 접근자.
    private var l: L { L(localizationLanguage) }

    let env: MobiusEnvironment
    let store: AccountStore
    let io: ClaudeConfigIO
    let codexIO: CodexConfigIO
    let switcher: Switcher
    let watcher: SessionLogWatcher<RateLimitHit>              // Claude 세션 로그
    // ★ 모듈 한정 필수: 이 앱 자신도 `CodexRateLimitStatus`(Core/Models.swift)를 갖고
    // 있고 같은 모듈 이름이 먼저 잡히므로, 한정하지 않으면 엔진 타입과 조용히 어긋난다.
    let codexWatcher: SessionLogWatcher<MobiusCore.CodexRateLimitStatus> // Codex 세션 로그
    let codexRouter = CodexStatusRouter() // 전환 전 세션 파일 격리 (계정 오귀속 방지)
    let engines: [Provider: AutoSwitchEngine] = [
        .claude: AutoSwitchEngine(provider: .claude),
        .codex: AutoSwitchEngine(provider: .codex),
    ]
    lazy var desktopSwitcher = DesktopSwitcher(env: env)
    lazy var desktopCoordinator = DesktopCoordinator(switcher: desktopSwitcher)
    private var timer: Timer?
    /// 진행 중인 틱 — `stop()` 이 취소할 수 있도록 핸들을 들고 있는다. 타이머만 걷으면
    /// "다음 틱이 안 생긴다"까지만 보장되고, **이미 떠 있는 틱은 자동 전환까지 끝까지 간다.**
    private var tickTask: Task<Void, Never>?
    private var observer: NSObjectProtocol?

    // MARK: 이중 writer 가드 (기존 Mobius.app 과의 공존)

    /// 기존 Mobius.app 이 실행 중이라 엔진을 멈춰 둔 상태. 화면에 **반드시 보여야 한다** —
    /// 설명 없이 기능만 죽으면 사용자에게는 고장으로 읽힌다(`AccountsView` 배너 + 설정 안내).
    @Published private(set) var blockedByExternalApp = false
    /// 외부 Mobius.app 감지기. 실제 프로세스를 띄우지 않고는 `NSRunningApplication` 을 만들 수
    /// 없어 주입 가능하게 둔다 — 가드가 **정말로 엔진을 멈추는지**는 이 주입으로만 검증할 수
    /// 있다(`MobiusCoexistenceGuardTests`).
    private let externalMobiusRunning: @MainActor () -> Bool
    /// 사용자가 기능을 켜 두었는가(= 마스터 토글). 엔진이 **실제로** 도는지와는 다르다 —
    /// 켜 두었어도 외부 Mobius.app 이 살아 있으면 엔진은 내려가 있다.
    private var wantsEngine = false
    /// 외부 앱 감시의 본체 — `NSWorkspace` 실행/종료 알림 구독. **엔진과 별개로** 산다.
    /// 막힌 동안에는 틱이 없으므로 여기에 얹지 않으면 Mobius.app 을 종료해도 앱을 재시작하기
    /// 전까지 영영 복구되지 않는다.
    private var externalAppWatchObservers: [NSObjectProtocol] = []
    /// 알림을 놓친 경우의 **저빈도 안전망**. 아래 `startExternalAppWatch()` 주석 참조.
    private var externalAppWatchTimer: Timer?
    static let externalAppWatchInterval: TimeInterval = 60

    /// `Timer.tolerance` 배수 — wakeup 코얼레싱(다른 wakeup 과 합쳐 깨우기 = 배터리 절약).
    ///
    /// 이 앱은 **자기가 만드는 모든 타이머에 tolerance 를 준다**(`UsageStore.reschedule` 0.1,
    /// `AppDelegate.menuFrameTolerance` 0.1). 이식된 두 타이머만 빠져 있었다.
    ///
    /// ★ tolerance 는 **늦게만** 발화시키므로(Apple: "fire the timer later than the scheduled
    /// time, up to the tolerance") 배수는 곧 **최악 지연**이다. 메뉴바에서 그 대가는 재생
    /// 속도였지만(0.5 를 쓰다 애니메이션이 늘어져 0.1 로 내린 기록 — defect-log '에너지'),
    /// 여기서 그 대가는 **전환이 늦어지는 시간**이다:
    ///  - 3초 틱 → 최악 +0.3초. 전환 경로는 그 뒤에 usage API 왕복과 분 단위 검증 쿨다운
    ///    (`HitAttribution.cooldown` 180초)을 더 태우므로 0.3초는 그 안에 묻힌다. 이 배수를
    ///    키우면 "빠른 폴백"이라는 3초 틱의 존재 이유를 갉아먹으므로 키우지 않는다.
    ///  - 60초 안전망 → 최악 +6초. 알림을 놓쳤을 때의 백스톱이라 분 단위가 원래 계약이다.
    ///
    /// 코얼레싱 상대는 충분하다 — 3초 틱 자체가 3초마다 깨므로 60초 타이머의 6초 창 안에는
    /// **반드시** 합칠 wakeup 이 있고, 메뉴바 프레임 타이머가 기본 0.4초마다 깨므로 틱의
    /// 0.3초 창도 대부분 합쳐진다.
    static let timerTolerance = 0.1

    private var lastReconcileAt = Date.distantPast
    private var lastActiveSnapshotSyncAt = Date.distantPast
    /// 엔진 틱 주기 — "빠른 폴백"이 목적이라 짧다. 안의 무거운 작업들은 각자 자기 간격으로
    /// 게이팅되므로(아래 reconcile/스냅샷 싱크) 이 값은 **반응 지연의 상한**에 가깝다.
    static let tickInterval: TimeInterval = 3
    static let reconcileInterval: TimeInterval = 15

    // MARK: 세션 로그 스캔 주기 (적응형)

    /// 세션 로그를 마지막으로 스캔한 시각.
    private var lastSessionLogScanAt = Date.distantPast
    /// 직전 틱이 본 활성 계정들 — 스캔을 건너뛰던 중에 전환이 일어났는지 보는 값.
    private var lastTickActiveByProvider: [Provider: UUID] = [:]
    /// **세션이 안 도는 동안의** 스캔 주기. 도는 동안은 매 틱(`tickInterval`).
    ///
    /// 스캔은 틱 안에서 유일하게 비용이 로그 트리 크기에 비례하는 작업이다(열거 + 파일당 stat).
    /// 실측 환경(Claude 205MB/147개 + Codex 548MB/515개)에서 이 앱의 유휴 CPU 를 눈에 띄게
    /// 올리는 단일 항목이었다. 그런데 **아무 세션도 안 도는 동안에는 스캔이 아무것도 낼 수 없다** —
    /// 그때가 배터리가 가장 아까운 시간이다(노트북이 그냥 켜져 있는 상태).
    static let idleSessionLogScanInterval: TimeInterval = 15

    /// 지금 세션 로그를 스캔해야 하는가.
    ///
    /// 신호는 워처가 이미 들고 있는 `lastActivity`(= 지금까지 본 세션 파일 mtime 의 최댓값)다.
    /// 판정 기준은 워처 **자신의** `recentWindow` 를 그대로 쓴다 — 그 창보다 오래된 파일은
    /// 스캔해도 파싱 대상에서 걸러지므로, "마지막 활동이 그 창 밖" 이면 직전 스캔이 **구조적으로
    /// 이벤트를 낼 수 없었다**는 뜻이다(임의의 휴리스틱이 아니라 워처의 필터와 같은 기준).
    ///
    /// ★ 이 게이트가 **잃지 않는 것**:
    ///  - 데이터. 오프셋은 유지되므로 건너뛴 동안의 append 는 다음 스캔이 통째로 읽는다.
    ///  - 파일. `recentWindow`(600초)가 스캔 주기(15초)보다 훨씬 길어, 건너뛰는 사이에 파일이
    ///    "최근" 창 밖으로 빠져나갈 수 없다.
    ///  - 재진입. 신호는 스캔이 갱신하므로 자기참조처럼 보이지만, 유휴 모드에서도 15초마다는
    ///    돌기 때문에 새 활동은 늦어도 그 안에 잡히고 즉시 매 틱 모드로 돌아온다.
    ///
    /// ★ 대가는 **지연 하나**다: 로그가 완전히 조용했던 뒤 도착하는 **첫** hit 의 검출이 최악
    /// +12초(15초 − 틱 3초). 그 뒤로는 활동이 최신이라 매 틱으로 돌아온다. 소진 판정은 그
    /// 뒤에 usage API 왕복과 분 단위 검증 쿨다운(`HitAttribution.cooldown` 180초)을 더 태우므로
    /// 이 12초는 전환 지연의 지배 항이 아니다.
    static func sessionLogScanIsDue(now: Date, lastActivity: Date?, lastScanAt: Date,
                                    activeWindow: TimeInterval,
                                    idleInterval: TimeInterval,
                                    activeChanged: Bool) -> Bool {
        // 활성이 바뀐 틱은 주기와 무관하게 스캔한다 — 위 라우터 격리 창(정확성) 때문이다.
        if activeChanged { return true }
        // nil = 아직 세션 파일을 하나도 못 봤다(빈 로그, 또는 첫 틱). 유휴 갈래로 내려가되
        // 첫 틱은 `lastScanAt` 이 `.distantPast` 라 아래 조건이 참이므로 지연 없이 프라이밍된다.
        if let lastActivity, now.timeIntervalSince(lastActivity) <= activeWindow { return true }
        return now.timeIntervalSince(lastScanAt) >= idleInterval
    }

    /// 테스트 전용 — 스캔을 **실제로 돈** 횟수. 게이트가 "돌지 않았다"를 증명하려면 결과가
    /// 아니라 행위를 봐야 한다 — 빈 로그에서는 돌아도 hit 이 0이라 결과로는 구분이 안 된다.
    private(set) var sessionLogScanCountForTesting = 0
    static let activeSnapshotSyncInterval: TimeInterval = 5 * 60 // 활성 계정 토큰 스냅샷 동기화
    // 만료 임박 폴백 자동 refresh: 1시간마다 스윕, 만료 3일 전부터, 계정당 최소 6시간 간격.
    private var lastProactiveRefreshSweepAt = Date.distantPast
    private var lastProactiveRefreshAt: [UUID: Date] = [:]
    static let proactiveRefreshSweepInterval: TimeInterval = 3600
    static let proactiveRefreshRenewWindow: TimeInterval = 3 * 24 * 3600
    static let proactiveRefreshPerAccountGate: TimeInterval = 6 * 3600
    // 만료 토큰 게이지용 refresh(reactive)의 계정당 재시도 쿨다운 — transient(네트워크/5xx)
    // 실패 시 usage 캐시가 안 갱신돼 계속 stale로 남으므로, 이게 없으면 팝오버를 여닫을
    // 때마다 회전 시도가 반복된다. 성공하면 즉시 해제(exp가 미래로 풀려 재진입도 자연히 멈춤).
    private var lastUsageRefreshAttemptAt: [UUID: Date] = [:]
    static let usageRefreshRetryCooldown: TimeInterval = 600

    /// 배지 의심 계정 — 카드 배지·'다시 로그인' 버튼 노출에만 쓴다(표시 전용).
    /// 무상태 판정(recomputeBadgeCheap/Live)이 채운다. ★ 절대 needsReauth로 승격하지 말 것
    /// (AuthSuspicion 주석 참조 — 이슈 #4 재발).
    @Published private(set) var authSuspect: Set<UUID> = []

    // MARK: 임계값 선제 전환 (advisory) 상태 — 전부 인메모리(스냅샷 아님)

    /// 후보 "없음" 마지막 판정 시각 — 엔진의 백오프 창(shouldProbeCandidates)에 넘긴다.
    /// distantPast로 시작. ★ advisory가 해제돼도 distantPast로 리셋하지 않는다 — 경계에서
    /// 켜졌다 꺼졌다 하는 오실레이션이 백오프를 매번 무장해제해 폴백을 계속 두드리는 것을 막는다.
    private var lastNoCandidateAt = Date.distantPast
    /// 계정별 "마지막으로 경고를 알린 창의 resetsAt". 같은 창에 중복 알림/전환을 막는
    /// 인트라세션 가드 — 창(resetsAt)이 바뀌면 다시 알린다. **영속하지 않는다.**
    private var lastAdvisedResetsAt: [UUID: Date] = [:]
    /// 활성 스냅샷 동기화가 연속으로 실패한 횟수 — 3회 도달 시 푸터 배너 힌트를 띄운다.
    /// ★ **활성 Claude 프로필이 있을 때만** 증가한다(Codex-only 풀·adopt 대기 오탐 방지).
    /// true 결과가 나오면 0으로 리셋. 영속하지 않는다.
    private var consecutiveSyncFailures = 0
    /// 활성 계정 사용량 **조회**가 연속 실패한 횟수(네트워크/타임아웃/5xx 등) — 위 동기화
    /// 실패(로컬)와 별개다. `UsagePollBreaker.failureThreshold` 도달 시 배경 폴링을 멈춘다
    /// (서킷 브레이커). 성공 시 0으로 리셋, 팝오버를 다시 열면(refreshUsageIfStale) 재개.
    /// 인메모리 — 앱 재시작도 재개 신호(사용자 결정 2026-07-21).
    private var consecutiveUsagePollFailures = 0

    /// 임계값 선제 전환 기능 토글(기본 꺼짐). 설정 UI가 같은 키를 쓴다.
    private var advisorySwitchEnabled: Bool {
        UserDefaults.standard.bool(forKey: MobiusFeature.advisorySwitchEnabledKey)
    }
    /// ★ 유효 게이트의 **단일 정의**. 미리 전환은 '자동 전환(Claude)'의 하위 옵션이라 부모가
    /// 켜져 있을 때만 동작한다(사용자 결정 2026-07-24: 부모 off면 UI도 강제 off+disabled —
    /// 구 "표시만" 모드 제거).
    ///
    /// 엔진(`advisoryEffectivelyEnabled`)과 설정 UI(`SettingsView.accountSwitchingGroup`)가
    /// **둘 다 이 함수를 부른다.** 각자 조건을 적으면 한쪽만 바뀌었을 때 "표시는 꺼졌는데 5분
    /// 폴링은 돈다"가 되고, 그건 화면 어디에도 안 보이므로 사용자가 신고할 수도 없다.
    /// 규칙이 한 곳에만 있는지는 `AccountSwitchingSettingsTests` 가 소스에서 확인한다.
    static func advisoryIsEffective(switchEnabled: Bool, claudeAutoSwitchEnabled: Bool) -> Bool {
        switchEnabled && claudeAutoSwitchEnabled
    }
    /// advisory pill 셋/클리어와 선제 전환이 보는 게이트 — 끄면 pill이 서고, 남은 advisory
    /// pill은 아래 정리 경로가 다음 틱에 걷어간다.
    ///
    /// ★ **5분 usage 폴 자체는 이 게이트가 아니다**(2026-09-16 결함 수정). 폴은 소진 기록도
    ///   겸하는데, 그건 advisory 옵션과 무관한 자동 전환의 최소 동작이다 — 폴을 이 게이트에
    ///   묶어 두면 옵션을 안 켠 사용자는 5시간 창이 100%가 돼도(로그 429가 안 남는 경우)
    ///   전환을 못 받는다. 폴의 게이트는 `usagePollIsWorthwhile`.
    private var advisoryEffectivelyEnabled: Bool {
        Self.advisoryIsEffective(switchEnabled: advisorySwitchEnabled,
                                 claudeAutoSwitchEnabled: store.file.isAutoSwitchEnabled(.claude))
    }
    /// 임계값(%) — 기본 90. 설정 UI 범위 50~95(step 5). Int/Double 저장 모두 관대하게 읽는다.
    private var advisoryThreshold: Double {
        let raw = UserDefaults.standard.object(forKey: MobiusFeature.advisoryThresholdPercentKey)
        if let d = raw as? Double { return d }
        if let i = raw as? Int { return Double(i) }
        return Double(MobiusFeature.advisoryThresholdDefault)
    }

    /// 라이브 환경 + 이 앱의 상태 디렉터리 주입. `~/.claude`·`~/.codex`(그리고
    /// `MOBIUS_HOME`/`CODEX_HOME` 오버라이드)는 전역 자원이라 그대로 두고, Mobius가
    /// **자기 상태를 저장하는 위치만** 갈라낸다.
    static func isolatedEnvironment() -> MobiusEnvironment {
        var env = MobiusEnvironment.live()
        env.appSupportDirOverride = MobiusPaths.stateDirectory()
        return env
    }

    /// - Parameter env: 기본값은 이 앱 전용 상태 디렉터리로 격리한 환경이다.
    ///   ★ `MobiusEnvironment.live()`를 그대로 쓰면 `~/Library/Application Support/Mobius`,
    ///   즉 **Mobius.app이 쓰는 바로 그 파일들**을 두 프로세스가 함께 쓰게 되어 자격증명이
    ///   오염된다(`MobiusPaths` 주석 참조). 테스트·진단용으로만 다른 환경을 주입한다.
    /// - Parameter keychain: 기본값은 실제 로그인 키체인(`security` CLI 경유). 테스트는
    ///   `InMemoryKeychain` 을 넣어 **실제 전환 경로를 그대로 돌린다** — 그러지 않으면 전환
    ///   후 부작용(캐시 무효화 콜백 등)을 소스 스캔으로밖에 확인할 수 없다.
    /// - Parameter externalMobiusRunning: 이중 writer 감지기. 위 '이중 writer 가드' 참조.
    init(env: MobiusEnvironment = AccountsState.isolatedEnvironment(),
         keychain: any KeychainClient = SystemKeychain(),
         externalMobiusRunning: @escaping @MainActor () -> Bool
            = MobiusCoexistence.isExternalMobiusRunning) {
        let kc = keychain
        // init 은 `self.localizationLanguage` 를 읽을 수 없고(아직 초기화 전), 시드하는
        // `AppDelegate` 도 아직 `CompanionStore` 를 만들지 않았다 — 미러의 기본값과 같은
        // 시스템 언어로 렌더한다. 여기서 만들어지는 두 문구(로드 실패·프로바이더 복구)는
        // 손상된 accounts.json 에서만 나오고, 사용자가 앱 언어를 시스템과 다르게 고른
        // 경우에만 어긋난다 — `UsageStore.localizationLanguage` 가 감수한 것과 같은 틈이다.
        let l = L(.systemDefault)
        self.externalMobiusRunning = externalMobiusRunning
        self.env = env
        // 초기화 실패(accounts.json 손상 등)는 빈 스토어로 시작하고 에러 표시
        let store: AccountStore
        var initError: String?
        do {
            store = try AccountStore(env: env, keychain: kc)
        } catch {
            store = AccountStore(env: env, keychain: kc, file: AccountsFile())
            initError = l.accountsErrorLoadFailed(error.localizedDescription)
        }
        self.store = store
        self.io = ClaudeConfigIO(env: env, keychain: kc)
        self.codexIO = CodexConfigIO(env: env)
        self.switcher = Switcher(env: env, keychain: kc, store: store, io: io,
                                 extraIOs: [codexIO])
        self.watcher = SessionLogWatcher(env: env)
        self.codexWatcher = SessionLogWatcher.codex(env: env)
        // 구버전 바이너리가 accounts.json을 저장하며 per-account provider를 드롭했다면 Codex 계정이
        // Claude 풀로 흡수돼 매 틱 자격증명 디코드 실패로 degraded 상태가 된다. secret이 provider의
        // authority이므로 로드 직후 진짜 provider로 되돌리고, 되돌린 게 있으면 사용자에게 경고한다.
        if let reassigned = try? switcher.healMisassignedProviders(), !reassigned.isEmpty {
            let names = reassigned
                .map { "\($0.nickname) (\($0.from.displayName)→\($0.to.displayName))" }
                .joined(separator: ", ")
            let warn = l.accountsErrorProviderHealed(names)
            initError = initError.map { "\($0)\n\(warn)" } ?? warn
        }
        self.file = store.file
        self.lastError = initError
        // init에서의 직접 대입은 didSet이 불리지 않는다 — TTL 기준점을 수동 기록
        if initError != nil { lastErrorAt = Date() }

        // 알림 중복 방지 집합은 한 번만 로드한다.
        loadNotifiedSuspectsIfNeeded()
    }

    // 의도적으로 deinit이 없다 — 예전엔 `isolated deinit`(SE-0371)로 같은 정리를 하는 안전망을
    // 뒀지만, `isolated deinit`이 클래스에 지원되는 건 Swift 6.2+뿐이라 CI의 Xcode 16.4/Swift
    // 6.1.2에서는 컴파일이 안 됐다(로컬 6.3.3에서만 통과 — `docs/reference/defect-log.md` §빌드·
    // 도구체인). 지우기 전에 도달 가능성부터 확인했다: 이 타입의 유일한 인스턴스는
    // `AppDelegate.accounts`이고 앱 수명 내내 재대입·nil화 없이 살아 프로세스 종료(exit)로만
    // 없어지므로 프로덕션에서 deinit은 사실상 안 불린다. 테스트(`MobiusTestSupport.
    // isolatedAccountsState`)는 매번 teardown에서 `stop()`을 먼저 부른 뒤에야 지역변수가 스코프를
    // 벗어나므로, 벗어나는 시점엔 timer·observer가 이미 nil이라 예전 deinit 본문은 그 경로에서도
    // no-op이었다. 즉 이 안전망은 어느 경로에서도 실제 일을 한 적이 없다 — 이식성과 맞바꿀 가치가
    // 없어 그냥 없앴다. 정상 종료 경로는 `stop()` 하나뿐이니 새 호출부를 추가할 때 반드시 그걸 부를 것.

    // MARK: 수명주기

    /// 기능을 켠다 — 호스트 앱의 마스터 토글(`mobius.enabled`)과 설정 UI 가 부르는 유일한
    /// 진입점이다. 꺼져 있으면 이 객체는 아무 일도 하지 않는다(타이머 0, Keychain 접근 0,
    /// 알림 권한 요청 0).
    ///
    /// ★ "켰다"와 "엔진이 돈다"는 **다르다.** 기존 Mobius.app 이 실행 중이면 같은 전역
    /// 자격증명을 두 프로세스가 스왑하게 되므로(`MobiusCoexistence`) 엔진은 뜨지 않고,
    /// 대신 가벼운 감시(`NSWorkspace` 구독 + 저빈도 안전망)만 남아 상대가 종료되는 순간
    /// 자동으로 이어받는다.
    /// 중복 호출은 무시한다 — 타이머가 겹치면 틱이 쌓여 이슈 #15의 되먹임을 되살린다.
    func start() {
        guard !wantsEngine else { return }
        wantsEngine = true
        startExternalAppWatch()
        // ★ 초기 상태는 여기서만 잡힌다 — `NSWorkspace` 알림은 **구독 이후의 변화**만 주므로,
        // 앱을 켤 때 이미 Mobius.app 이 떠 있는 경우는 이 즉시 판정이 없으면 영영 안 보인다
        // (그리고 그 사이에 엔진이 떠서 전환을 한 번 해 버리면 가드가 있으나 마나다).
        reevaluateExternalApp()
    }

    /// 외부 Mobius.app 감시를 건다. 판정 자체는 `reevaluateExternalApp()` 이 하고, 이 감시는
    /// **엔진이 내려가 있는 동안에도** 살아 있어야 한다 — 자동 재개의 유일한 동력이다.
    ///
    /// **폴링이 아니라 이벤트 구동이다.** 예전에는 5초마다 `NSRunningApplication` 을 조회해,
    /// 아무 일도 일어나지 않는 유휴 상태에서도 분당 12회 LaunchServices 왕복 + wakeup 을 냈다.
    /// `NSWorkspace` 의 실행/종료 알림은 **변화가 있을 때만** 오므로 유휴 비용이 0 이 된다.
    /// 알림이 주지 않는 것은 **초기 상태**뿐이고(앱을 켤 때 이미 Mobius.app 이 떠 있는 경우),
    /// 그건 `start()` 가 감시를 건 직후 곧바로 부르는 `reevaluateExternalApp()` 이 잡는다.
    ///
    /// ★ **안전망 타이머는 남긴다 — 이건 폴링을 없애는 최적화지 안전장치를 약하게 만드는
    /// 변경이 아니다.** 알림 경로에는 우리가 통제할 수 없는 틈이 남는다: 종료 알림이 배달되는
    /// 시점과 `NSRunningApplication.isTerminated` 가 반영되는 시점의 레이스, 그리고 상대가
    /// 알림을 내지 않는 방식으로 사라지는 경우. 놓치면 두 앱이 같은 자격증명을 스왑해 라이브
    /// 로그인이 **에러 없이** 오염되므로(`MobiusCoexistence`), 60초 주기로 한 번 더 확인한다 —
    /// 옛 5초 폴링 대비 wakeup 은 1/12 이고, 알림이 정상 배달되는 평시에는 재개가 **즉시**라
    /// 오히려 빨라진다. 자격증명을 쓰는 경로는 이 감시와 무관하게 그 자리에서 다시 판정한다
    /// (`externalAppBlocksSwitching()`).
    private func startExternalAppWatch() {
        guard externalAppWatchTimer == nil else { return }
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification,
                     NSWorkspace.didTerminateApplicationNotification] {
            externalAppWatchObservers.append(
                center.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                    // 값싼 사전 필터 — 시스템의 모든 앱 실행/종료마다 조회를 돌리지 않는다.
                    let bundleID = (note.userInfo?[NSWorkspace.applicationUserInfoKey]
                        as? NSRunningApplication)?.bundleIdentifier
                    guard MobiusCoexistence.notificationConcernsMobius(bundleID: bundleID)
                    else { return }
                    Task { @MainActor in self?.reevaluateExternalApp() }
                })
        }
        let timer = Timer(timeInterval: Self.externalAppWatchInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.reevaluateExternalApp() }
        }
        timer.tolerance = Self.externalAppWatchInterval * Self.timerTolerance
        RunLoop.main.add(timer, forMode: .common)
        externalAppWatchTimer = timer
    }

    /// 감시를 통째로 걷는다 — 타이머와 구독은 **함께** 서고 함께 걷힌다. 한쪽만 남으면
    /// "끄면 아무것도 안 돈다"가 성립하지 않는다(구독만 남으면 앱 실행/종료마다 재판정이 돈다).
    private func stopExternalAppWatch() {
        externalAppWatchTimer?.invalidate()
        externalAppWatchTimer = nil
        let center = NSWorkspace.shared.notificationCenter
        for observer in externalAppWatchObservers { center.removeObserver(observer) }
        externalAppWatchObservers.removeAll()
    }

    /// 지금 외부 Mobius.app 이 살아 있는지 다시 보고, 엔진의 가동 상태를 그 결과에 맞춘다.
    /// 타이머가 주기적으로 부르고, 자격증명을 쓰는 경로도 **그 자리에서** 한 번 더 부른다
    /// (`externalAppBlocksSwitching()` — 5초 창 안에 상대가 뜨는 경우를 좁힌다).
    func reevaluateExternalApp() {
        blockedByExternalApp = externalMobiusRunning()
        if wantsEngine && !blockedByExternalApp { startEngine() } else { stopEngine() }
    }

    private func startEngine() {
        guard timer == nil else { return }

        // `.app` 번들에서만 — `UNUserNotificationCenter.current()`는 번들 프로세스가 아니면
        // `bundleProxyForCurrentProcess is nil`로 **예외를 던져 프로세스를 죽인다**. raw 바이너리
        // 개발 실행(`swift run`)과 `swift test`가 그 경우라, 이 줄은 호스트 앱의 나머지 알림
        // 접근과 같은 게이트 뒤에 둔다(`UsageStore`·`CompanionStore`·`AppLog`).
        if AppEnv.isBundledApp {
            UNUserNotificationCenter.current()
                .requestAuthorization(options: [.alert, .sound]) { _, _ in }
        }

        // CLI 등 외부 변경 통지 수신
        observer = DistributedNotificationCenter.default().addObserver(
            forName: MobiusNotification.accountsChanged, object: nil, queue: .main
        ) { [weak self] _ in Task { @MainActor in self?.reload() } }

        // 시작 시 Claude 자격증명 Keychain에 한 번 접근해 권한을 미리 받는다 —
        // 여기서 '항상 허용'을 한 번 누르면, 이후 계정 추가/전환 각 단계마다 반복해서
        // 권한 요청이 뜨지 않는다. (ACL이 이미 허용돼 있으면 조용히 지나간다.)
        let ioForWarmup = io
        Task.detached(priority: .utility) { _ = try? ioForWarmup.readLiveSnapshot() }

        // 3초 주기: 로그 스캔 → 자동 전환 판단 (빠른 fallback). reconcile/adopt는 내부에서
        // 15초로 게이팅해 Keychain 접근·라이브 추종 바운스를 늘리지 않는다.
        // tolerance 는 하우스 규율(모든 타이머가 코얼레싱한다) — 배수 근거는 `timerTolerance`.
        let tick = Timer(timeInterval: Self.tickInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.scheduleTick() }
        }
        tick.tolerance = Self.tickInterval * Self.timerTolerance
        RunLoop.main.add(tick, forMode: .common)
        timer = tick
        scheduleTick()
    }

    /// 틱 하나를 띄우고 **핸들을 보관**한다 — `stop()` 이 취소할 대상이기 때문이다.
    /// 앞 틱이 살아 있으면 새로 띄우지 않는다(`tickInFlight` 와 같은 뜻이지만, 이쪽이 보장하는
    /// 것은 "핸들이 늘 하나"다 — 두 개가 되면 `stop()` 이 그중 하나만 취소하게 된다).
    /// 핸들은 취소 시점이 아니라 **틱이 실제로 끝날 때** 비운다: `stop()` 직후 `start()` 가
    /// 와도 죽어가는 틱의 `defer` 가 새 핸들을 덮어쓰지 못한다. 그 대가로, 껐다 곧바로 켜면
    /// 즉시 틱 **한 번**이 생략될 수 있다(취소된 틱이 아직 안 끝난 동안). 3초 뒤 타이머가
    /// 이어받으므로 손실은 거기까지고, 반대쪽 실수(핸들이 둘)는 `stop()` 이 그중 하나만
    /// 취소하게 만들어 이 수정 자체를 무력화한다.
    private func scheduleTick() {
        guard tickTask == nil else { return }
        tickTask = Task { @MainActor in
            defer { tickTask = nil }
            await tick()
        }
    }

    /// 기능을 끈다 — 마스터 토글 off, 앱 종료. 엔진과 **외부 앱 감시까지** 모두 걷는다.
    /// 스토어 상태는 그대로 두므로 `start()`로 언제든 재개할 수 있다.
    ///
    /// 진행 중인 작업의 취소는 `stopEngine()` 이 한다(이중 writer 가드도 같은 함수를 쓴다 —
    /// 막힌 동안 취소가 절반만 되면 가드가 있으나 마나다). `AccountsEngineLifecycleTests` 의
    /// Task 필드 스윕이 그 함수를 본다.
    func stop() {
        wantsEngine = false
        stopExternalAppWatch()
        // 기능 자체가 꺼졌으니 "막혀 있다" 안내도 내린다 — 남기면 꺼진 기능에 대한 배너가 된다.
        blockedByExternalApp = false
        stopEngine()
    }

    /// 주기 처리를 멈춘다 — 기능 토글 off, 이중 writer 가드 작동 시 호출한다.
    ///
    /// ★ 타이머·옵저버만 걷으면 "끄면 아무것도 안 돈다"가 **성립하지 않는다**. `start()` 는
    /// 마지막 줄에서 곧바로 한 틱을 띄우고, 그 틱은 게이트를 지나 자동 전환까지 수행한다 —
    /// 즉 사용자가 방금 끈 기능이 계정을 바꿀 수 있다. 게이지 조회(`usageTask`·
    /// `codexUsageTask`)와 폴백 로컬 검증(`fallbackLocalTask`)도 진행 중이면 그대로 남는다.
    /// 그래서 타이머와 함께 **진행 중인 작업도 취소**한다.
    ///
    /// 취소가 안전한 이유(자격증명 원자성): 취소는 `await` 지점에서만 듣는데, 자격증명을
    /// 쓰는 구간은 전부 **동기**이거나(`switcher.switchTo`, `store.withCredentialLock` 블록)
    /// 취소가 전파되지 않는 `Task {}` 쉴드 안에 있다(`FallbackAuthChecker.inFlight`,
    /// `CodexTokenRefresher` 호출부). 회전된 refresh 토큰을 서버가 소비한 뒤 저장 전에 끊겨
    /// 계정이 벽돌이 되는 경로는 그래서 존재하지 않는다. 같은 잣대로 `manualSwitchTask` 도
    /// 안전하다 — 그 안의 자격증명 쓰기(`performSwitch` → `switcher.switchTo`)도 동기라서,
    /// 취소는 그 앞의 `await`(preflight/quiesce)에서만 걸리고 쓰기 도중에는 걸리지 않는다.
    /// `addAccountTask` 도 마찬가지다 — `LoginFlowController.run()` 의 자격증명 등록 구간은
    /// 라이브 스냅샷을 안정적으로 감지(두 번 읽어 일치 확인)한 **뒤에만** 실행되는 연속 동기
    /// 블록이라 취소가 그 중간에 끼어들 수 없고, 감지 전에 끊기면 `cleanup()` 이 PTY 프로세스·
    /// 인증창·임시파일을 정리해 반쯤 쓴 상태를 남기지 않는다(타임아웃·사용자 취소와 같은 경로).
    /// 드물게 CLI가 이미 로그인을 끝냈는데 우리가 그걸 감지하기 전에 끊기면(라이브 로그인은
    /// 바뀌었지만 우리 계정 목록엔 미등록) 엔진이 다시 돌 때 `tick()` 의 reconcile
    /// (`adoptLiveAccountIfUnregistered`)이 그 계정을 자동으로 흡수한다 — Desktop 캡처의 stash 와
    /// 달리 되돌릴 장치가 없는 게 아니라 **엔진 재개가 스스로 되돌린다.**
    ///
    /// 취소하지 **않는** 것(의도적):
    ///  - `desktopSwitchTask` — Desktop 종료 → 프로필 스왑 → 재실행의 중간에서 끊으면 Desktop
    ///    자격증명이 반쯤 옮겨진 채 남고 앱은 안 뜬다. 짧고 스스로 끝나므로 그대로 둔다.
    ///  - `desktopCaptureTask` — 사용자가 연 가이드 캡처. 이미 **원래 Desktop 로그인을 치워
    ///    둔(stash)** 상태이고 되돌리는 경로는 `endDesktopCapture()` 하나뿐이라, 여기서 취소만
    ///    하면 사용자의 Desktop 로그인이 로그아웃된 채 남는다.
    ///  - `desktopCaptureRestoreTask` — `endDesktopCapture()` 자신이 만드는 복원 태스크(종료→
    ///    stash 복원→재실행). 시작 전에 `desktopCaptureStash` 를 이미 nil 로 비우므로 이 태스크가
    ///    그 stash 를 되돌릴 **유일한** 경로다 — 위 `desktopCaptureTask` 보다도 더 끊으면 안 된다:
    ///    끊었다가는 복원 자체가 없던 일이 되고 재시도할 상태도 남지 않는다.
    ///  - `startEngine()` 의 Keychain 워밍업(`Task.detached`) — 취소 지점이 없는 동기 읽기 1회다.
    private func stopEngine() {
        timer?.invalidate()
        timer = nil
        if let observer {
            DistributedNotificationCenter.default().removeObserver(observer)
            self.observer = nil
        }
        // 핸들을 nil로 만들지 않는다 — 각 태스크의 `defer` 가 **실제로 끝날 때** 비운다.
        // 여기서 비우면 아직 살아 있는 태스크가 참조를 잃어, 곧이은 `start()` 가 두 번째
        // 핸들을 만들 수 있다(다음 `stop()` 이 그중 하나만 취소하게 된다).
        tickTask?.cancel()
        usageTask?.cancel()
        codexUsageTask?.cancel()
        fallbackLocalTask?.cancel()
        desktopAutoCaptureTask?.cancel()
        manualSwitchTask?.cancel()
        addAccountTask?.cancel()
    }

    /// 테스트 전용 — 지금 스케줄된 틱 타이머. **객체 자체**를 내주는 이유는 `stop()` 이 필드를
    /// nil로 만들기만 한 게 아니라 `invalidate()` 까지 했는지 봐야 하기 때문이다. 무효화된
    /// 타이머는 다시 발화하지 않으므로 `isValid == false` 가 "확실히 멈췄다"의 직접 증거다.
    /// 켜고 끄기를 반복해도 타이머가 겹치지 않는지는 이 객체의 **동일성**으로 확인한다.
    /// (테스트 전용 접근자 관례: `AccountCardView.statusBadgesForTesting`,
    /// `StateDirectoryMigration.migrateIfNeeded(base:)`)
    var tickTimerForTesting: Timer? { timer }

    /// 테스트 전용 — 외부 변경(CLI) 통지 옵저버가 살아 있는지. 타이머와 함께 걷혀야
    /// "끄면 아무것도 안 돈다"가 성립한다(옵저버가 남으면 CLI 변경마다 reload가 돈다).
    var isObservingExternalChangesForTesting: Bool { observer != nil }

    /// 테스트 전용 — `start()` 가 곧바로 띄우는 틱의 핸들. 취소됐는지(`isCancelled`)와
    /// 실제로 끝나는지(`await value`)를 둘 다 봐야 "stop()이 진행 중인 작업을 걷었다"가
    /// 증명된다. 타이머와 달리 이건 **이미 돌고 있는** 작업이라 무효화만으로는 안 멈춘다.
    var tickTaskForTesting: Task<Void, Never>? { tickTask }

    /// 테스트 전용 — 진행 중인 수동 전환 태스크. `manualSwitch(to:)` 의 재진입 가드가 **실제로**
    /// 두 번째 호출을 막는지, 그리고 완료 후 스스로 풀리는지(`await value` 뒤 nil)를 이 핸들로
    /// 확인한다(`ManualSwitchReentrancyTests`).
    var manualSwitchTaskForTesting: Task<Void, Never>? { manualSwitchTask }

    /// 테스트 전용 — 외부 Mobius.app 감시 타이머. 엔진이 내려간 동안에도 **이것만은** 살아
    /// 있어야 자동 재개가 성립한다(없으면 사용자가 앱을 재시작해야 복구된다).
    var externalAppWatchTimerForTesting: Timer? { externalAppWatchTimer }

    /// 테스트 전용 — `NSWorkspace` 구독이 몇 개 살아 있는지. 감시의 **본체**가 구독이므로
    /// 타이머만 보면 "이벤트 구동이 실제로 걸렸는지"도, "꺼질 때 함께 걷혔는지"도 못 본다.
    var externalAppWatchObserverCountForTesting: Int { externalAppWatchObservers.count }

    /// 전환이 **실제로 성사된 뒤** 호출된다 — 자동(`apply`)·수동(`performSwitch`) 두 경로가
    /// 모두 지나며, 전환이 throw 하면 호출되지 않는다.
    ///
    /// 호스트 앱이 자기 캐시를 버릴 자리다. `AccountsState` 는 이 앱의 사용량 계층을
    /// 모르고 알 필요도 없으므로(둘 다 들고 있는 것은 `AppDelegate` 다), 새 전역 상태를 만드는
    /// 대신 `UsageStore.onRefresh` 와 같은 콜백 관례를 따른다.
    var onSwitched: (@MainActor (Provider) -> Void)?

    /// 자격증명을 실제로 쓰는 경로의 공통 관문. 막혀 있으면 `true` 를 돌려주고 호출부는
    /// 아무것도 하지 않는다.
    ///
    /// 캐시된 `blockedByExternalApp` 을 읽는 대신 **그 자리에서 다시 판정**하는 이유: 감시는
    /// 알림 배달(+60초 안전망)에 의존하므로 그 사이에 Mobius.app 이 뜨면 창이 열린다. 전환은
    /// 드문 이벤트이므로 한 번 더 조회하는 비용이 무의미하고, 반대로 그 창에서 한 번만 겹쳐
    /// 써도 라이브 로그인이 **에러 없이** 오염된다(`MobiusCoexistence`).
    /// ★ 감시를 이벤트 구동으로 바꾼 뒤에도 이 재조회는 그대로 둔다 — 폴링 제거의 대가를
    /// 여기서 흡수하기 때문이다(자격증명을 쓰는 순간만큼은 항상 최신 판정으로 간다).
    private func externalAppBlocksSwitching() -> Bool {
        reevaluateExternalApp()
        return blockedByExternalApp
    }

    /// 팝오버가 열릴 때 호출 — 캐시가 만료된 계정만 사용량 조회 (상시 폴링 없음)
    func refreshUsageIfStale() {
        // 임계값 폴 서킷 브레이커 재개 지점 — 사용자가 앱을 다시 열었으니(네트워크가
        // 돌아왔을 가능성) 연속 실패 카운터를 풀어 배경 폴링을 재개시킨다(사용자 결정).
        consecutiveUsagePollFailures = 0
        loadUsageCacheIfNeeded()
        guard MobiusFeature.showUsageGauges else { return }
        guard usageTask == nil else { return }
        let now = Date()
        // Claude만 — Codex 게이지는 세션 로그에서 얻는다 (tick의 processCodexBatches).
        // needsReauth 계정도 계속 조회한다 — CLI에서 직접 `claude auth login`으로 복구하는
        // 경우, 조회가 200이면 그 복구를 감지해 needsReauth를 자동으로 푼다(아래 성공 경로).
        // 여전히 401이면 `!profile.needsReauth` 가드가 재알림을 막으므로 스팸은 없다.
        let stale = store.file.accounts.filter {
            $0.provider == .claude &&
            (usage[$0.id]?.fetchedAt ?? .distantPast) < now.addingTimeInterval(-usageStaleness)
        }
        guard !stale.isEmpty else { return }
        usageTask = Task { @MainActor in
            defer { usageTask = nil }
            var reauthChanged = false
            for profile in stale {
                let isActive = store.file.activeAccountID == profile.id
                // 활성 계정은 저장 스냅샷 대신 **라이브 토큰**으로 조회한다 — claude CLI가
                // 라이브 토큰을 갱신하므로 저장본이 낡으면 401 오탐(잘 쓰는데 "재로그인 필요")이
                // 난다. 비활성 계정은 라이브가 그 계정이 아니므로 저장 스냅샷을 쓴다.
                // ★ 라이브를 쓸 땐 **라이브 이메일이 이 프로필과 맞는지** 확인한다 —
                //   activeByProvider 마커가 외부 로그인보다 최대 15초 뒤처지므로, 확인 없이
                //   쓰면 X의 토큰으로 조회한 결과를 Y의 게이지에 쓰고 401이면 Y에 재로그인
                //   딱지까지 붙인다(이 PR이 없애는 오귀인과 같은 클래스). 불일치면 저장
                //   스냅샷으로 내려온다 — 그건 계정 id로 꺼내므로 오귀인이 불가능하다.
                guard let blob = usageQueryBlob(for: profile.id) else { continue }
                // 비활성 계정의 저장 access 토큰이 만료됐으면 게이지를 못 읽어 얼어붙는다
                // (429/401 → 조용히 continue). 폴백 refresh 기계로 미리 갱신한다 — 활성은
                // check의 첫 guard가 절대 건드리지 않고, 회전 토큰은 원자 저장되며,
                // refresh 토큰이 만료/폐기면 needsReauth로 마킹된다(계정당 access TTL≈1h라
                // 갱신 후엔 만료 조건이 풀려 재-refresh가 자연히 멈춘다 = 스톰 없음).
                var fetchBlob = blob
                if !isActive, !profile.needsReauth,
                   let exp = UsageFetcher.expiresAt(from: blob), exp <= now {
                    // 계정당 쿨다운: 최근 시도가 있으면 이번 라운드는 아예 건너뛴다(만료 토큰이라
                    // 어차피 게이지도 못 읽는다). transient 실패가 팝오버마다 회전 시도로 반복되지
                    // 않게 하는 것 — 첫 시도는 게이팅 안 됨(distantPast)이라 프리즈 해소는 유지.
                    guard now.timeIntervalSince(lastUsageRefreshAttemptAt[profile.id] ?? .distantPast)
                            >= Self.usageRefreshRetryCooldown else { continue }
                    lastUsageRefreshAttemptAt[profile.id] = now
                    switch await fallbackChecker.check(profile.id,
                                                       activeAccountID: store.file.activeAccountID,
                                                       now: now, allowNetwork: true) {
                    case .refreshedAlive:
                        lastUsageRefreshAttemptAt[profile.id] = nil   // 성공 — 쿨다운 해제
                        if let fresh = (try? store.secret(for: profile.id))?.keychainBlob {
                            fetchBlob = fresh
                        }
                    case .dead, .storeFailed:
                        // **네트워크로만 알 수 있는** 죽음(invalid_grant / 저장 실패) — 매 팝오버
                        // 함께 도는 validateFallbacksLocally는 로컬 검사(allowNetwork:false)라
                        // 못 잡는다. 여기서 알림을 전담한다(check가 이미 needsReauth 마킹).
                        reauthChanged = true
                        notify(title: l.accountsNotifyReauthTitle,
                               body: l.accountsNotifyReauthBody(profile.nickname))
                        continue
                    case .locallyDead, .noRefreshToken:
                        // **로컬로 판정 가능**한 죽음 — 매 팝오버 함께 도는 validateFallbacksLocally가
                        // 알림을 전담하므로(같은 계정에 알림 2개 방지) 여기선 알리지 않는다.
                        // check가 켠 needsReauth 반영(reload)만 하고 조용히 스킵.
                        reauthChanged = true
                        continue
                    case .transient, .notFallback, .noSecret:
                        continue   // 갱신 실패/불가 — 쿨다운 뒤 재시도
                    }
                }
                do {
                    guard let snap = try await UsageFetcher.fetch(keychainBlob: fetchBlob)
                    else { continue }
                    usage[profile.id] = snap
                    // 조회 성공 = 토큰 살아있음 → 잘못 남은 재로그인 마킹 자가 해제
                    if profile.needsReauth {
                        try? store.setNeedsReauth(profile.id, false)
                        reauthChanged = true
                    }
                    // 리셋 시각 보정: 로그 기반 감지는 시각이 없으면 24h로 때웠지만
                    // usage API는 진짜 리셋 시각을 안다. 이 계정이 limited로 마킹돼 있고
                    // 소진된 한도(≥100%)의 실제 리셋이 현재 기록과 다르면 그 값으로 교정.
                    if let cur = store.file.accounts.first(where: { $0.id == profile.id })?.rateLimit,
                       let real = verifiedResetCorrection(snap, modelScoped: cur.modelScoped,
                                                          now: Date()),
                       abs(cur.resetsAt.timeIntervalSince(real)) > 60 {
                        try? store.update(profile.id) {
                            $0.rateLimit = RateLimitInfo(resetsAt: real, recordedAt: cur.recordedAt,
                                                         modelScoped: cur.modelScoped)
                        }
                        reauthChanged = true // reload 유발용 (상태 변경 반영)
                    }
                } catch is UsageFetcherError {
                    // 401/403 = 이 계정의 토큰이 거부됨. 계정별 토큰으로 조회하므로 오귀인 불가.
                    // 단 자연 만료 토큰의 401은 **활성/비활성 모두** 오탐이라 마킹하지 않는다 —
                    // 활성도 잠자기 등으로 claude가 안 돌면 라이브 토큰이 만료된 채 남는다
                    // (이슈 #4: 오마킹 → 엔진이 멀쩡한 주계정을 밀어내던 연쇄의 수정).
                    // 판정 규칙은 UsageFetcher.shouldMarkReauthAfterAuthError 참조.
                    // ★ 판정 대상은 fetchBlob: refresh 성공 시 fetchBlob은 신선한(유효) 토큰이라
                    //   그래도 401이면 폐기로 마킹, refresh를 안 한 경로면 fetchBlob==blob.
                    let marked = UsageFetcher.shouldMarkReauthAfterAuthError(blob: fetchBlob,
                                                                            isActive: isActive)
                        && !profile.needsReauth
                    if marked {
                        try? store.setNeedsReauth(profile.id, true)
                        reauthChanged = true
                        notify(title: l.accountsNotifyReauthTitle,
                               body: l.accountsNotifyReauthBody(profile.nickname))
                    }
                    // 위 규칙이 못 잡는 죽음(활성 계정의 진짜 폐기)은 이제 무상태 배지
                    // (AuthSuspicion.cheapConditionsHold/confirmed — recomputeBadgeCheap/Live)가
                    // 세션 활동 × 토큰 만료 상관으로 감지한다. 여기서 401을 누적하지 않는다.
                } catch { continue }   // 네트워크 오류 — 토큰 문제가 아니므로 누적하지 않는다
            }
            if reauthChanged {
                MobiusNotification.postAccountsChanged()
                reload()
            }
            saveUsageCache()
        }
    }

    /// codex 전환 직전, 진행 중인 비활성 게이지 refresh를 정지·완료대기시킨다 — 전환↔회전 HTTP
    /// 창(케이스2: 왕복 중 전환)을 닫는다. cancel()은 루프의 다음 계정 진입을 막아, 대기를 현재 처리
    /// 중인 계정의 진행 중 HTTP(refresh 후 probe까지 최대 2회 순차) 완료까지로 바운드한다.
    private func quiesceCodexUsageTask() async {
        codexUsageTask?.cancel()
        await codexUsageTask?.value
    }

    /// 팝오버가 열릴 때 호출 — **비활성 codex** 계정의 게이지를 네트워크로 조회한다(Claude의
    /// refreshUsageIfStale와 대칭). 활성 codex 계정은 세션 로그 in-band 경로(tick의
    /// processCodexBatches)가 그대로 담당하므로 제외한다 — processCodexBatches는 손대지 않는다.
    ///
    /// ★ **게이지 전용**: usage 캐시(usage[id])만 채운다. setNeedsReauth·엔진·rateLimit 기록을
    /// 절대 호출하지 않고(CodexUsageProber의 안전 계약), 자격증명은 저장 스냅샷 바이트를 읽기
    /// 전용으로만 쓴다(쓰기/refresh/codex 실행 없음). 401은 만료된 비활성 토큰이라 무해하게
    /// 게이지를 stale로 둔다. wham/usage는 codex가 이미 폴링하는 상태 엔드포인트라 추가 쿼터
    /// 부담이 없어(B1), showUsageGauges와 함께 기본 활성이다(별도 토글 없음 — Claude와 대칭).
    /// 신선도/쿨다운 기준은 usage[id].fetchedAt(영속됨) — 재시작 후에도 엔드포인트를 난타하지 않는다.
    func refreshCodexUsageIfStale() {
        loadUsageCacheIfNeeded()
        guard MobiusFeature.showUsageGauges else { return }
        guard codexUsageTask == nil else { return }
        let now = Date()
        let codexActiveID = store.file.activeByProvider[.codex]
        // 비활성 codex 계정 중 게이지 캐시가 만료된 것만. 활성은 로그 경로가 담당하므로 제외.
        let stale = store.file.accounts.filter {
            $0.provider == .codex && $0.id != codexActiveID &&
            (usage[$0.id]?.fetchedAt ?? .distantPast) < now.addingTimeInterval(-usageStaleness)
        }
        guard !stale.isEmpty else { return }
        codexUsageTask = Task { @MainActor in
            defer { codexUsageTask = nil }
            var updated = false
            for profile in stale {
                if Task.isCancelled { break }
                // 죽은 토큰 계정은 긴 백오프 동안 refresh/probe를 아예 건너뛴다(어차피 401 → 무의미).
                if let deadUntil = codexRefreshDeadUntil[profile.id], now < deadUntil { continue }
                // 저장된 auth.json 스냅샷 바이트를 읽는다. refresh 성공 시 아래에서 회전본으로 교체.
                guard let authJSON = try? store.secretData(for: profile.id) else { continue }
                var probeBytes = authJSON

                // 저장 access 토큰이 이미 만료됐으면 게이지를 못 읽어 얼어붙는다(GET엔 회전이 없어
                // 만료 토큰으로 조회하면 401만 받는다) → refresh로 미리 되살린다. **활성 계정은 절대
                // refresh하지 않는다**(락 밖 fresh-read로 활성/전환중 계정을 재확인).
                let liveActiveID = store.file.activeByProvider[.codex]
                if profile.id != liveActiveID, profile.id != pendingSwitchID,
                   let exp = CodexAuthBlob.accessTokenExpiry(fromAuthJSON: authJSON), exp <= now {
                    // 계정당 쿨다운: 최근 시도가 있으면 이번 라운드는 건너뛴다(만료 토큰이라 게이지도
                    // 어차피 못 읽는다). 첫 시도는 게이팅 안 됨(distantPast)이라 프리즈 해소는 유지.
                    guard now.timeIntervalSince(lastCodexRefreshAttemptAt[profile.id] ?? .distantPast)
                            >= Self.usageRefreshRetryCooldown else { continue }
                    lastCodexRefreshAttemptAt[profile.id] = now
                    let refreshOutcome = await Task { await codexRefresher.refresh(authJSON: authJSON) }.value
                    switch refreshOutcome {
                    case .refreshed(let rotated):
                        // ★ 원자 capture: credential lock 안에서 (1) 활성 재확인(TOCTOU — 그 사이
                        //   자동/수동 전환으로 활성이 됐으면 라이브 ~/.codex가 authoritative이므로
                        //   회전본을 버린다), (2) 신원/형태 검증(실패 기록 1/13 클래스: 손상·타 계정
                        //   바이트가 스냅샷을 덮어쓰지 않게), (3) 원자 저장. 하나라도 어긋나면 기존
                        //   스냅샷을 보존한다(덮어쓰지 않음).
                        let stored: Data? = store.withCredentialLock(profile.id) { () -> Data? in
                            guard profile.id != store.file.activeByProvider[.codex] else { return nil }
                            // 락 안에서 스냅샷을 다시 읽는다 — HTTP 왕복 중 adopt/재로그인이 끼면
                            // 신규 로그인 스냅샷을 구 세션 회전본으로 덮는 edge를 차단(회전본 폐기).
                            guard let current = try? store.secretData(for: profile.id),
                                  current == authJSON else { return nil }
                            guard codexIO.recognizesSecret(rotated),
                                  CodexConfigIO.email(fromAuthJSON: rotated) == profile.emailAddress,
                                  CodexTokenRefresher.refreshToken(fromAuthJSON: rotated)?.isEmpty == false
                            else { return nil }
                            do { try store.setSecretData(rotated, for: profile.id) } catch { return nil }
                            return rotated
                        }
                        guard let stored else { continue }   // 활성이 됨 / 검증 실패 — 이번 라운드 스킵
                        probeBytes = stored
                        lastCodexRefreshAttemptAt[profile.id] = nil   // 성공 — 쿨다운 해제
                        codexRefreshDeadUntil[profile.id] = nil
                    case .invalidated:
                        // 죽은 refresh 토큰(세션 종료) — 게이지 전용 방화벽: 엔진/persisted reauth를
                        // 절대 건드리지 않고, 긴 백오프(codexRefreshDeadUntil)만 남기고 stale로 둔다.
                        codexRefreshDeadUntil[profile.id] = now.addingTimeInterval(Self.codexDeadRefreshCooldown)
                        continue
                    case .transient:
                        // refresh POST는 위 Task {} 쉴드로 취소 비전파라 여기는 순수 네트워크/5xx다
                        // (우리 자신의 취소로 인한 transient는 이 분기에 도달할 수 없다).
                        continue   // 쿨다운 뒤 재시도(게이지는 마지막 값 유지)
                    }
                }

                // B1 게이지 조회 — (가능하면 갱신된) 바이트로. 읽기 전용, 아무것도 마킹하지 않는다.
                switch await codexProber.probe(authJSON: probeBytes, now: now) {
                case .usage(let snap):
                    usage[profile.id] = snap
                    updated = true
                case .stale, .transient:
                    continue   // 게이지를 마지막 스냅샷에 둔다 — 아무것도 마킹하지 않는다.
                }
            }
            if updated { saveUsageCache() }
        }
    }

    /// 팝오버 열 때 폴백 계정을 **네트워크 0 로컬 검사**만 한다 — 빈/시간만료 refresh 토큰을
    /// 즉시 needsReauth로 플래그(fore.st 같은 손상 스냅샷 대응). 실제 네트워크 refresh는 하지
    /// 않는다(계정 리스크 최소화 — 매 팝오버마다 서버 호출 안 함). 진짜 refresh 검증은
    /// 자동 폴백 전환 직전에만 한다(preflightFallback).
    func validateFallbacksLocally() {
        guard fallbackLocalTask == nil else { return }
        let active = store.file.activeAccountID
        let now = Date()
        // Claude 전용: 이 checker는 Claude refresh 토큰 형태만 판정한다. Codex 계정이 새면
        // (a) 활성 제외 가드가 Claude activeAccountID 기준이라 활성 Codex가 우회될 수 있고
        // (b) 팝오버마다 Codex 계정 수만큼 불필요한 secret 디코드 시도가 돈다.
        let targets = store.file.accounts.filter { $0.provider == .claude && $0.id != active && !$0.needsReauth }
        guard !targets.isEmpty else { return }
        fallbackLocalTask = Task { @MainActor in
            defer { fallbackLocalTask = nil }
            var changed = false
            for p in targets {
                let r = await fallbackChecker.check(p.id, activeAccountID: active, now: now, allowNetwork: false)
                if r == .noRefreshToken || r == .locallyDead {
                    changed = true   // targets는 !needsReauth만 → 새 전이 → 1회 알림
                    notify(title: l.accountsNotifyReauthTitle,
                           body: l.accountsNotifySignInExpiredBody(p.nickname))
                }
            }
            if changed { MobiusNotification.postAccountsChanged(); reload() }
        }
    }

    /// 자동 폴백이 이 계정으로 넘어가기 **직전** 실제 refresh로 검증한다. 죽었으면(마킹됨)
    /// false를 반환해 전환을 취소 — 다음 틱에 엔진(onTick)이 needsReauth를 제외하고 다음 폴백을
    /// 고른다. 살아있거나(refresh 성공) 판단 불가(네트워크 오류)면 true(전환 진행).
    private func preflightFallback(_ id: UUID, now: Date) async -> Bool {
        let r = await fallbackChecker.check(id, activeAccountID: store.file.activeAccountID,
                                            now: now, allowNetwork: true)
        switch r {
        case .dead, .locallyDead, .noRefreshToken, .storeFailed:
            let name = store.file.accounts.first { $0.id == id }?.nickname ?? "?"
            notify(title: l.accountsNotifyReauthTitle,
                   body: l.accountsNotifySwitchSkippedBody(name))
            return false
        default:
            return true   // refreshedAlive / transient / notFallback → 전환 진행
        }
    }

    /// 만료 임박한 폴백의 refresh 토큰을 미리 갱신한다 — refresh가 새 refresh 토큰(연장된
    /// 만료)을 주므로, 안 쓰던 폴백이 몇 주 뒤 조용히 죽는 것을 막는다. 폴백만(활성 제외),
    /// **만료 3일 이내**일 때만, 계정당 **6시간 이상 간격**으로만 호출(→ 블락 위험 미미).
    /// 성공하면 만료일이 멀어져 다음 스윕엔 대상에서 빠진다. 이미 만료/토큰없음이면
    /// checker가 네트워크 0으로 needsReauth 마킹.
    private func proactiveRefreshExpiringFallbacks(now: Date) async {
        let active = store.file.activeAccountID
        var changed = false
        // Claude 폴백만 — OAuth refresh는 Claude 자격증명 형식 전용이다. Codex 계정에
        // 이 검사를 돌리면 refresh 토큰을 못 읽어 잘못 needsReauth로 마킹된다.
        for p in store.file.accounts where p.provider == .claude && p.id != active && !p.needsReauth {
            guard let snap = try? store.secret(for: p.id),
                  let exp = CredentialBlob.refreshTokenExpiresAt(from: snap.keychainBlob),
                  exp.timeIntervalSince(now) < Self.proactiveRefreshRenewWindow,
                  (lastProactiveRefreshAt[p.id] ?? .distantPast)
                      < now.addingTimeInterval(-Self.proactiveRefreshPerAccountGate)
            else { continue }
            lastProactiveRefreshAt[p.id] = now
            let r = await fallbackChecker.check(p.id, activeAccountID: active, now: now, allowNetwork: true)
            switch r {
            case .refreshedAlive:
                changed = true
            case .dead, .locallyDead, .noRefreshToken, .storeFailed:
                changed = true
                notify(title: l.accountsNotifyReauthTitle,
                       body: l.accountsNotifySignInExpiredBody(p.nickname))
            default:
                break
            }
        }
        if changed { MobiusNotification.postAccountsChanged(); reload() }
    }

    /// 저장된 기록을 교정할 실제 리셋 시각. 없으면 nil(교정 안 함).
    ///
    /// ★ **기록을 쓰는 쪽과 정확히 같은 규칙을 쓴다**(`exhaustionHit`/`scopedExhaustionHit`):
    ///   기록의 종류와 같은 창만 보고, 아직 안 지난 리셋 중 **가장 늦은 것**. 예전엔 이 함수만
    ///   따로 `min()`을 썼는데, 쓰는 쪽이 `max()`라 5시간·주간이 함께 소진되면 **저장(+5일) →
    ///   교정(+2시간) → 2시간 뒤 해제 → 아직 주간 소진인 계정으로 복귀 → 다시 hit** 의 무한
    ///   왕복이 된다. 두 규칙을 나란히 두지 말고 한 곳에서만 정의한다.
    private func verifiedResetCorrection(_ s: UsageSnapshot, modelScoped: Bool,
                                         now: Date) -> Date? {
        (modelScoped ? s.scopedExhaustionHit(now: now) : s.exhaustionHit(now: now))?.resetsAt
    }

    func reload() {
        // AccountStore는 자기 인스턴스 상태를 유지하므로 디스크에서 재로드
        if let fresh = try? AccountStore(env: env, keychain: SystemKeychain()) {
            try? store.replaceFile(with: fresh.file)
        }
        file = store.file
        // 플래그(hasDesktopSnapshot)를 진실의 원천으로 삼아 스냅샷 디렉토리를 정리 —
        // 실패한 캡처의 잔재 dir이 유효 스냅샷으로 오인돼 잘못 복원되는 것을 막는다.
        let flagged = Set(store.file.accounts.filter { $0.hasDesktopSnapshot }.map { $0.id })
        desktopSwitcher.pruneSnapshotsExcept(flagged)
    }

    var menuStatus: MenuStatus {
        let now = Date()
        let pools = Provider.allCases.filter { !file.accounts(of: $0).isEmpty }
        guard pools.contains(where: { file.active(of: $0) != nil }) else { return .unknown }
        func poolExhausted(_ provider: Provider) -> Bool {
            file.accounts(of: provider).allSatisfy { $0.isLimited(now: now) || $0.needsReauth }
        }
        // 빨강 = 모든 풀이 막혀 어디서도 작업 불가.
        if pools.allSatisfy(poolExhausted) { return .allExhausted }
        // 주계정에 머무는 중인 풀은 알람색 아님 — 사용자가 직접 주계정을 선택했을 때
        // (Fable 등 일부 한도만 소진돼도) 알람색으로 보이지 않게(upstream 293a911 반영).
        // 어떤 풀이든 fallback에 활성이면 주황. (진짜 소진이면 자가복구가 fallback으로 옮긴다.)
        if pools.contains(where: { provider in
            guard let active = file.active(of: provider) else { return false }
            return active.id != file.primary(of: provider)?.id
        }) { return .fallbackActive }
        return .primaryActive
    }

    // MARK: 주기 처리

    /// 틱 재진입 가드 — @MainActor 전용 필드라 별도 동기화가 필요 없다(설정~첫 await 사이에
    /// 다른 틱이 끼어들 수 없다).
    private var tickInFlight = false

    func tick() async {
        // ★ 앞 틱이 끝나기 전에는 새 틱을 돌리지 않는다 (이슈 #15).
        // 3초 타이머(:289)는 이전 틱의 완료를 확인하지 않고 매번 새 Task를 만들고, tick()에는
        // await 지점이 여럿이라 틱들이 서로 끼어들며 **무한정 쌓인다**. 쌓인 틱은 각자 세션 로그
        // 스캔을 하나씩 더 띄우고, 그 스캔들은 워처의 스캔 락에 직렬화되므로 대기열이 영영 줄지
        // 않는다 — 스캔이 틱 간격을 한 번 넘기는 순간 스스로 못 빠져나오는 되먹임이 된다
        // (실측 제보: 2일 11시간 동안 CPU 336분을 태우며 UI 정지).
        // 워처 락 분리(SessionLogWatcher)만으로 메인 스레드 정지는 막히지만, 이 가드가 없으면
        // 스캔이 겹쳐 CPU를 계속 태운다. 두 수정은 각각 다른 증상을 막으므로 함께 둔다.
        // 건너뛴 틱은 유실이 아니다 — 내부 작업은 전부 "마지막 실행 시각" 기준 게이트라
        // 다음 틱에서 이어서 처리된다.
        guard !tickInFlight else { return }
        // ★ `stop()` 이 취소한 틱은 여기서 스스로 물러난다. 취소는 **실행을 막지 못한다** —
        // 이미 큐에 오른 태스크는 취소돼도 몸체를 그대로 돌기 시작하므로, 직접 확인해야
        // "껐는데 마지막 틱이 계정을 바꿨다"가 안 생긴다. 틱 도중의 취소는 `apply` 가 막는다.
        guard !Task.isCancelled else { return }
        tickInFlight = true
        defer { tickInFlight = false }
        // 오래된 푸터 에러 자동 소거 (TTL 5분)
        if let at = lastErrorAt, Date().timeIntervalSince(at) >= Self.lastErrorTTL {
            lastError = nil
        }
        let now = Date()
        // 임계값 기능이 유효하지 않으면(토글 off 또는 부모 '자동 전환' off) 남아있는 advisory를
        // 매 틱 정리한다 — **가드 위**에서 도는 값싼 로컬 정리라 라이브 자격증명을 안 건드린다
        // (로그인 플로우 감지와 경합 없음). 잔재 없음을 보장해, 꺼져 있는데 옛 advisory가
        // primary 복귀를 막거나 pill이 얼어붙는 일이 없게.
        if !advisoryEffectivelyEnabled { clearAdvisoriesIfFeatureOff() }
        // 로그인 창이 열려 있는 동안은 reconcile/자동 전환이 LoginFlow의
        // 자격증명 변경 감지와 경합하지 않도록 전체를 건너뛴다.
        // Desktop 가이드 캡처 중에도 동일 — 자동 전환이 Desktop을 재실행하면
        // 사용자가 로그인 중인 창을 죽이고 감시 신호를 오염시킨다.
        guard loginFlow == nil, desktopCapture == nil else { return }
        // 배지 값싼 절반 — 가드 바로 아래(IO 0). 라이브 재검증은 5분 블록에서만.
        recomputeBadgeCheap(now: now)
        // reconcile/adopt는 15초마다만 — 3초 틱에 매번 돌리면 Keychain 접근이 잦아진다.
        // reconcile은 항상 라이브(실제 자격증명)를 진실로 삼아 active를 맞춘다 — active 마커가
        // 라이브와 어긋나면 UI가 /status와 달라지는 더 나쁜 버그가 된다(유예는 넣지 않는다).
        if now.timeIntervalSince(lastReconcileAt) >= Self.reconcileInterval {
            lastReconcileAt = now
            let activeBefore = store.file.activeByProvider
            _ = try? await switcher.adoptLiveAccountIfUnregistered()
            try? await switcher.reconcile()
            // 외부 요인(재로그인, 또는 구 세션의 토큰 리프레시가 자격증명 파일을 되돌리는
            // 클로버 — Codex 실측)으로 활성이 바뀌면 조용히 넘어가지 않고 알린다.
            for provider in Provider.allCases {
                let after = store.file.activeByProvider[provider]
                guard activeBefore[provider] != after, activeBefore[provider] != nil,
                      let name = store.file.accounts.first(where: { $0.id == after })?.nickname
                else { continue }
                notify(title: l.accountsNotifyExternalChangeTitle(provider.displayName),
                       body: l.accountsNotifyExternalChangeBody(name))
            }
        }
        // 활성 계정 스냅샷을 5분마다 라이브(갱신된 토큰)와 동기화 — 오래 쓰다 크래시해도
        // 스냅샷이 낡지 않게. reconcile은 활성 불변 시 되저장을 건너뛰므로 이 보강이 그 틈을 메운다.
        // 이 fresh 스냅샷을 배지 라이브 절반과 임계값 폴이 공유한다(5분 창당 라이브 자격증명
        // subprocess 1회로 묶는 통합 — 실패 기록 3 계열의 승인창 비용 절감).
        if now.timeIntervalSince(lastActiveSnapshotSyncAt) >= Self.activeSnapshotSyncInterval {
            lastActiveSnapshotSyncAt = now   // await 전에 설정 — 이 창 안 재진입 방지
            if await switcher.refreshActiveSnapshotIfStable() {
                consecutiveSyncFailures = 0     // 진짜 fresh write — 실패 카운터 리셋
                invalidateExpiryCache()         // 스냅샷 갱신 → 만료 캐시 재계산 유도
                recomputeBadgeLive(now: now)    // fresh 스냅샷으로 confirmed 최종 판정
                // 서킷 브레이커: 사용량 조회가 3연속 실패하면 배경 폴링을 멈춘다(네트워크
                // 이상 방어 — 이상 중엔 미리 전환 자체가 무의미). 재개는 팝오버 열기/재시작.
                // ★ 게이트가 advisory 토글이 **아닌** 이유(2026-09-16 결함): 소진 기록을 만드는
                //   경로가 세션 로그 429 하나뿐이라, 5시간 창이 100%가 돼도 CLI가 그 뒤로 요청을
                //   안 보내면(막힌 사용자는 당연히 멈춘다) 기록이 없어 `onTick`이 자동 전환을
                //   못 한다 — usage API 는 이미 100%를 보고 있는데도. 그래서 이 폴은 advisory
                //   토글과 무관하게 돈다. 대신 **전환할 이유가 있을 때만** 돈다(아래 헬퍼).
                if Self.usagePollIsWorthwhile(
                        autoSwitchEnabled: store.file.isAutoSwitchEnabled(.claude),
                        claudeAccountCount: store.file.accounts(of: .claude).count),
                   !UsagePollBreaker.isTripped(consecutiveFailures: consecutiveUsagePollFailures) {
                    await pollActiveUsage(now: now)
                }
            } else {
                // false = 이른 가드 실패(라이브 이메일이 등록 활성과 불일치) 또는 저장 실패.
                // ★ 활성 Claude 프로필이 실제로 있을 때만 실패로 센다 — Codex-only 풀이나
                //   Claude adopt 대기 상태는 첫 가드가 상시/일시적으로 false라, 이 게이트가
                //   없으면 멀쩡한 사용자에게 매 세션 유령 배너가 뜬다(finding LOW-breadcrumb-scope).
                if store.file.active(of: .claude) != nil {
                    consecutiveSyncFailures += 1
                    if consecutiveSyncFailures >= 3 {
                        lastError = l.accountsErrorSyncStalled
                    }
                }
            }
        }
        // 만료 임박 폴백 자동 refresh (저빈도 스윕) — 안 쓰던 폴백이 조용히 죽는 것 방지.
        if now.timeIntervalSince(lastProactiveRefreshSweepAt) >= Self.proactiveRefreshSweepInterval {
            lastProactiveRefreshSweepAt = now
            await proactiveRefreshExpiringFallbacks(now: now)
        }

        // 로그 스캔은 메인 액터 밖에서 — Codex 세션 루트는 파일이 수만 개라
        // 열거+stat(실측 ~0.1s)가 UI를 막지 않게 한다.
        // ★ [정정, 이슈 #15] 예전 주석은 "워처는 자체 락으로 안전"이라고 적혀 있었는데 정확히
        // 반대였다. 워처가 **자체 락을 갖고 있기 때문에** 메인 액터에서 그 접근자
        // (lastActivity/trackedFiles)를 만지면 진행 중인 스캔이 끝날 때까지 메인 스레드가
        // 동기 블록된다 — 백그라운드로 옮겼다는 사실이 안전을 뜻하지 않는다. 공유된 락이
        // 두 경로를 도로 붙인다. 지금은 그 두 접근자가 스캔 락과 분리된 경량 락을 쓰므로
        // 안전하지만, **워처에 새 접근자를 추가할 때 스캔 락을 잡게 하지 말 것.**
        // ★ 세션이 안 도는 동안은 저빈도로 — 근거·대가는 `sessionLogScanIsDue` 주석.
        //   단 **활성 계정이 바뀐 틱에서는 유휴여도 반드시 스캔한다.** `CodexStatusRouter` 는
        //   활성이 바뀐 순간의 `trackedFiles`(= 직전 스캔 완료 시점 스냅샷)로 전환 전 세션
        //   파일을 격리하는데, 그 스냅샷이 낡으면 전환 직전에 시작된 세션이 격리되지 않아
        //   옛 계정의 사용량이 새 계정에 박힌다(연쇄 전환). 이 한 줄이 그 창을 스캔 주기가
        //   아니라 **틱 주기**로 되돌려, 주기를 늘리면서도 정확성은 손대지 않게 한다.
        let activeByProvider = store.file.activeByProvider
        let activeChanged = activeByProvider != lastTickActiveByProvider
        lastTickActiveByProvider = activeByProvider
        let claudeHits: [RateLimitHit]
        let codexBatches: [SessionLogWatcher<MobiusCore.CodexRateLimitStatus>.Batch]
        if Self.sessionLogScanIsDue(
            now: now,
            lastActivity: [watcher.lastActivity, codexWatcher.lastActivity].compactMap { $0 }.max(),
            lastScanAt: lastSessionLogScanAt,
            activeWindow: min(watcher.recentWindow, codexWatcher.recentWindow),
            idleInterval: Self.idleSessionLogScanInterval,
            activeChanged: activeChanged)
        {
            lastSessionLogScanAt = now
            sessionLogScanCountForTesting += 1
            let claudeWatcher = watcher, codexWatcher = self.codexWatcher
            (claudeHits, codexBatches) = await Task.detached(priority: .utility) {
                (claudeWatcher.scan(now: now), codexWatcher.scanBatches(now: now))
            }.value
        } else {
            (claudeHits, codexBatches) = ([], [])
        }

        // Claude: 세션 로그의 rate-limit 에러 이벤트.
        // 주의(upstream 293a911): 인증 만료(authentication_failed) 로그는 "어느 계정" 것인지
        // 적혀 있지 않아 활성 계정에 오귀인된다 → needsReauth는 로그가 아니라 usage API 401
        // (계정별 토큰으로 조회 → 오귀인 불가)로만 판정한다(refreshUsageIfStale 참조).
        // ★ [이슈 #19] **rate-limit 라인도 똑같이 익명이다.** 같은 원칙을 여기에도 적용한다 —
        //   로그 hit은 **트리거**일 뿐이고 판정은 usage API가 한다(HitAttribution 참조).
        //   전환 시점에 진행 중이던 턴이 옛 계정의 에러를 전환 **뒤에** 남기므로, 스캔 시점
        //   활성 계정에 그대로 기록하면 멀쩡한 폴백이 소진으로 박혀 자동 전환이 통째로 죽는다.
        //   그래서 hit 자체의 내용(리셋 시각·modelScoped)은 쓰지 않고 **버린다** — 검증된
        //   스냅샷에서 나온 값만 기록한다. 로그 hit의 종류·개수는 "지금 확인해 볼 이유"로만 쓴다.
        let claudeActiveID = store.file.activeByProvider[.claude]
        // 활성 변경 감지(경로 무관 — 앱 전환·CLI·외부 로그인 전부 여기서 잡힌다).
        // 첫 관찰은 "변경"이 아니다 — 앱 시작 직후 5분 동안 모델 한도 증거를 못 믿게 되면
        // 그건 그냥 손해다.
        if !sawClaudeActiveOnce {
            sawClaudeActiveOnce = true
            lastKnownClaudeActive = claudeActiveID
        } else if lastKnownClaudeActive != claudeActiveID {
            lastKnownClaudeActive = claudeActiveID
            claudeActiveChangedAt = now
        }
        var sawMonthlySpend = false
        // ★ 트리거의 신선도 기준은 **스캔이 끝난 지금**이지 틱 시작 시각(now)이 아니다
        //   (셀프리뷰 지적). 틱은 여기까지 오는 동안 reconcile·5분 스냅샷 동기화·임계값 폴을
        //   거치는데, 그중 임계값 폴은 usage 캐시를 갱신한다 — 그 스냅샷은 아직 **소진 전**
        //   (예: 96%)일 수 있고, 그런데도 `fetchedAt > now`라 "트리거보다 나중"으로 통과해
        //   방금 도착한 진짜 소진을 "여유"로 판정하고 트리거까지 태워 없앤다. 이 PR이 세운
        //   "나이가 아니라 순서" 규칙이 정확히 여기서 깨진다. 한 배치의 hit들은 같은 값을
        //   공유하므로 배치 내 캐시 재사용(네트워크 0)은 그대로다.
        let scannedAt = Date()
        for hit in claudeHits {
            // 월간 지출 한도(P3)는 창 소진이 아니다 — 기록하면 24h 폴백 오탐이 된다
            // (2026-07-13 실측: 플랜 창 여유 상태에서도 뜨고 세션은 정상 동작).
            // 단 창 소진과 겹치면 이 메시지가 우선 표시돼 창 소진을 가리므로 usage로 교차 확인.
            guard hit.kind == .window else { sawMonthlySpend = true; continue }
            await verifyAndRecordWindowHit(accountID: claudeActiveID, now: scannedAt, logHit: hit)
        }
        // 판정을 못 끝낸 트리거 재시도 — 로그 hit은 한 번만 배달되므로(오프셋 전진), 조회가
        // 실패한 트리거를 여기서 다시 보지 않으면 사용자가 타이핑을 멈춘 순간 그 소진은
        // 영영 기록되지 않는다. 재시도 주기는 HitAttribution.cooldown이 잡는다(매 틱 아님).
        for accountID in Array(pendingHitVerify.keys) {   // 루프 중 딕셔너리를 지우므로 복사
            await verifyAndRecordWindowHit(accountID: accountID, now: scannedAt, isRetry: true)
        }
        // 월 지출(P3, extra-usage) 한도 이벤트도 **같은 경로로 교차 확인**한다.
        // 이 메시지는 표시 우선순위(override)라 "무엇이 막혔는지"의 신뢰 신호가 아니어서
        // 원래도 usage로 창을 교차확인했는데, 그 전용 코드는 이 PR이 창 hit 경로에 넣은
        // 보호(순서 기반 캐시·보류 재시도·라이브 신원 확인)를 하나도 못 받고 있었다 —
        // 캐시가 나이 기준(4분)이라 소진 직전 스냅샷으로 "여유"라 오판할 수 있고, 조회가
        // 실패하면 재시도 장치가 없어 그 hit이 통째로 사라졌다(셀프리뷰 지적).
        // 판정 로직이 동일하므로 전용 경로를 지우고 합쳤다.
        if sawMonthlySpend {
            await verifyAndRecordWindowHit(accountID: claudeActiveID, now: scannedAt)
        }

        // Codex: 매 턴 실리는 rate_limits 상태 — 라우터가 전환 전 세션 파일을 걸러낸 뒤
        // 게이지 갱신 + 소진 판정 (네트워크 0)
        await processCodexBatches(codexBatches, now: now)

        for provider in Provider.allCases {
            await apply(engines[provider]!.onTick(file: store.file, now: now),
                        provider: provider, now: now)
        }
        file = store.file
    }

    private func recordHit(_ hit: RateLimitHit, on accountID: UUID?, now: Date) {
        guard let accountID else { return }
        try? store.update(accountID) {
            $0.rateLimit = RateLimitInfo(resetsAt: hit.effectiveResetsAt(now: now),
                                         recordedAt: now, modelScoped: hit.modelScoped)
        }
    }

    /// usage 조회에 쓸 자격증명 blob. **활성 계정은 라이브 토큰**을 쓴다 — 저장 스냅샷은 앱
    /// 시작 직후 만료 토큰일 수 있다(claude CLI가 라이브를 갱신한다).
    ///
    /// ★ 라이브를 쓸 땐 **라이브 이메일이 그 프로필과 일치하는지 확인한다**(셀프리뷰 지적).
    ///   `activeByProvider` 마커는 reconcile이 15초마다 맞추고 로그인 창이 열려 있으면 아예
    ///   건너뛰므로, 밖에서 계정이 바뀐 직후엔 **X의 토큰으로 조회한 결과를 Y에 기록**할 수
    ///   있다 — 이 PR이 없애려는 오귀인과 정확히 같은 클래스다. 이메일 확인은 `~/.claude.json`
    ///   한 번 읽기라 Keychain 승인창과 무관하다(실패 기록 3).
    ///   불일치면 **라이브를 쓰지 않고 저장 스냅샷으로 내려온다**(아래 참조) — 저장 secret은
    ///   계정 id로 꺼내므로 그 자체가 오귀인 안전한 경로다.
    private func usageQueryBlob(for accountID: UUID) -> Data? {
        // ★ 순서 주의(실패 기록 3b): **값싼 이메일 확인을 먼저.** readLiveSnapshot은
        //   security CLI 서브프로세스라, 불일치로 버릴 결과를 먼저 읽으면 그 비용만 버린다.
        if store.file.activeAccountID == accountID,
           let profileEmail = store.file.accounts.first(where: { $0.id == accountID })?.emailAddress,
           let liveEmail = try? io.liveEmail(), liveEmail == profileEmail,
           let live = try? io.readLiveSnapshot() {
            return live.keychainBlob
        }
        // 라이브를 못 쓰는 경우(신원 불일치·Keychain 읽기 실패)엔 **저장 스냅샷으로 내려온다.**
        // 저장 secret은 계정 id로 꺼내므로 오귀인 위험이 없다 — 낡아서 조회가 실패할 수는
        // 있고, 그건 보류 트리거가 다시 시도한다. 여기서 nil로 끝내면 P3(월 지출) 교차확인은
        // 재시도 장치가 없어 그 hit이 통째로 사라진다(셀프리뷰 지적).
        return (try? store.secret(for: accountID))?.keychainBlob
    }

    /// 계정별 마지막 **네트워크** 검증 시도 시각 — 실패 시 백오프용(HitAttribution.cooldown).
    private var lastHitVerifyAttempt: [UUID: Date] = [:]

    /// 판정이 안 끝난 트리거 하나.
    /// 두 시각을 **따로** 들고 있다: 언제까지 재시도할지(TTL)와, 어떤 스냅샷을 믿을지(신선도).
    /// 하나로 합치면 둘 중 하나가 반드시 틀린다 — 신선도 기준을 갱신하면 TTL이 영영 안 오고,
    /// TTL 기준을 그대로 쓰면 이미 "모르겠다"고 판정한 스냅샷으로 계속 같은 답을 낸다.
    private struct PendingTrigger {
        /// TTL 기준 — 이 트리거를 처음 본 시각.
        let firstSeenAt: Date
        /// 이 시각 **이후에 뜬** 스냅샷만 판정에 쓴다.
        var needsFresherThan: Date
        /// 이 트리거를 만든 로그 hit(창 소진일 때만). 검증이 **끝내 불가능**할 때의
        /// 최후 폴백에 쓴다 — 아래 giveUp 처리 참조. P3처럼 창 신호가 아닌 경우 nil.
        let logHit: RateLimitHit?
        /// 마지막 판정이 **모델 전용 한도** 때문에 보류됐는가(계정 창은 여유였다).
        ///
        /// ★ 로그 라인에는 **모델 이름이 없어서** `logHit.modelScoped`는 항상 false다
        ///   (`RateLimitParser`가 true를 세우는 곳은 P3 경로뿐이고 그건 여기 안 온다).
        ///   그래서 이 값 없이 최후 폴백을 쓰면 "그 모델만 막힘"이어야 할 상황이
        ///   **계정 전체 소진**으로 기록된다 — 메뉴바가 빨개지고, CLI 라벨이 틀리고,
        ///   무엇보다 `autoSwitchMayLeave`가 `isLimited`에서 **핀을 보기 전에 단락**해
        ///   사용자가 고정해 둔 계정에서 15분 뒤 강제로 밀려난다(셀프리뷰 H1).
        var lastInconclusiveWasModelScoped = false
    }

    /// **판정이 안 끝난 트리거**(계정 → 트리거).
    /// ★ 로그 hit은 워처 오프셋이 전진해 **한 번만 배달된다.** 조회가 실패했다고 그 자리에서
    ///   버리면, 사용자가 한도 에러를 보고 타이핑을 멈춘 순간 새 에러가 안 나와 **진짜 소진이
    ///   영영 기록되지 않는다**(자동 전환이 통째로 사라짐 — 셀프리뷰 지적). 그래서 트리거를
    ///   여기 남겨 다음 틱에 다시 판정한다(쿨다운이 재시도 주기를 잡는다).
    private var pendingHitVerify: [UUID: PendingTrigger] = [:]
    /// 보류 트리거의 수명 — 이 시간이 지나도록 판정을 못 했으면 버린다(오프라인이 길어질 때
    /// 옛 트리거로 뒤늦게 엉뚱한 기록을 남기지 않도록).
    /// ★ `HitAttribution.modelLimitedSteadyRecheck`(15분)와 **같은 값을 쓰지 않는다**(셀프리뷰 M1).
    ///   모델 한도 기록이 있는 계정에서 보류가 걸리면 재시도는 그 간격만큼 조회를 미루는데,
    ///   두 값이 같으면 "다시 조회할 때"와 "포기할 때"가 같은 틱에 겹치고 TTL 검사가 먼저라
    ///   **한 번도 새로 조회해 보지 못한 채** 최후 폴백으로 넘어갈 수 있다. 20분으로 벌려
    ///   재시도가 반드시 한 번은 실제 조회를 하도록 보장한다.
    private static let pendingHitVerifyTTL: TimeInterval = 20 * 60
    /// 수명이 다해 포기한 뒤 그 계정의 검증을 다시 시작하기까지의 간격.
    private static let verifyGiveUpBackoff: TimeInterval = 10 * 60
    /// 계정별 "당분간 조회 안 함" 시각. (트리거는 계속 쌓아 두고 **조회만** 쉰다.)
    private var verifyGiveUpUntil: [UUID: Date] = [:]
    /// 모델 전용 한도를 **같은 값으로 다시 확인한** 계정 — 이후 재확인을 더 늦춘다.
    /// 모델 한도는 며칠 가는 상태라, 여기서 늦추지 않으면 그 기간 내내 3분마다 조회가 돌아
    /// "게이지 끄면 폴링 0" 계약이 무너진다. 기록이 바뀌면(다른 값/해제) 다시 빠른 주기로.
    private var modelLimitReconfirmed: Set<UUID> = []
    /// 연속 `.discard` 횟수 — 이 계정과 무관한 hit(다른 계정의 뒤늦은 에러)이 계속 흘러들 때
    /// 60초마다 조회가 무한히 도는 것을 막는다. `.discard`는 "이 계정은 멀쩡하다"는 뜻이라
    /// 몇 번 확인했으면 잠시 쉬어도 잃는 게 없다.
    private var consecutiveDiscards: [UUID: Int] = [:]
    private static let discardBackoffThreshold = 3
    /// Claude 활성 계정이 마지막으로 **바뀐** 시각 — 모델 전용 한도를 귀속 증거로 믿어도
    /// 되는지 판단한다(HitAttribution.modelScopeTrustWindow). 전환·외부 로그인·CLI 전환
    /// 어느 경로든 여기서 한 번에 감지된다(틱마다 값 비교).
    private var lastKnownClaudeActive: UUID?
    private var sawClaudeActiveOnce = false
    private var claudeActiveChangedAt: Date = .distantPast

    /// ★ [이슈 #19] 창 소진 hit의 **계정 귀속 검증**. 로그 hit은 트리거일 뿐이고, 이 계정이
    /// 정말 소진인지는 **그 계정의 토큰으로 조회한 usage**가 판정한다(오귀인 구조적 불가).
    ///
    /// 판정이 안 서면(조회 실패/쿨다운) **아무것도 기록하지 않는다.** 잘못된 기록은 폴백을
    /// 후보에서 빼 자동 전환을 통째로 죽이고 가짜 리셋 시각이 몇 시간 남지만, 기록을 미루면
    /// 다음 hit에서 다시 잡히기 때문이다(소진 상태면 에러가 계속 나온다).
    ///
    /// ★ 401을 여기서 needsReauth로 승격하지 않는다 — 이 경로는 "이 hit이 누구 것인가"만
    ///   판정한다. 재인증 판정은 기존 경로(refreshUsageIfStale)가 자기 조건으로 한다.
    /// - Parameter isRetry: 보류 트리거의 재시도인가(= 이번 틱에 새 로그 hit이 온 게 아니다).
    private func verifyAndRecordWindowHit(accountID: UUID?, now: Date,
                                          logHit: RateLimitHit? = nil,
                                          isRetry: Bool = false) async {
        guard let accountID else { return }
        guard let account = store.file.accounts.first(where: { $0.id == accountID }) else {
            pendingHitVerify[accountID] = nil   // 계정이 사라졌다 — 보류도 함께 정리(누수 방지)
            lastHitVerifyAttempt[accountID] = nil
            verifyGiveUpUntil[accountID] = nil
            return
        }
        // 백오프 중 — **조회만** 쉰다. ★ 트리거는 계속 등록한다(셀프리뷰 지적): 여기서
        // 신호를 통째로 버리면, 이 구간에 진짜 소진이 나고 사용자가 (막혔으니 자연스럽게)
        // 타이핑을 멈추는 순간 그 소진은 영영 기록되지 않는다 — 기록이 없으면 onTick의
        // 자가복구도 못 돈다. 조회는 백오프가 끝난 뒤 재시도 루프가 이어서 한다.
        let backingOff: Bool
        if let until = verifyGiveUpUntil[accountID] {
            if now < until {
                backingOff = true
            } else {
                verifyGiveUpUntil[accountID] = nil
                consecutiveDiscards[accountID] = 0
                // 백오프 동안은 시도조차 안 했으므로 수명 시계를 다시 건다 — 안 그러면
                // 쉬는 사이에 수명이 차서, 재개하자마자 곧바로 다시 포기하게 된다.
                if let held = pendingHitVerify[accountID] {
                    pendingHitVerify[accountID] = PendingTrigger(
                        firstSeenAt: now, needsFresherThan: held.needsFresherThan,
                        logHit: held.logHit)
                }
                backingOff = false
            }
        } else {
            backingOff = false
        }
        let trigger: PendingTrigger
        if isRetry {
            guard let previous = pendingHitVerify[accountID] else { return }
            guard now.timeIntervalSince(previous.firstSeenAt) <= Self.pendingHitVerifyTTL else {
                await giveUpVerification(previous, accountID: accountID, now: now)
                return
            }
            trigger = previous
        } else if let previous = pendingHitVerify[accountID],
                  now.timeIntervalSince(previous.firstSeenAt) > Self.pendingHitVerifyTTL {
            // 새 hit이지만 이 계정의 판정은 이미 15분째 안 서고 있다 → 조회는 잠시 쉰다.
            // ★ 단 **새 hit은 새 트리거로 남긴다**: 낡은 트리거를 버리면서 방금 도착한 가장
            //   신선한 증거까지 같이 버리면, 사용자가 (막혔으니) 타이핑을 멈추는 순간 그
            //   소진은 영영 기록되지 않는다.
            await giveUpVerification(previous, accountID: accountID, now: now)
            pendingHitVerify[accountID] = PendingTrigger(firstSeenAt: now, needsFresherThan: now,
                                                         logHit: logHit)
            return
        } else {
            // 새 hit은 **새 데이터를 요구**한다 — 그 사이 팝오버가 떠 놓은 *소진 이전* 스냅샷이
            // "트리거보다 나중"으로 통과해 진짜 소진을 "여유"로 판정하는 걸 막는다.
            // ★ 단 **TTL 기준(firstSeenAt)은 물려받는다**: 새 hit마다 수명을 리셋하면, 판정이
            //   계속 "모르겠다"로 끝나는 상황(리셋 시각을 안 주는 창)에서 사용자가 작업을
            //   이어가는 한 hit이 계속 와 **수명이 영영 안 차고 60초마다 조회가 무한 반복**된다
            //   = 이 코드베이스가 피하는 배경 폴링(셀프리뷰 지적). 두 시각을 나눠 든 이유가 이것.
            trigger = PendingTrigger(firstSeenAt: pendingHitVerify[accountID]?.firstSeenAt ?? now,
                                     needsFresherThan: now,
                                     logHit: logHit ?? pendingHitVerify[accountID]?.logHit)
        }
        pendingHitVerify[accountID] = trigger

        // 디스크 캐시를 먼저 올린다(멱등). ★ 안 하면 두 가지가 깨진다: 팝오버를 한 번도
        //   안 연 상태에서 saveUsageCache()가 **메모리에 있는 계정만** 기록해 나머지 계정의
        //   저장된 게이지를 지우고, 멀쩡한 디스크 캐시를 못 봐서 불필요한 조회를 한 번 더 한다.
        loadUsageCacheIfNeeded()

        let snapshot: UsageSnapshot?
        var judgedByFetch = false
        switch HitAttribution.plan(accountIsLimited: account.isLimited(now: now),
                                   hasModelLimitRecord: account.isModelLimited(now: now),
                                   modelLimitReconfirmed: modelLimitReconfirmed.contains(accountID),
                                   cachedUsageAt: usage[accountID]?.fetchedAt,
                                   hitObservedAt: trigger.needsFresherThan,
                                   lastFetchAttemptAt: lastHitVerifyAttempt[accountID],
                                   now: now) {
        case .skipAlreadyRecorded:
            pendingHitVerify[accountID] = nil   // 이미 기록됨 = 이 트리거는 해소됐다
            return
        case .skipCooldown:
            return                              // 보류 유지 — 다음 틱에 다시 본다
        case .verifyWithCache:
            // ★ 백오프 중에도 이 갈래는 막지 않는다(셀프리뷰 지적) — 백오프의 목적은
            //   **조회를 쉬는 것**이지 판정을 멈추는 게 아니다. 공짜로 판정할 수 있는데
            //   막으면, 그 사이 진짜 소진이 나도 기록이 없어 자동 전환이 최대 10분 늦는다.
            snapshot = usage[accountID]
        case .fetchUsage:
            if backingOff { return }            // 트리거는 남기고 조회만 쉰다
            judgedByFetch = true
            lastHitVerifyAttempt[accountID] = now
            guard let blob = usageQueryBlob(for: accountID),
                  let fetched = try? await UsageFetcher.fetch(keychainBlob: blob) else { return }
            usage[accountID] = fetched      // 게이지도 같이 신선해진다 (같은 계정의 같은 값)
            saveUsageCache()                // 다른 usage 갱신 지점과 동일하게 디스크에도 반영
            snapshot = fetched
        }
        guard let snapshot else { return }
        // ★ 조회하는 동안 시간이 흘렀다(네트워크 최대 10초) — 리셋 시각 비교와 기록에는
        //   틱의 낡은 now가 아니라 **지금**을 쓴다. 안 그러면 그 사이 리셋이 지난 창을
        //   소진으로 인정해, 이미 지난 resetsAt을 기록하면서 전환 알림까지 띄운다.
        let verifiedAt = Date()
        // ★ 모델 전용 한도는 **최근에 전환이 없었을 때만** 귀속 증거로 쓴다 — 그 100%는
        //   며칠 가는 상태라 "누가 이 에러를 냈는지"를 말해 주지 않는다. 오귀인은 전환 직후에만
        //   생기므로, 그 구간에서는 이 증거를 안 쓴다(셀프리뷰 지적). 계정 창 100%는 "지금
        //   막혀 있다"라 시점 정보가 있어 이 제약이 필요 없다.
        let trustModelScope = verifiedAt.timeIntervalSince(claudeActiveChangedAt)
            > HitAttribution.modelScopeTrustWindow
        switch HitAttribution.verdict(usage: snapshot, now: verifiedAt,
                                      trustModelScope: trustModelScope) {
        case .inconclusive:
            // 소진은 맞는데 리셋 시각을 못 얻었다(또는 한도에 바짝 붙어 API가 아직 못 따라옴)
            // — 보류를 유지하되, **방금 본 스냅샷으로는 다시 판정하지 않는다.** 안 그러면
            // 같은 스냅샷이 계속 "트리거보다 나중"으로 통과해 매 틱 같은 답만 내고 새 조회가
            // 영영 안 일어난다(셀프리뷰 지적).
            pendingHitVerify[accountID]?.needsFresherThan = verifiedAt
            // 계정 창은 여유인데 보류라면 그 이유는 모델 전용 한도뿐이다 — 최후 폴백이
            // 이걸 계정 소진으로 잘못 기록하지 않도록 종류를 남긴다(위 필드 주석 참조).
            pendingHitVerify[accountID]?.lastInconclusiveWasModelScoped =
                HitAttribution.inconclusiveIsModelScoped(usage: snapshot)
            return
        case .notYetTrusted:
            // 모델 한도는 보이는데 전환 직후라 못 믿는다 → **트리거를 버린다.**
            // ★ 보류해 뒀다가 창이 지난 뒤 같은 스냅샷으로 다시 판정하면(7차에 그렇게 했다)
            //   신뢰 창은 오귀인을 **5분 미루기만 할 뿐 막지 못한다** — 그 100%는 며칠
            //   그대로라 시간이 지나도 새 증거가 아니다(셀프리뷰 지적). 진짜 모델 한도
            //   사용자는 계속 그 에러를 만나므로, 창이 지난 뒤 **새로 도착한 hit**이
            //   기록한다 — 그게 "전환과 무관하게 발생한 신호"라는 유일한 증거다.
            // 단 백오프 카운터에는 넣지 않는다: 우리가 스스로 만든 판정 불가이지
            // "이 계정과 무관한 hit"의 증거가 아니다.
            pendingHitVerify[accountID] = nil
            return
        case .discard:
            pendingHitVerify[accountID] = nil   // 여유 있음 = 이 hit은 다른 계정 것이었다
            // 이 계정과 무관한 hit이 계속 흘러들면(다른 계정의 뒤늦은 에러) 매번 조회하게
            // 된다 — 몇 번 "멀쩡하다"를 확인했으면 잠시 쉰다. 진짜 소진이 나면 그때는
            // 계정 창이 100%가 되므로 백오프가 끝난 뒤 바로 잡힌다.
            // ★ **조회로 판정한 경우에만 센다**(셀프리뷰 지적): 전환 직후 구 계정의 잔여
            //   에러는 한 배치에 여러 개 몰려 오는데(동시 세션 수만큼), 그중 2·3번째는 방금
            //   받아 둔 캐시로 공짜 판정된다. 그것까지 세면 배치 하나로 임계값을 채워
            //   **멀쩡한 새 활성 계정**이 10분간 백오프에 걸린다 — 이 PR이 다루는 바로 그 시나리오다.
            guard judgedByFetch else { return }
            let discards = (consecutiveDiscards[accountID] ?? 0) + 1
            consecutiveDiscards[accountID] = discards
            if discards >= Self.discardBackoffThreshold {
                verifyGiveUpUntil[accountID] = verifiedAt.addingTimeInterval(Self.verifyGiveUpBackoff)
            }
            return
        case .record(let verified):
            pendingHitVerify[accountID] = nil
            consecutiveDiscards[accountID] = 0
            await record(verified, on: accountID, at: verifiedAt)
        }
    }

    /// 15분 동안 판정을 못 냈다 — 포기하되, **안전한 경우에만** 로그 hit을 그대로 믿는다.
    ///
    /// ★ 이 폴백이 필요한 이유: 이 PR 이후로 소진 기록은 **오직 usage 엔드포인트를 통해서만**
    ///   생긴다. 그래서 API가 죽거나 429를 뱉는 동안엔 claude 자체는 멀쩡히 돌아도 자동 전환이
    ///   통째로 멈춘다 — 수정 전에는 로그만으로 네트워크 없이 전환했다(셀프리뷰 지적).
    /// ★ 안전 조건: **최근에 전환이 없었을 것.** 오귀인은 전환 직후에만 생기므로(전환 전에
    ///   시작된 턴이 뒤늦게 에러를 남긴다), 그 구간만 피하면 로그 hit의 귀속은 사실상 옳다.
    ///   전환 직후라면 아무것도 기록하지 않는다 — 이 PR이 막으려는 바로 그 경우다.
    private func giveUpVerification(_ trigger: PendingTrigger, accountID: UUID, now: Date) async {
        pendingHitVerify[accountID] = nil
        verifyGiveUpUntil[accountID] = now.addingTimeInterval(Self.verifyGiveUpBackoff)
        guard let hit = trigger.logHit,
              now.timeIntervalSince(claudeActiveChangedAt) > HitAttribution.modelScopeTrustWindow
        else { return }
        // ★ 보류가 모델 전용 한도 때문이었다면 **그 종류로** 기록한다 — 로그 hit 자체는
        //   모델을 모르므로(modelScoped=false) 그대로 쓰면 계정 전체 소진이 된다(H1).
        let attributed = trigger.lastInconclusiveWasModelScoped
            ? RateLimitHit(resetsAt: hit.resetsAt, kind: hit.kind, modelScoped: true)
            : hit
        await record(attributed, on: accountID, at: now)
    }

    /// 검증된 소진을 실제로 반영한다.
    private func record(_ verified: RateLimitHit, on accountID: UUID, at verifiedAt: Date) async {
        guard let account = store.file.accounts.first(where: { $0.id == accountID }),
              !account.isLimited(now: verifiedAt) else { return }
        // 같은 내용을 다시 쓰지 않는다 — 모델 전용 한도는 며칠 유지되고 그동안 사용자는 계정을
        // 계속 쓰므로 hit이 반복해서 온다. 매번 저장하면 accounts.json이 무의미하게 갱신되고
        // recordedAt만 흔들린다(UI 깜빡임·불필요한 디스크 쓰기).
        if let existing = account.rateLimit, existing.resetsAt == verified.resetsAt,
           existing.modelScoped == verified.modelScoped, existing.resetsAt > verifiedAt {
            // 같은 모델 한도를 다시 확인했다 = 이제 알아낼 건 "계정 창이 새로 소진됐는지"뿐
            // → 재확인 주기를 늦춘다(위 modelLimitReconfirmed 참조).
            if verified.modelScoped { modelLimitReconfirmed.insert(accountID) }
            return
        }
        modelLimitReconfirmed.remove(accountID)   // 새로운 기록 — 다시 빠른 주기로
        recordHit(verified, on: accountID, now: verifiedAt)
        // ★ 엔진 호출은 **이 계정이 아직 활성일 때만.** onRateLimitHit은 hit을 인자 계정이
        //   아니라 "현재 활성 계정"에 얹어 판단하므로(markedFile), 그 사이 전환이 끝났다면
        //   엉뚱한 계정을 소진으로 보고 결정한다. 기록만 남기고 나머지는 onTick에 맡긴다.
        if store.file.activeByProvider[.claude] == accountID {
            await apply(engines[.claude]!.onRateLimitHit(file: store.file, hit: verified,
                                                         now: verifiedAt),
                        provider: .claude, now: verifiedAt)
        }
        file = store.file
    }

    private func processCodexBatches(_ batches: [SessionLogWatcher<MobiusCore.CodexRateLimitStatus>.Batch],
                                     now: Date) async {
        // 라우터는 활성 변경 감지를 겸하므로 배치가 비어도 매 틱 호출한다
        // (CLI/외부 전환도 다음 틱에 격리가 반영되도록).
        let codexActiveID = store.file.activeByProvider[.codex]
        let routed = codexRouter.route(batches: batches,
                                       trackedFiles: codexWatcher.trackedFiles,
                                       activeID: codexActiveID)
        guard let codexActiveID else { return }
        if let latest = routed.latestUsage {
            usage[codexActiveID] = latest.usageSnapshot(fetchedAt: now)
        }
        for hit in routed.exhaustionHits {
            // 이미 한도 기록이 있으면 중복 처리하지 않는다 — codex는 매 턴 상태를 남기므로
            // 이 가드가 없으면 15초마다 알림·엔진 호출이 반복된다 (알림 폭풍).
            let active = store.file.accounts.first { $0.id == codexActiveID }
            guard let active, !active.isLimited(now: now) else { break }
            recordHit(hit, on: codexActiveID, now: now)
            await apply(engines[.codex]!.onRateLimitHit(file: store.file, hit: hit, now: now),
                        provider: .codex, now: now)
        }
    }

    // MARK: 임계값 선제 전환 (advisory)

    /// 임계값 기능이 꺼져 있을 때 남은 advisory를 정리한다 — 매 틱(가드 위)에서 값싸게 돈다.
    /// setAdvisory의 동등성 스킵 덕에 첫 정리 이후 반복 틱은 인메모리 스캔 비용만 든다(재저장 없음).
    private func clearAdvisoriesIfFeatureOff() {
        for p in store.file.accounts where p.provider == .claude && p.advisory != nil {
            try? store.setAdvisory(p.id, nil)
        }
    }

    /// 이 5분 폴을 돌릴 이유가 있는가 — **전환할 곳이 없으면 돌리지 않는다.**
    ///
    /// 폴 자체가 계정당 네트워크 1회다. 자동 전환이 꺼져 있거나 Claude 계정이 하나뿐이면
    /// 소진을 기록해도 갈 곳이 없어 조회가 순수 비용이 된다("끄면 아무것도 안 돈다" 계약).
    /// 두 조건 모두 실제로 존재한다 — 계정 하나로 게이지만 보는 사용자, 자동 전환을 끄고
    /// 직접 고르는 사용자. 로그 429 경로는 이 게이트와 무관하게 그대로 돈다.
    static func usagePollIsWorthwhile(autoSwitchEnabled: Bool, claudeAccountCount: Int) -> Bool {
        autoSwitchEnabled && claudeAccountCount >= 2
    }

    /// 활성 Claude 사용량 폴 — **5분 fresh sync 성사 뒤에만** 호출된다(활성 secret이 방금 갱신됨).
    /// 활성 Claude를 저장 secret으로 조회(라이브 2차 읽기 없음)해 ① 소진이면 그대로 기록하고,
    /// ② advisory 기능이 켜져 있으면 히스테리시스로 advisory를 set/clear한 뒤 후보 탐색→엔진
    /// 판정→결정 적용을 한다.
    ///
    /// ★ ①과 ②의 게이트가 다르다. ②는 사용자 옵션(`advisorySwitchEnabled`)이지만 ①은
    ///   **자동 전환의 최소 동작**이다 — 로그 429 없이 100%에 도달하는 경우(Desktop·웹에서
    ///   사용량을 태웠거나, 막힌 사용자가 CLI 요청을 더 보내지 않는 경우)가 유일한 기록 경로를
    ///   비워, 옵션을 켜지 않은 사용자에게 자동 전환이 통째로 사라졌다(2026-09-16 실측).
    private func pollActiveUsage(now: Date) async {
        // 재인증 필요/저장 secret 없으면 스킵(secret은 5분 블록이 방금 동기화했다).
        guard let active = store.file.active(of: .claude), !active.needsReauth,
              let blob = (try? store.secret(for: active.id))?.keychainBlob else { return }
        // 저장 secret으로 조회 — 방금 fresh sync됐으므로 라이브를 한 번 더 읽지 않는다.
        // 실패(네트워크/타임아웃/5xx 등)는 서킷 브레이커 카운터를 올린다. 3연속이면 위
        // 5분 블록이 다음부터 폴을 건너뛴다. 성공하면 0으로 리셋.
        guard let snap = try? await UsageFetcher.fetch(keychainBlob: blob) else {
            consecutiveUsagePollFailures += 1
            return
        }
        consecutiveUsagePollFailures = 0
        usage[active.id] = snap

        // ① 소진 기록 — **로그 429가 없어도.** 판정은 로그 경로와 **같은 함수**로 한다
        //    (`HitAttribution.verdict`): 규칙을 두 곳에 적으면 같은 스냅샷이 "어느 경로로
        //    들어왔느냐"에 따라 다르게 판정된다. 로그 경로가 씌우는 귀속 검증은 여기 필요 없다
        //    — 이 스냅샷은 **이 계정의 토큰으로** 조회한 것이라 오귀인이 구조적으로 불가능하다.
        //    이미 같은 기록이 있으면 `record`가 스스로 되쓰기를 막는다.
        let verifiedAt = Date()
        if case let .record(hit) = HitAttribution.verdict(usage: snap, now: verifiedAt) {
            await record(hit, on: active.id, at: verifiedAt)
        }

        // ② 임계값 선제 전환(사용자 옵션). 위 기록이 전환까지 끝냈으면 활성이 바뀌었으므로
        //    이번 폴의 advisory 작업은 대상이 사라진다 — 조회 직후와 같은 이유로 재확인한다.
        guard advisoryEffectivelyEnabled,
              let current = store.file.active(of: .claude), current.id == active.id else { return }

        let threshold = advisoryThreshold
        let util = snap.fiveHourPercent ?? 0

        // 히스테리시스 set/clear. set: 임계값 이상 + 리셋 시각 존재 → detectedAt 보존해 세운다.
        // clear: 밴드 아래(임계값-5 이하) + 기존 advisory 존재 → 해제하되 백오프·last-advised
        //        맵은 **건드리지 않는다**(새 창은 resetsAt이 달라 자연히 재알림된다).
        // 그 사이(밴드 내부)면 그대로 둔다.
        if AdvisoryRecord.shouldSet(utilization: util, threshold: threshold),
           let resetsAt = snap.fiveHourResetsAt {
            let detectedAt = current.advisory?.detectedAt ?? now  // 이미 있었으면 첫 시각 보존
            try? store.setAdvisory(active.id,
                AdvisoryRecord(utilization: util, resetsAt: resetsAt, detectedAt: detectedAt))
        } else if AdvisoryRecord.shouldClear(utilization: util, threshold: threshold),
                  current.advisory != nil {
            try? store.setAdvisory(active.id, nil)
        }
        // else(밴드 내부 or advisory 없음): advisory 필드는 그대로 둔다.

        // advisory가 여전히 유효한 경우에만 후보 탐색 + 엔진 판정 + 알림/전환.
        guard let advised = store.file.active(of: .claude), advised.id == active.id,
              let advisory = advised.advisory else { return }

        let engine = engines[.claude]!
        var verifiedCandidate: UUID?
        // 후보 탐색은 "전환 가능(switch-eligible)"할 때만 — 풀 자동 전환이 켜져 있고(스펙 AC3:
        // 폴백은 switch-eligible probe에서만 읽는다) 백오프 창을 지났을 때. 자동 전환이 꺼져
        // 있으면 후보는 알림 경로에서 쓰이지 않으므로 탐색(네트워크)도 생략한다.
        if store.file.isAutoSwitchEnabled(.claude),
           engine.shouldProbeCandidates(lastNoCandidateAt: lastNoCandidateAt, now: now) {
            verifiedCandidate = await probeCandidate(now: now)
            // 후보 있으면 백오프 리셋(distantPast=즉시 재탐색 허용), 없으면 now(백오프 시작).
            // ★ 여기서만 리셋한다 — advisory clear에서는 절대 리셋하지 않는다(오실레이션 방어).
            lastNoCandidateAt = verifiedCandidate != nil ? .distantPast : now
            // 후보 탐색(네트워크) 중 활성이 바뀌었을 수 있다 — 재확인.
            guard let still = store.file.active(of: .claude), still.id == active.id else { return }
        }

        // ★★★ 로드-베어링 순서 (finding MEDIUM-notify-ordering) — 절대 재배열 금지.
        // "맵을 먼저 쓰고 플래그를 계산"하면 비교가 항상 같아져 alreadyAdvised가 영원히 true가
        // 되고, 토글-off 알림(notifyAdvisoryOnly)이 영구히 삼켜진다(엔진 테스트는 플래그를
        // 파라미터로 주입받아 초록으로 남는다 — 캡처-비교-호출-쓰기 순서로만 잡힌다).
        //   1) 직전 last-advised resetsAt을 **맵 쓰기 전에** 지역 변수로 포착한다.
        let priorAdvised = lastAdvisedResetsAt[active.id]
        //   2) 포착한 지역 값과 이번 advisory의 resetsAt을 비교해 alreadyAdvised를 계산한다.
        let alreadyAdvised = priorAdvised == advisory.resetsAt
        //   3) 엔진 판정을 호출하고 결정을 적용한다.
        let decision = engine.checkAdvisory(file: store.file, activeID: active.id,
                                            verifiedCandidate: verifiedCandidate,
                                            alreadyAdvised: alreadyAdvised, now: now)
        await apply(decision, provider: .claude, now: now)
        //   4) **그런 다음에야** 이번 폴의 resetsAt을 맵에 쓴다(토글 상태 무관).
        lastAdvisedResetsAt[active.id] = advisory.resetsAt
    }

    /// advisory가 걸린 활성 계정의 폴백 후보를 우선순위대로 검증한다. 임계값 미만인 첫 후보의
    /// id를 반환(없으면 nil). ★ **네트워크 refresh는 `.escalate`(만료+쿨다운경과)에서만** —
    /// `refreshUsageIfStale`의 검증된 가드를 그대로 미러링한다(멀쩡한 폴백 토큰을 회전시켜 벽돌
    /// 만들지 않도록). 이 메서드는 배지 집합·notified 집합을 절대 건드리지 않고, checker가
    /// 스스로 하는 것 이상으로 needsReauth를 마킹하지 않는다(추가 알림도 없음 — stale sweep 전담).
    private func probeCandidate(now: Date) async -> UUID? {
        let threshold = advisoryThreshold
        let active = store.file.activeByProvider[.claude]
        for p in store.file.accounts where p.provider == .claude
            && p.id != active && !p.isLimited(now: now) && !p.needsReauth {
            guard let secret = try? store.secret(for: p.id) else { continue }
            var fetchBlob = secret.keychainBlob
            switch AutoSwitchEngine.candidateProbeAction(
                    expiresAt: UsageFetcher.expiresAt(from: fetchBlob),
                    now: now,
                    lastRefreshAttemptAt: lastUsageRefreshAttemptAt[p.id],
                    cooldown: Self.usageRefreshRetryCooldown) {
            case .skipCooldown:
                continue   // 만료 + 쿨다운 중 — 판정 없이 스킵(죽었다고 단정 금지)
            case .useStoredToken:
                break      // 저장 토큰 유효(또는 만료 정보 없음) — 네트워크 없이 아래서 조회
            case .escalate:
                // ★ 만료 + 쿨다운 경과일 때만 네트워크 refresh로 승격한다.
                lastUsageRefreshAttemptAt[p.id] = now
                switch await fallbackChecker.check(p.id, activeAccountID: active,
                                                   now: now, allowNetwork: true) {
                case .refreshedAlive:
                    lastUsageRefreshAttemptAt[p.id] = nil   // 성공 — 쿨다운 해제
                    guard let fresh = (try? store.secret(for: p.id))?.keychainBlob else { continue }
                    fetchBlob = fresh   // 회전된 신선한 토큰으로 조회
                default:
                    continue   // dead/storeFailed/locallyDead/noRefreshToken/transient 등 —
                               // checker가 이미 마킹, 추가 알림 없이 스킵(stale sweep 전담)
                }
            }
            guard let snap = try? await UsageFetcher.fetch(keychainBlob: fetchBlob) else { continue }
            usage[p.id] = snap
            if (snap.fiveHourPercent ?? 0) < threshold { return p.id }   // 임계값 미만 = 검증된 후보
        }
        return nil
    }

    private func apply(_ decision: Decision, provider: Provider, now: Date) async {
        // ★ 취소된 틱은 결정을 **적용하지 않는다.** 이 함수가 자동 전환(자격증명 스왑)과 그
        // 알림의 유일한 관문이라, 여기 한 줄이 "기능을 끈 뒤엔 자동으로 계정이 안 바뀐다"를
        // 전부 덮는다(수동 전환은 `performSwitch` 로 따로 가므로 영향받지 않는다).
        // 취소는 `await` 지점에서만 들리는데 틱에는 그 지점이 여럿이다 — 스캔·usage 조회를
        // 지나 여기 도착했을 때는 이미 `stop()` 이 끝나 있을 수 있다.
        guard !Task.isCancelled else { return }
        // 적용할 것이 없으면 여기서 끝 — 아래 가드보다 **먼저** 빠져나간다.
        // `externalAppBlocksSwitching()` 은 LaunchServices 조회(`NSRunningApplication`)를 돌리는데
        // 이 함수는 프로바이더마다 **매 틱** 불리므로, 결정이 없는 평시에도 3초당 2회 조회가
        // 상시로 깔린다(감시 폴링을 이벤트 구동으로 바꿔도 이쪽이 남으면 유휴 비용은 그대로다).
        // 판정이 "아무것도 하지 않음"이면 자격증명도 알림도 안 건드리므로 가드가 지킬 것이 없다 —
        // 가드는 **쓰기 직전**에만 의미가 있다.
        if case .none = decision { return }
        // ★ 취소 확인과 같은 이유로 이중 writer 가드도 여기서 한 번 더 본다. 이 틱은
        // `preflightFallback` 의 `await` 를 지나오는데, 그 사이에 Mobius.app 이 뜨면 위 취소
        // 확인은 이미 통과한 뒤다 — 확인을 입구에만 두면 "감지했는데도 한 번 더 전환한" 경우가
        // 남는다.
        guard !externalAppBlocksSwitching() else { return }
        switch decision {
        case .none: break   // 위에서 이미 반환됐다 — switch 전수성 유지용
        case .allExhausted:
            notify(title: l.accountsNotifyAllExhaustedTitle(provider.displayName),
                   body: l.accountsNotifyAllExhaustedBody)
        case let .notifyAdvisoryOnly(id):
            // 임계값 선제 경고 알림 — **소진이 아니다**(문구가 섞이면 거짓말). 자동 전환이
            // 꺼진 풀에서만 온다. 계정+창(resetsAt) 전이당 1회 — 엔진이 alreadyAdvised로
            // 걸러 이 케이스를 딱 한 번만 돌려주므로(pollActiveUsage의 last-advised 맵) 여기선
            // 무조건 알린다.
            let name = store.file.accounts.first { $0.id == id }?.nickname ?? "?"
            notify(title: l.accountsNotifyAdvisoryTitle(name),
                   body: l.accountsNotifyAdvisoryBody(name))
        case let .notifyExhaustedOnly(id):
            let name = store.file.accounts.first { $0.id == id }?.nickname ?? "?"
            notify(title: l.accountsNotifyExhaustedManualTitle,
                   body: l.accountsNotifyExhaustedManualBody(name))
        case let .notifyModelLimitedOnly(id):
            // ★ "계정 한도 소진"과 문구를 공유하면 거짓말이 된다 — 계정은 다른 모델로 계속
            //   쓸 수 있다(같은 이유로 메뉴바·CLI도 이 상태를 소진으로 표시하지 않는다).
            let name = store.file.accounts.first { $0.id == id }?.nickname ?? "?"
            notify(title: l.accountsNotifyModelLimitedManualTitle,
                   body: l.accountsNotifyModelLimitedManualBody(name))
        case let .switchTo(id, reason):
            // 전환 직전 검증(Claude 전용): 자동 폴백(activeExhausted)이나 임계값 선제
            // 전환(thresholdAdvisory)으로 넘어가기 전에 대상 계정을 실제 OAuth refresh로
            // 확인한다. 죽었으면 취소(마킹됨) → 다음 틱에 엔진이 다음 폴백을 고른다.
            // (Codex는 OAuth refresh 검증 경로가 없어 스킵한다.)
            // 모델 전용 한도 전환도 "자동 전환"이다 — 전환 전 검증과 primary 자동 복귀
            // 플래그를 계정 소진과 동일하게 적용한다(문구만 다르다).
            let autoFromPrimary = reason == .activeExhausted || reason == .thresholdAdvisory
                || reason == .modelExhausted
            if autoFromPrimary, provider == .claude {
                guard await preflightFallback(id, now: now) else { file = store.file; return }
            }
            let fromID = store.file.activeByProvider[provider]
            if provider == .codex { await quiesceCodexUsageTask() }
            do {
                try switcher.switchTo(id)
                // 자동 전환 쪽 뒤처리 통지. 수동 전환은 `performSwitch` 가 같은 일을 한다 —
                // 두 경로가 갈라져 있어 한쪽만 배선하면 그쪽 전환에서만 게이지가 낡는다.
                onSwitched?(provider)
                engines[provider]?.noteSwitched(now: now,
                                                forModelLimit: reason == .modelExhausted,
                                                leftAccount: fromID)
                // 자동 전환의 결과인지 기록 — onTick의 primary 복귀는 이 플래그가
                // true일 때만 일어난다 (수동 전환 자동 회귀 방지). 임계값 선제 전환도
                // 자동 전환이므로 소진 전환과 동일하게 플래그를 세운다.
                try? store.setAutoSwitchedFromPrimary(autoFromPrimary, provider: provider)
                MobiusNotification.postAccountsChanged()
                let name = store.file.accounts.first { $0.id == id }?.nickname ?? "?"
                let fromName = store.file.accounts.first { $0.id == fromID }?.nickname
                // ★ [정정 2026-08-15] "새로 시작하는 세션부터 적용돼요"는 틀린 안내였다 —
                //   실행 중 claude 세션은 **턴마다 자격증명을 다시 읽어** 다음 입력부터
                //   새 계정으로 이어진다(옛 계정이 쓰이는 건 진행 중이던 한 턴뿐.
                //   claude 2.1.232/2.1.233 기준). 필요 없는 세션 재시작을 시키고 있었다.
                //   ★ Codex는 전제가 정반대다 — 실행 중 세션이 시작 시점 토큰을 계속 쓰고
                //   토큰 갱신으로 로그인을 되돌리기까지 하므로(클로버, README 참조)
                //   "이전 세션 종료"가 맞는 안내다. 한 문구로 합치지 말 것.
                //   ★ if/else가 아니라 switch인 이유(셀프리뷰 반영): 프로바이더가 늘면
                //   "claude가 아니면 codex"가 조용히 틀린 안내를 하게 된다 — 컴파일 에러로
                //   드러나야 한다. 세 알림이 같은 note를 공유하므로 복귀 알림도 함께 맞는다.
                let sessionNote: String
                switch provider {
                case .claude: sessionNote = l.accountsNotifySessionNoteClaude
                case .codex: sessionNote = l.accountsNotifySessionNoteCodex
                }
                switch reason {
                case .primaryRecovered:
                    notify(title: l.accountsNotifyPrimaryRecoveredTitle(name),
                           body: l.accountsNotifyPrimaryRecoveredBody(note: sessionNote))
                case .thresholdAdvisory:
                    // ★ 소진 표현 금지 — 아직 쓸 수 있는데 임계값에 가까워 미리 옮긴 것이다.
                    notify(title: l.accountsNotifyAdvisorySwitchTitle(name),
                           body: l.accountsNotifyAdvisorySwitchBody(from: fromName ?? "?", to: name,
                                                                   note: sessionNote))
                case .activeExhausted:
                    notify(title: l.accountsNotifySwitchedTitle(name),
                           body: l.accountsNotifySwitchedBody(from: fromName ?? "?", to: name,
                                                              note: sessionNote))
                case .modelExhausted:
                    // ★ 계정 소진과 문구를 섞지 않는다 — 떠난 계정은 다른 모델로 멀쩡히 쓸 수 있다.
                    notify(title: l.accountsNotifySwitchedTitle(name),
                           body: l.accountsNotifyModelSwitchedBody(from: fromName ?? "?", to: name,
                                                                   note: sessionNote))
                }
            } catch {
                lastError = l.accountsErrorAutoSwitchFailed(error.localizedDescription)
                return
            }
            // Desktop 자동 Fallback (Claude 전용): 옵션 켬 + 대상 스냅샷 존재 시에만.
            // ★ `MobiusFeature.desktopSyncInScope` 가 먼저 온다 — 1차 범위 밖 기능이라 저장된
            // `desktopAutoSwitchEnabled` 값과 무관하게 막는다(`MobiusFeature.swift` 참조).
            if MobiusFeature.desktopSyncInScope, provider == .claude,
               store.file.desktopAutoSwitchEnabled {
                switchDesktopIfPossible(from: fromID, to: id)
            }
        }
    }

    // MARK: 사용자 액션

    func manualSwitch(to id: UUID) {
        // 이중 writer 가드 — 수동 전환도 자동 전환과 **똑같이** 전역 자격증명을 스왑한다.
        // 여기서 먼저 막는 이유는 아래 `preflightFallback` 이 네트워크 refresh(토큰 회전)를
        // 하기 때문이다: 어차피 전환하지 못할 계정의 토큰을 굳이 돌려 놓을 이유가 없다.
        // (UI 는 막힌 동안 카드를 비활성화하므로 평소엔 여기 닿지 않는다 — `AccountsView`.)
        guard !externalAppBlocksSwitching() else { return }
        // 재진입 가드 — 두 계정을 빠르게 연속 클릭하면 독립된 두 전환이 경합해 나중에 끝난
        // 쪽이 이긴다(사용자가 마지막에 누른 계정과 최종 활성이 달라질 수 있었다). 아래 모든
        // 분기(동기 즉시 전환 포함)보다 **먼저** 막아야 한다 — 진행 중인 분기가 `await` 에서
        // 잠깐 양보하는 사이 다른 분기가 동기로 끝까지 돌면, 나중에 깨어난 진행 중인 분기가
        // 그 결과를 덮어쓸 수 있기 때문이다. `desktopSwitchTask` 와 같은 패턴 — 조용히
        // 무시하지 않고 배너로 알린다(무반응은 그 자체로 고장처럼 보인다).
        guard manualSwitchTask == nil else {
            lastError = l.accountsErrorSwitchBusy
            return
        }
        guard let provider = store.file.accounts.first(where: { $0.id == id })?.provider else { return }
        let alreadyFlagged = store.file.accounts.first { $0.id == id }?.needsReauth ?? false
        // Codex는 OAuth refresh 검증 경로가 없고, 이미 재로그인 필요로 마킹된 계정은 사용자가
        // 의도적으로 고른 것이므로 — 두 경우 모두 preflight 없이 바로 전환한다.
        guard provider == .claude, !alreadyFlagged else {
            if provider == .codex {
                // 낙관적 표시 + ①a fresh-read 가드 강화(전환 대상 계정의 게이지 refresh를 스킵시킴).
                pendingSwitchID = id
                manualSwitchTask = Task { @MainActor in
                    defer { pendingSwitchID = nil; manualSwitchTask = nil }
                    await quiesceCodexUsageTask()
                    guard !Task.isCancelled else { return } // stop()/가드가 끊음 — 전환하지 않는다
                    performSwitch(to: id)
                }
            } else {
                performSwitch(to: id)   // 이미 재인증 필요로 마킹된 claude — preflight 없이 전환
            }
            return
        }
        // 낙관적 표시: 클릭 즉시 이 계정을 활성으로 보여줘 UI가 스무스하게 전환된 것처럼 보이게 한다.
        // 실제 refresh(대상이 아직 폴백일 때 — 안전) + 자격증명 스왑은 백그라운드에서.
        pendingSwitchID = id
        manualSwitchTask = Task { @MainActor in
            defer { pendingSwitchID = nil; manualSwitchTask = nil }   // 완료되면 실제 activeAccountID가 표시를 인계
            guard await preflightFallback(id, now: Date()) else { reload(); return } // 죽음 → 취소(마킹됨)
            guard !Task.isCancelled else { return } // stop()/가드가 끊음 — 전환하지 않는다
            performSwitch(to: id)
        }
    }

    private func performSwitch(to id: UUID) {
        // 수동 전환이 실제로 자격증명을 쓰는 **관문**. `manualSwitch` 가 먼저 보지만 그 사이에
        // `preflightFallback` 의 `await` 가 있어 그때 상대가 뜰 수 있고, 나중에 다른 호출부가
        // 생기면 입구의 확인은 같이 따라오지 않는다 — 관문 쪽 확인이 진짜 계약이다.
        guard !externalAppBlocksSwitching() else { return }
        let provider = store.file.accounts.first { $0.id == id }?.provider ?? .claude
        let fromID = store.file.activeByProvider[provider]
        do {
            try switcher.switchTo(id)
            // 수동 전환 쪽 뒤처리 통지 — 자동(`apply`)과 **다른 경로**라 따로 배선한다.
            onSwitched?(provider)
            engines[provider]?.noteSwitched()
            // 사용자가 직접 고른 계정 — 모델 전용 한도(Fable 등)로 자동으로 밀어내지 않는다.
            try? store.setUserPinned(id)
            // 사용자의 의지로 전환 — 자동 복귀 대상이 아니다
            try? store.setAutoSwitchedFromPrimary(false, provider: provider)
            MobiusNotification.postAccountsChanged()
            reload()
        } catch {
            lastError = l.accountsErrorSwitchFailed(error.localizedDescription)
            return
        }
        // Desktop 동시 전환 (Claude 전용 — 옵션 켜짐 + 대상 스냅샷 존재 시).
        // ★ `MobiusFeature.desktopSyncInScope` 가 먼저 온다 — 1차 범위 밖 기능이라 저장된
        // `desktopSyncEnabled` 값과 무관하게 막는다. 이 값은 지속화 필드 기본값이 **`true`**
        // 라 기존 accounts.json 에 이미 `true` 로 저장돼 있을 수 있다(실측, `MobiusFeature.swift`
        // 참조) — 저장값에 의존하지 않아야 그 파일에서도 안전하다.
        if MobiusFeature.desktopSyncInScope, provider == .claude, store.file.desktopSyncEnabled {
            switchDesktopIfPossible(from: fromID, to: id)
        }
    }

    /// 진행 중인 Desktop 전환 태스크 — 자동/수동 어느 경로든 하나만 허용.
    private var desktopSwitchTask: Task<Void, Never>?

    /// 테스트 전용 — `switchDesktopIfPossible` 진입 횟수. 실제 Desktop 조작(`DesktopCoordinator`)
    /// 은 실물 `NSRunningApplication`/`com.anthropic.claudefordesktop` 을 건드리므로 테스트에서
    /// 절대 실행하고 싶지 않다 — 이 함수 **진입 여부**만으로 `MobiusFeature.desktopSyncInScope`
    /// 게이트가 호출부를 막는지 확인한다(`DesktopSyncScopeTests`).
    private(set) var desktopSwitchAttemptsForTesting = 0

    /// CLI 전환 성공 후 Desktop 동반 전환. 실패해도 CLI 전환은 유지된다.
    private func switchDesktopIfPossible(from fromID: UUID?, to id: UUID) {
        desktopSwitchAttemptsForTesting += 1
        guard let fromID, fromID != id,
              desktopCapture == nil else { return } // 가이드 캡처 중엔 Desktop을 건드리지 않음
        // 대상이 캡처됐으면 복원, 미캡처지만 Desktop이 로그인돼 있으면 로그아웃한다.
        // 둘 다 아니면(대상 미캡처 + Desktop 이미 로그아웃) 건드릴 필요 없음 — 불필요한 재실행 방지.
        guard desktopSwitcher.hasSnapshot(for: id) || desktopSwitcher.hasLiveLogin() else { return }
        // 직렬화 게이트: 이전 Desktop 전환이 진행 중이면 이번 요청은 드롭 —
        // 연속 전환(A→B, B→C)이 겹치며 스냅샷이 교차 오염되는 것을 방지 (코디네이터도 재차 차단).
        guard desktopSwitchTask == nil else {
            lastError = l.accountsErrorDesktopSwitchBusy
            return
        }
        let targetUncaptured = !desktopSwitcher.hasSnapshot(for: id)
        desktopSwitchTask = Task { @MainActor in
            defer { desktopSwitchTask = nil }
            do { try await desktopCoordinator.switchDesktop(from: fromID, to: id) }
            catch { lastError = l.accountsErrorDesktopSwitchFailed(l.accountsErrorMessage(error)); return }
            // 미캡처 계정으로 전환 = Desktop 로그아웃됨. 이제 사용자가 Desktop에 로그인하면
            // 그 세션을 자동으로 캡처해 다음부터는 전환만으로 복원되게 한다.
            if targetUncaptured { startDesktopAutoCapture(for: id) }
        }
    }

    private var desktopAutoCaptureTask: Task<Void, Never>?

    /// 미캡처 계정으로 전환해 Desktop이 로그아웃된 뒤, 사용자가 그 계정으로 로그인하면
    /// 자동으로 캡처한다. (로그아웃 확인 → 새 로그인 전이로만 발동, 5분 후 포기.)
    private func startDesktopAutoCapture(for id: UUID) {
        desktopAutoCaptureTask?.cancel()
        desktopAutoCaptureTask = Task { @MainActor in
            defer { desktopAutoCaptureTask = nil }
            var confirmedLoggedOut = false
            var loginSeenAt: Date?
            let deadline = Date().addingTimeInterval(300)
            while Date() < deadline {
                do { try await Task.sleep(for: .seconds(2)) } catch { return }
                // 그 사이 계정을 바꿨거나 가이드 캡처가 시작되면 중단
                guard store.file.activeAccountID == id, desktopCapture == nil else { return }
                let loggedIn = desktopSwitcher.hasLiveLogin()
                if !confirmedLoggedOut {
                    if !loggedIn { confirmedLoggedOut = true }
                    continue // 아직 로그인 상태면 자동캡처 안 함(오캡처 방지)
                }
                guard loggedIn else { loginSeenAt = nil; continue }
                if loginSeenAt == nil { loginSeenAt = Date() }
                else if Date().timeIntervalSince(loginSeenAt!) >= 2 { // 토큰 기록 완료 대기
                    do {
                        try desktopSwitcher.capture(for: id)
                        try store.update(id) { $0.hasDesktopSnapshot = true }
                        MobiusNotification.postAccountsChanged()
                        reload()
                        let name = store.file.accounts.first { $0.id == id }?.nickname ?? "?"
                        notify(title: l.accountsNotifyDesktopLinkedTitle,
                               body: l.accountsNotifyDesktopLinkedBody(name))
                    } catch { lastError = l.accountsErrorDesktopAutoCaptureFailed(error.localizedDescription) }
                    return
                }
            }
        }
    }

    func moveFallback(provider: Provider, from source: IndexSet, to destination: Int) {
        // List.onMove는 풀 계정 배열 인덱스로 호출한다 (primary 행 0은 moveDisabled).
        // destination은 "제거 전 삽입 위치"라 from보다 뒤면 1을 빼고, primary 위(0)로
        // 떨어뜨리면 첫 fallback 자리(1)로 고정한다 — 승격은 명시적 메뉴로만.
        guard let from = source.first else { return }
        var to = destination
        if to > from { to -= 1 }
        to = max(to, 1)
        guard from != to, from >= 1 else { return }
        try? store.moveFallback(provider: provider, fromIndex: from, toIndex: to)
        MobiusNotification.postAccountsChanged()
        reload()
    }

    func setAutoSwitch(_ on: Bool, provider: Provider) {
        try? store.setAutoSwitch(on, provider: provider)
        MobiusNotification.postAccountsChanged()
        reload()
    }

    func setDesktopSync(_ on: Bool) {
        try? store.setDesktopSync(on)
        MobiusNotification.postAccountsChanged()
        reload()
    }

    func setDesktopAutoSwitch(_ on: Bool) {
        try? store.setDesktopAutoSwitch(on)
        MobiusNotification.postAccountsChanged()
        reload()
    }


    func setPrimary(_ id: UUID) {
        do { try store.setPrimary(id) } catch {
            lastError = l.accountsErrorSetPrimaryFailed(error.localizedDescription)
            return
        }
        MobiusNotification.postAccountsChanged()
        reload()
    }

    func removeAccount(_ id: UUID) {
        try? store.remove(id)
        desktopSwitcher.deleteSnapshot(for: id) // 고아 Desktop 스냅샷 정리
        MobiusNotification.postAccountsChanged()
        reload()
    }

    private var loginFlow: LoginFlowController?
    /// `addAccount()` 의 진행 중 태스크 — `stop()` 취소 대상(부류 스윕 대상 필드).
    /// 재진입 방지는 여전히 `loginFlow`(위)가 맡는다: 이 태스크가 시작하기 **전**(동기)에
    /// 세팅되므로 `loginFlow == nil` 가드가 항상 먼저 걸린다.
    private var addAccountTask: Task<Void, Never>?

    /// 테스트 전용 — 로그인 플로우가 떴는지. 이중 writer 가드가 계정 **추가**까지 막는지는
    /// 이것으로만 확인할 수 있다(막지 못하면 `claude auth login` 이 실제로 실행된다).
    var isLoginFlowActiveForTesting: Bool { loginFlow != nil }

    func addAccount() {
        // 계정 추가도 라이브 자격증명을 바꾼다(`claude auth login` → adopt). 상대가 살아 있는
        // 동안 로그인하면 상대의 reconcile 이 그 변경을 자기 쪽으로 흡수해 두 앱의 프로필이
        // 갈라진다 — 전환과 같은 관문으로 막는다.
        guard !externalAppBlocksSwitching() else { return }
        guard loginFlow == nil else { return } // 진행 중이면 중복 실행 방지
        let flow = LoginFlowController(io: io, store: store, switcher: switcher)
        loginFlow = flow
        addAccountTask = Task { @MainActor in
            defer { addAccountTask = nil }
            // 계정 추가는 `claude auth login`으로 동작 — CLI가 없으면 설정에서 설치하도록 안내.
            // 탐색은 대화형 로그인 셸을 띄울 수 있어(초 단위) **메인에서 기다리지 않는다** —
            // 여기서 동기로 부르면 버튼을 누른 순간 팝오버가 통째로 멈춘다.
            guard await Task.detached(priority: .userInitiated,
                                      operation: { ClaudeCLI.isInstalled }).value else {
                lastError = l.accountsErrorClaudeCLIMissing
                notify(title: l.accountsNotifyClaudeCLINeededTitle,
                       body: l.accountsNotifyClaudeCLINeededBody)
                loginFlow = nil
                return
            }
            do {
                switch try await flow.run() {
                case .added(let profile):
                    notify(title: l.accountsNotifyAccountAddedTitle,
                           body: "\(profile.nickname) <\(profile.emailAddress)>")
                case .refreshed(let profile):
                    notify(title: l.accountsNotifyAccountRefreshedTitle,
                           body: "\(profile.nickname) <\(profile.emailAddress)>")
                }
                reload()
                loginFlow = nil
                // 계정 추가는 CLI 계정만 추가한다. Desktop 연결은 사용자가 카드 메뉴에서
                // 필요할 때 직접 한다 (계정 추가 흐름에 끼워넣으면 저장 계정이 뒤섞였음).
                return
            } catch is CancellationError {
                // stop()/이중 writer 가드가 진행 중인 로그인을 끊었다 — 사용자 실패가 아니라
                // 엔진이 물러난 것이므로 에러 배너·알림을 띄우지 않는다.
                // `LoginFlowController.run()`의 `defer { cleanup() }`이 이미 PTY 프로세스·
                // 인증창·임시파일을 정리했다(타임아웃/사용자취소와 같은 경로). 드물게 CLI가
                // 우리가 감지하기 전에 이미 로그인을 끝냈다면, 그 계정은 미등록인 채 라이브에만
                // 남는다 — `stopEngine()` 문서에 적었듯 다음 `tick()`의
                // `adoptLiveAccountIfUnregistered()`가 엔진 재개 시 자동으로 흡수한다.
            } catch {
                let message = l.accountsErrorMessage(error)
                lastError = message
                // 팝오버가 닫혀 있어도 인지할 수 있도록 알림으로도 전달
                notify(title: l.accountsNotifyAddFailedTitle, body: message)
            }
            loginFlow = nil
        }
    }

    // MARK: Desktop 연결 — 가이드형 자동 캡처

    struct DesktopCaptureSession: Identifiable, Equatable {
        enum Step: Equatable {
            case launching      // Desktop 실행 중
            case waitingLogin   // 사용자 로그인 대기 (변경 감시)
            case saving         // 스냅샷 저장 중
            case done
            case failed(String)
        }
        let accountID: UUID
        let nickname: String
        var step: Step = .launching
        var id: UUID { accountID }
    }

    @Published var desktopCapture: DesktopCaptureSession?
    private var desktopCaptureTask: Task<Void, Never>?
    /// 강제 로그아웃으로 치워둔 원래 세션 — 취소 시 복원용
    private var desktopCaptureStash: URL?

    /// 카드 "Desktop 연결": 현재 Desktop을 강제 로그아웃(세션 치우기)한 뒤 다시 띄워
    /// 사용자가 **해당 계정으로 새로 로그인**하게 하고, 그 세션을 캡처한다.
    /// 강제 로그아웃 덕에 다른 계정이 잘못 저장될 여지가 원천 차단된다.
    func beginDesktopCapture(for id: UUID) {
        guard desktopCapture == nil else { return } // 진행 중이면 중복 방지
        guard let profile = store.file.accounts.first(where: { $0.id == id }) else { return }
        // 안전 가드: Desktop 캡처는 현재 활성 계정의 세션을 잡으므로, 활성 계정에서만 허용한다.
        guard id == store.file.activeAccountID else {
            lastError = l.accountsErrorDesktopNeedsActive
            return
        }
        guard desktopSwitcher.isDesktopInstalled else {
            lastError = l.accountsErrorDesktopNotInstalled
            return
        }
        desktopCapture = DesktopCaptureSession(accountID: id, nickname: profile.nickname)
        desktopCaptureTask = Task { @MainActor [weak self] in
            await self?.runDesktopCaptureWatch(for: id)
        }
    }

    /// `endDesktopCapture()` 의 복원 태스크(종료→stash 복원→재실행) — 부류 스윕 대상 필드.
    /// **일부러 취소하지 않는다**(아래 `deliberatelyNotCancelled` 참조): 시작 시점에
    /// `desktopCaptureStash` 를 이미 nil 로 비웠으므로, 이 태스크 자체가 그 스택을 되돌릴
    /// 유일한 경로다 — 끊으면 Desktop 이 로그아웃된 채 남고 되돌릴 방법이 없어진다.
    private var desktopCaptureRestoreTask: Task<Void, Never>?

    /// 시트 닫기/취소 — 감시 태스크 정리 + 강제 로그아웃했던 원래 세션 복원.
    func endDesktopCapture() {
        desktopCaptureTask?.cancel()
        desktopCaptureTask = nil
        desktopCapture = nil
        guard let stash = desktopCaptureStash else { return }
        desktopCaptureStash = nil
        // 취소: 치워둔 원래 Desktop 로그인을 되돌린다 (종료 → 복원 → 재실행)
        desktopCaptureRestoreTask = Task { @MainActor in
            defer { desktopCaptureRestoreTask = nil }
            await desktopCoordinator.terminateAndWait()
            try? desktopSwitcher.restoreStashedIdentity(from: stash)
            if await !desktopCoordinator.launch() {
                lastError = l.accountsErrorDesktopRelaunchManual
            }
        }
    }

    private func runDesktopCaptureWatch(for id: UUID) async {
        // 1. Desktop 종료 → 현재 세션 치우기(강제 로그아웃) → 재실행(로그인 화면)
        await desktopCoordinator.terminateAndWait()
        guard !Task.isCancelled, desktopCapture?.accountID == id else { return }
        do {
            desktopCaptureStash = try desktopSwitcher.stashLiveIdentity()
        } catch {
            desktopCapture?.step = .failed(l.accountsErrorDesktopLogoutFailed(error.localizedDescription))
            return
        }
        if await !desktopCoordinator.launch() {
            desktopCapture?.step = .failed(
                l.accountsErrorDesktopRelaunchRetry)
            return
        }
        guard !Task.isCancelled, desktopCapture?.accountID == id else { return }
        desktopCapture?.step = .waitingLogin

        // 자동 감지 — **로그아웃 확인 → 새 로그인** 전이일 때만 저장한다.
        //  ① 먼저 실제로 로그아웃됐는지 확인(hasLiveLogin==false). 재실행 직후에도 계속 로그인
        //     상태면 강제 로그아웃이 실패한 것 → 이전 계정을 잘못 캡처하지 않도록 에러 처리.
        //  ② 로그아웃 확인 후, 로그인 토큰이 새로 생기면(사용자가 로그인) 1.5초 안정화 뒤 저장.
        var confirmedLoggedOut = false
        let stillLoggedInSince = Date()
        var loginSeenAt: Date?
        let deadline = Date().addingTimeInterval(300)
        while Date() < deadline {
            do { try await Task.sleep(for: .seconds(1)) } catch { return } // 취소됨
            guard desktopCapture?.accountID == id else { return }
            let loggedIn = desktopSwitcher.hasLiveLogin()

            if !confirmedLoggedOut {
                if loggedIn {
                    // 재실행했는데도 로그아웃이 안 됨 — 6초까지 기다려보고 계속이면 실패 판정.
                    if Date().timeIntervalSince(stillLoggedInSince) >= 6 {
                        desktopCapture?.step = .failed(
                            l.accountsErrorDesktopLogoutStuck)
                        return
                    }
                } else {
                    confirmedLoggedOut = true // 로그아웃 확인됨 — 이제 새 로그인을 기다린다
                }
                continue
            }

            // 로그아웃 확인 후 단계: 새 로그인 감지
            guard loggedIn else { loginSeenAt = nil; continue }
            if loginSeenAt == nil { loginSeenAt = Date() }
            else if Date().timeIntervalSince(loginSeenAt!) >= 1.5 { // 토큰 기록 완료 대기
                desktopCaptureTask = nil
                finishDesktopCapture(for: id)
                return
            }
        }
        desktopCapture?.step = .failed(l.accountsErrorDesktopLoginTimeout)
    }

    private func finishDesktopCapture(for id: UUID) {
        // 로그인 전(신원 파일 없음)에 저장을 누른 경우 빈 세션을 캡처하지 않도록 막는다.
        guard desktopSwitcher.identityLastModified() != nil else {
            desktopCapture?.step = .failed(
                l.accountsErrorDesktopLoginNotDetected)
            return
        }
        desktopCapture?.step = .saving
        do {
            try desktopSwitcher.capture(for: id)
            try store.update(id) { $0.hasDesktopSnapshot = true }
            if let stash = desktopCaptureStash { desktopSwitcher.discardStash(stash) }
            desktopCaptureStash = nil
            MobiusNotification.postAccountsChanged()
            reload()
            desktopCapture?.step = .done
            let name = store.file.accounts.first { $0.id == id }?.nickname ?? "?"
            notify(title: l.accountsNotifyDesktopSnapshotSavedTitle,
                   body: l.accountsNotifyDesktopSnapshotSavedBody(name))
        } catch {
            desktopCapture?.step = .failed(l.accountsErrorDesktopSaveFailed(error.localizedDescription))
        }
    }

    /// 계정 전환 알림(`.app` 번들일 때만). 번들이 아니면 `UNUserNotificationCenter.current()`가
    /// 예외를 던져 프로세스를 죽이므로, 호스트 앱의 `notifyCompanionEvent`와 같은 게이트를 쓴다.
    /// 22개 호출부가 전부 여기로 모이므로 가드는 이 한 곳이면 된다.
    /// `private`이 아닌 이유: 회귀 테스트가 **진짜 트리거를 밟아야** 하는데(가드 유무를 단언하는
    /// 테스트는 가드를 지워도 초록일 수 있다) `@testable import`는 `internal`까지만 닿는다.
    func notify(title: String, body: String) {
        guard AppEnv.isBundledApp else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }
}
