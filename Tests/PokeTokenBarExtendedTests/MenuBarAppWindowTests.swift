import AppKit
import SwiftUI
import XCTest
@testable import PokeTokenBarExtended

/// 메뉴바 전용 앱이 **창을 띄우지 않는다**는 계약 (2026-09-25 결함).
///
/// 증상: 새 버전을 설치하고 `/Applications` 에서 앱을 더블클릭하면 **빈 검은 창**("PokeTokenBar
/// Extended Settings")이 떴다. 닫기 전에는 계속 남는다.
///
/// 원인: `App` 은 Scene 을 최소 하나 요구하는데 이 앱의 유일한 Scene 은 `Settings { EmptyView() }`
/// 다(메뉴바는 Scene 이 아니라 `NSStatusItem` 이 그린다). 앱은 LaunchAgent(KeepAlive)로 상시
/// 실행되므로 "앱을 연다"는 행위는 새 실행이 아니라 **reopen** 이고, 기본 reopen 처리는 창이
/// 없으면 첫 Scene 을 연다 — 그게 내용이 `EmptyView` 인 설정 창이다.
@MainActor
final class MenuBarAppWindowTests: XCTestCase {

    /// 트리거 브랜치: 보이는 창이 없는 상태의 reopen — 설치 직후 더블클릭이 정확히 이 경우다.
    func testReopenWithNoVisibleWindowsIsSwallowed() {
        let delegate = AppDelegate()
        XCTAssertFalse(
            delegate.applicationShouldHandleReopen(NSApplication.shared, hasVisibleWindows: false),
            """
            false 여야 기본 동작이 멈춘다. true 면 AppKit 이 "창이 없으니 첫 Scene 을 열자"로
            가서 Settings { EmptyView() } 를 띄운다 = 빈 검은 창.
            """)
    }

    /// 창이 이미 있는 경우도 같은 답이어야 한다 — 이 앱에는 사용자가 열 수 있는 창이 없고,
    /// 팝오버는 Scene 이 아니라 `NSPopover` 라 이 경로와 무관하다.
    func testReopenWithVisibleWindowsIsAlsoSwallowed() {
        let delegate = AppDelegate()
        XCTAssertFalse(delegate.applicationShouldHandleReopen(NSApplication.shared, hasVisibleWindows: true))
    }

    /// ★ 위 두 단언이 **무엇이든 통과시키는 장식**이 아닌지 — 기본 구현(메서드 없음)은
    ///   AppKit 이 "구현 안 됨 = true 취급"으로 가는 것이 이 결함의 본체였다. 그래서 델리게이트가
    ///   그 셀렉터에 실제로 응답하는지도 본다: 메서드를 지우면 이 단언이 먼저 깨진다.
    func testTheDelegateActuallyImplementsTheReopenSelector() {
        let delegate = AppDelegate()
        XCTAssertTrue(
            delegate.responds(to: #selector(NSApplicationDelegate.applicationShouldHandleReopen(_:hasVisibleWindows:))),
            "메서드가 없으면 AppKit 은 기본 동작(첫 Scene 열기)을 그대로 수행한다")
    }

    /// 앱이 **메뉴바 전용**이라는 전제 자체를 잠근다 — 누군가 `WindowGroup` 을 더하면 위
    /// 가드의 의미가 사라진다(그때는 reopen 을 삼키는 게 오히려 버그다).
    func testTheAppDeclaresNoUserFacingWindowScene() throws {
        let source = try MobiusTestSupport.sourceLines(
            of: "Sources/PokeTokenBarExtended/PokeTokenBarExtendedApp.swift")
        let code = source.filter { !MobiusTestSupport.isComment($0) }.joined(separator: "\n")
        XCTAssertFalse(code.contains("WindowGroup"),
                       "창을 여는 Scene 이 생겼다면 reopen 을 삼키는 가드를 다시 판단해야 한다")
        XCTAssertTrue(code.contains("Settings { EmptyView() }"),
                      "유일한 Scene 이 빈 Settings 라는 것이 이 가드가 존재하는 이유다")
        XCTAssertTrue(code.contains("setActivationPolicy(.accessory)"),
                      "accessory 가 아니면 Dock 아이콘이 생겨 reopen 경로가 더 자주 열린다")
    }
}
