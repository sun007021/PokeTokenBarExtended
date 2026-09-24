import XCTest
@testable import MobiusCore
@testable import PokeTokenBarExtended

/// **로그 429 없이** usage API 만으로 소진을 기록하는 경로 (2026-09-16 결함).
///
/// 결함: 소진 기록을 만드는 경로가 세션 로그의 429 라인 하나뿐이었다. 5시간 창이 100%가 돼도
/// CLI 가 그 뒤로 요청을 보내지 않으면 — 막힌 사용자는 당연히 멈추고, 사용량을 Desktop·웹에서
/// 태웠으면 애초에 로그가 없다 — 기록이 없어 `AutoSwitchEngine.onTick` 이 자동 전환을 못 한다.
/// 앱은 그 사이 usage API 로 100% 를 **이미 보고 있었다**(실측: 계정 캐시에 five=100 저장,
/// 같은 시각 accounts.json 에 rateLimit 기록 없음).
///
/// 왜 기존 테스트가 못 걸렀나: `HitAttributionTests` 가 `verdict(usage: 100%) → .record` 를
/// 초록으로 증명하지만, 그 함수는 **로그 hit 트리거에서만** 도달 가능했다. 판정 규칙만 잠그고
/// 도달 경로를 안 잠그면 경로가 통째로 비어도 초록불이다 — 그래서 여기서는 `tick()` 을 돌려
/// **배선**을 잰다.
@MainActor
final class MobiusUsageExhaustionTests: XCTestCase {

    override func tearDown() {
        UsageFetcher.transportForTesting = nil
        super.tearDown()
    }

    // MARK: - 트리거 브랜치: usage 100% → 기록

    func testAnExhaustedFiveHourWindowIsRecordedWithoutAnyLogHit() async throws {
        let (state, active, _) = try makeTwoAccountPool()
        let resetsAt = Date().addingTimeInterval(2 * 3600)
        let calls = installTransport(fiveHourPercent: 100, resetsAt: resetsAt)

        await state.tick()

        XCTAssertGreaterThan(calls.value, 0, "5분 폴이 아예 안 돌았다 — 아래 단언이 무의미해진다")
        let recorded = try XCTUnwrap(
            state.store.file.accounts.first { $0.id == active }?.rateLimit,
            """
            usage 가 100% 라고 답했는데 소진 기록이 없다. 기록이 없으면 onTick 의 자동 전환도
            못 돌아, 로그에 429 가 안 찍히는 경우(Desktop·웹 사용, 막힌 뒤 타이핑 중단)엔
            자동 전환이 통째로 사라진다.
            """)
        XCTAssertFalse(recorded.modelScoped, "계정 창 소진을 모델 전용 한도로 기록하면 안 된다")
        XCTAssertEqual(recorded.resetsAt.timeIntervalSince1970, resetsAt.timeIntervalSince1970,
                       accuracy: 1,
                       "리셋 시각은 API 값 그대로여야 한다(로그 문구 파싱값보다 정확하다)")
        XCTAssertTrue(state.store.file.accounts.first { $0.id == active }!.isLimited(now: Date()),
                      "기록이 isLimited 로 읽히지 않으면 엔진이 이 계정을 떠나지 않는다")
    }

    /// ★ 결함 주입 — 위 테스트가 **무엇이든 통과시키는 장식**이 아닌지 확인한다.
    /// 같은 배선에 여유 있는 사용량을 먹이면 기록이 **없어야** 한다.
    func testAHealthyWindowRecordsNothing() async throws {
        let (state, active, _) = try makeTwoAccountPool()
        let calls = installTransport(fiveHourPercent: 40, resetsAt: Date().addingTimeInterval(3600))

        await state.tick()

        XCTAssertGreaterThan(calls.value, 0, "폴은 돌아야 한다 — 안 돌면 이 단언도 공짜로 통과한다")
        XCTAssertNil(state.store.file.accounts.first { $0.id == active }?.rateLimit,
                     "40% 를 소진으로 기록하면 멀쩡한 계정이 몇 시간 폴백에서 빠진다")
    }

    /// advisory(미리 전환)는 **기본 꺼짐**인 사용자 옵션이다. 소진 기록이 그 옵션에 묶여 있던
    /// 것이 이 결함의 본체였으므로, 꺼진 상태에서 도는지를 명시적으로 잠근다.
    func testTheExhaustionRecordDoesNotDependOnTheAdvisoryOption() async throws {
        let defaults = UserDefaults.standard
        let previous = defaults.object(forKey: MobiusFeature.advisorySwitchEnabledKey)
        defaults.set(false, forKey: MobiusFeature.advisorySwitchEnabledKey)
        defer {
            if let previous { defaults.set(previous, forKey: MobiusFeature.advisorySwitchEnabledKey) }
            else { defaults.removeObject(forKey: MobiusFeature.advisorySwitchEnabledKey) }
        }

        let (state, active, _) = try makeTwoAccountPool()
        installTransport(fiveHourPercent: 100, resetsAt: Date().addingTimeInterval(2 * 3600))

        await state.tick()

        XCTAssertNotNil(state.store.file.accounts.first { $0.id == active }?.rateLimit,
                        "미리 전환을 안 켠 사용자에게 자동 전환이 사라지는 것이 이 결함이다")
    }

