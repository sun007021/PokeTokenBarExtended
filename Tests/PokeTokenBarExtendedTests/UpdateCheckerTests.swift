import XCTest
@testable import PokeTokenBarExtended

final class UpdateCheckerTests: XCTestCase {
    func testNewerPatch() {
        XCTAssertTrue(UpdateChecker.isNewer("2.0.2", than: "2.0.1"))
    }
    func testSameIsNotNewer() {
        XCTAssertFalse(UpdateChecker.isNewer("2.0.1", than: "2.0.1"))
    }
    func testOlderIsNotNewer() {
        XCTAssertFalse(UpdateChecker.isNewer("2.0.0", than: "2.0.1"))
        XCTAssertFalse(UpdateChecker.isNewer("2.0.9", than: "2.1.0"))
    }
    func testNumericNotLexical() {
        // "2.0.10" 은 "2.0.9" 보다 높다 (문자열 비교면 반대로 틀림)
        XCTAssertTrue(UpdateChecker.isNewer("2.0.10", than: "2.0.9"))
    }
    func testMinorAndMajor() {
        XCTAssertTrue(UpdateChecker.isNewer("2.1.0", than: "2.0.9"))
        XCTAssertTrue(UpdateChecker.isNewer("3.0.0", than: "2.9.9"))
    }
    func testDifferentComponentCounts() {
        XCTAssertTrue(UpdateChecker.isNewer("2.0.1", than: "2.0"))   // 2.0.1 > 2.0.0
        XCTAssertFalse(UpdateChecker.isNewer("2.0", than: "2.0.0"))  // 동일
    }

    // MARK: - Detached upgrade script wait loop (#175)

    // MARK: 독자 버전 (1.0.0 부터, 2026-09-15)

    /// 이 앱은 상류와 별개로 1.0.0 부터 버전을 매긴다. 배너가 상류 저장소를 보면 상류 2.x 가
    /// 늘 새 버전으로 판정돼 배너가 상시로 뜬다 — 그 전제(상류 2.x > 1.x)와, 그래서 조회
    /// 대상이 이 앱의 저장소여야 한다는 결론을 함께 잠근다.
    func testChecksThisAppsOwnReleasesBecauseUpstreamVersionsAlwaysLookNewer() {
        XCTAssertTrue(UpdateChecker.isNewer("2.5.4", than: "1.0.0"))
        XCTAssertEqual(UpdateChecker.releaseRepo, "sun007021/PokeTokenBarExtended")
    }

    /// semver 빌드 메타데이터(`+…`)는 우선순위에서 제외된다. `.` 으로 그냥 쪼개면
    /// `"0+local"` → 0 이 되어 판정이 흔들린다.
    func testBuildMetadataIsIgnoredWhenComparing() {
        XCTAssertFalse(UpdateChecker.isNewer("1.0.0", than: "1.0.0+local.1"))
        XCTAssertTrue(UpdateChecker.isNewer("1.0.1", than: "1.0.0+local.9"))
    }

    /// 프리릴리스 접미사도 같은 규칙으로 잘린다(semver §9 — 우선순위에서 제외).
    func testPreReleaseSuffixIsStrippedBeforeComparing() {
        XCTAssertFalse(UpdateChecker.isNewer("1.0.0-rc1", than: "1.0.0"))
        XCTAssertTrue(UpdateChecker.isNewer("1.0.1-rc1", than: "1.0.0"))
    }

    /// 상류 cask 업그레이드는 확인창 없이 앱을 종료하고 번들을 상류 빌드로 교체한다(같은 번들
    /// ID·같은 설치 경로) → 포크의 계정 전환 기능이 조용히 사라진다. 지금은 사용자가 cask 를
    /// 지워 경로가 죽어 있지만 재설치 한 번이면 되살아나므로, 코드에서 닫혀 있는지를 잠근다.
    func testForkNeverTakesTheBrewCaskUpgradePath() {
        XCTAssertFalse(
            UpdateChecker.allowsBrewCaskUpgrade,
            "a cask upgrade replaces this fork with the upstream build without confirmation"
        )
    }

    func testDetachedUpgradeScriptWaitsOnPidNotProcessName() {
        let script = UpdateChecker.detachedUpgradeScript
        XCTAssertFalse(
            script.contains("pgrep -x"),
            "pgrep -x matches any instance by name and always times out when a duplicate runs"
        )
        XCTAssertTrue(
            script.contains("kill -0 \"$3\""),
            "the wait loop must wait on the specific terminating PID via $3"
        )
    }

    func testDetachedUpgradeScriptUsesPositionalParameters() {
        let script = UpdateChecker.detachedUpgradeScript
        XCTAssertTrue(script.contains("\"$1\" update"), "must execute brew via $1 positional arg")
        XCTAssertTrue(script.contains("\"$1\" upgrade"), "must execute brew upgrade via $1 positional arg")
        XCTAssertTrue(script.contains("open \"$2\""), "must open bundlePath via $2 positional arg")
    }
}