    // MARK: - 폴 게이트: 전환할 곳이 없으면 돌지 않는다

    func testThePollGateNeedsBothAutoSwitchAndAFallback() {
        XCTAssertTrue(AccountsState.usagePollIsWorthwhile(autoSwitchEnabled: true,
                                                          claudeAccountCount: 2))
        XCTAssertFalse(AccountsState.usagePollIsWorthwhile(autoSwitchEnabled: false,
                                                           claudeAccountCount: 2),
                       "자동 전환을 끈 사용자에게 5분 네트워크 조회를 깔면 안 된다")
        XCTAssertFalse(AccountsState.usagePollIsWorthwhile(autoSwitchEnabled: true,
                                                           claudeAccountCount: 1),
                       "갈 곳이 없으면 소진을 기록해도 쓸 데가 없다")
    }

    /// 판정만 잠그면 호출부가 게이트를 무시해도 초록불이다 — 틱이 실제로 그 판정을 쓰는지.
    func testATickDoesNotPollWhenAutoSwitchIsOff() async throws {
        let (state, _, _) = try makeTwoAccountPool()
        try state.store.setAutoSwitch(false, provider: .claude)
        let calls = installTransport(fiveHourPercent: 100, resetsAt: Date().addingTimeInterval(3600))

        await state.tick()

        XCTAssertEqual(calls.value, 0, "자동 전환이 꺼져 있는데 배경 조회가 돌면 '끄면 아무것도 안 돈다'가 깨진다")
    }

    // MARK: - 헬퍼

    /// 활성 + 폴백 하나. 라이브(`~/.claude`)를 활성 계정으로 맞춰 둬야 틱의 5분 블록이
    /// `refreshActiveSnapshotIfStable()` 을 통과해 폴까지 내려간다.
    ///
    /// 스냅샷 blob 에 refresh 토큰을 **일부러 넣지 않는다** — 그래야 전환 직전 검증
    /// (`preflightFallback`)이 네트워크 없이 `.noRefreshToken` 으로 끝난다. 이 테스트가 재는
    /// 것은 "소진이 기록되는가"이지 실제 자격증명 스왑이 아니다.
    private func makeTwoAccountPool() throws -> (AccountsState, UUID, UUID) {
        let state = try MobiusTestSupport.isolatedAccountsState(
            cleanupWith: self, keychain: InMemoryKeychain())
        try FileManager.default.createDirectory(at: state.io.env.claudeDir,
                                                withIntermediateDirectories: true)
        let active = try state.store.upsertProfile(
            nickname: "active", snapshot: Self.snapshot(email: "a@x.com"))
        let fallback = try state.store.upsertProfile(
            nickname: "fallback", snapshot: Self.snapshot(email: "f@x.com"))
        try state.io.writeLiveSnapshot(Self.snapshot(email: "a@x.com"))
        try state.store.setActive(active.id)
        return (state, active.id, fallback.id)
    }

    /// usage 엔드포인트 응답을 실제 필드 이름(`five_hour`/`utilization`/`resets_at`)으로 만든다 —
    /// 파서가 읽는 그 모양이어야 배선을 재는 의미가 있다. 반환값은 호출 횟수 카운터.
    @discardableResult
    private func installTransport(fiveHourPercent: Int, resetsAt: Date) -> Counter {
        let counter = Counter()
        let iso = ISO8601DateFormatter()
        let body = Data("""
            {"five_hour":{"utilization":\(fiveHourPercent),"resets_at":"\(iso.string(from: resetsAt))"}}
            """.utf8)
        UsageFetcher.transportForTesting = { request in
            counter.bump()
            let response = HTTPURLResponse(url: request.url!, statusCode: 200,
                                           httpVersion: nil, headerFields: nil)!
            return (body, response)
        }
        return counter
    }

    /// transport 는 `@Sendable` 이라 호출 횟수를 락으로 감싼다.
    final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        func bump() { lock.lock(); count += 1; lock.unlock() }
        var value: Int { lock.lock(); defer { lock.unlock() }; return count }
    }

    private static func snapshot(email: String) -> CredentialsSnapshot {
        let blob = Data(#"{"claudeAiOauth":{"accessToken":"tok-\#(email)"}}"#.utf8)
        return CredentialsSnapshot(
            keychainBlob: blob, credentialsFileData: blob,
            oauthAccountJSON: Data(#"{"emailAddress":"\#(email)","organizationName":"O"}"#.utf8))
    }
}
