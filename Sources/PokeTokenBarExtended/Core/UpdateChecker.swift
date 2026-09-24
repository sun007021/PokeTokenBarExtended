import AppKit
import Observation

/// GitHub 릴리스 최신 버전을 확인해 새 버전이 있으면 팝오버에 알린다.
/// 실제 설치는 brew 사용자면 `brew upgrade`, 그 외엔 릴리스 페이지 열기(저위험·인프라 0).
@MainActor
@Observable
final class UpdateChecker {
    struct Available: Equatable { let version: String; let url: String }

    private(set) var available: Available?
    private(set) var isUpdating = false

    let currentVersion: String
    /// 이 앱의 릴리스 저장소. PokeTokenBar Extended 는 상류(chattymin/PokeTokenBar)와 별개로
    /// 1.0.0 부터 버전을 매기므로(2026-09-15) 상류를 보면 2.x 가 늘 "새 버전"이 되어 배너가
    /// 상시로 뜬다 — 반드시 이 저장소를 본다.
    ///
    /// ★ 개명(2026-09-24): `sun007021/PokeTokenBar` → `…Extended`. GitHub 리다이렉트가 옛
    ///   이름을 아직 받아주지만 **의존하지 않는다** — 리다이렉트는 누군가 옛 이름으로 새
    ///   저장소를 만드는 순간 끊기고, 그때 이 상수는 **남의 저장소의 릴리스를 사용자에게
    ///   업데이트로 제시한다**(응답의 `html_url` 을 그대로 NSWorkspace.open 에 넘긴다 —
    ///   host 검사는 github.com 여부만 보므로 이 오염을 못 막는다).
    nonisolated static let releaseRepo = "sun007021/PokeTokenBarExtended"
    private let repo = UpdateChecker.releaseRepo
    private let clock: () -> Date
    private var lastChecked: Date?

    init(currentVersion: String? = nil, clock: @escaping () -> Date = Date.init) {
        self.currentVersion = currentVersion
            ?? (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "0"
        self.clock = clock
    }

    /// 최신 릴리스 조회 → 새 버전이고 사용자가 그 버전을 'skip' 하지 않았으면 available 설정.
    /// minInterval 보다 자주 호출되면 무시(레이트리밋 보호).
    func check(minInterval: TimeInterval = 1800) async {
        if let last = lastChecked, clock().timeIntervalSince(last) < minInterval { return }
        lastChecked = clock()
        guard let url = URL(string: "https://api.github.com/repos/\(repo)/releases/latest") else { return }
        var req = URLRequest(url: url, timeoutInterval: 15)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = json["tag_name"] as? String,
              let html = json["html_url"] as? String,
              // 응답 필드가 NSWorkspace.open 으로 가므로 https + github.com 만 허용(스킴 하이재킹 방지)
              let htmlURL = URL(string: html), htmlURL.scheme == "https", htmlURL.host == "github.com"
        else { return }
        let latest = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
        let skipped = UserDefaults.standard.string(forKey: "skippedUpdateVersion")
        if Self.isNewer(latest, than: currentVersion), latest != skipped {
            available = Available(version: latest, url: html)
        } else {
            available = nil
        }
    }

    /// 이 버전은 다시 알리지 않음.
    func skipCurrent() {
        if let v = available?.version { UserDefaults.standard.set(v, forKey: "skippedUpdateVersion") }
        available = nil
    }

    /// 이 앱은 **상류 cask 업그레이드 경로를 타지 않는다.**
    /// `brew upgrade --cask poke-token-bar` 는 확인창 하나 없이 앱을 종료하고 **상류 앱**을
    /// 설치한다 — 이 앱(PokeTokenBar Extended)의 갱신 수단이 아니다. cask 가 한 번이라도
    /// 설치돼 있으면 `brewCaskPath()` 가 그 경로를 되살리므로 코드에서 닫는다.
    /// 업데이트 알림은 이 앱의 저장소(`releaseRepo`) 릴리스만 받고, 적용은 릴리스 페이지를 여는
    /// 것으로 끝난다(사용자가 DMG 를 받아 교체). 이 한 줄이 결정 지점이다 — 지우면 cask 경로가
    /// 돌아온다.
    nonisolated static let allowsBrewCaskUpgrade = false

    /// 업데이트 적용: brew cask 설치본이면 `brew upgrade` 후 재시작, 아니면 릴리스 페이지.
    func applyUpdate() {
        guard let update = available, !isUpdating else { return }
        isUpdating = true
        Task { @MainActor in
            // brew cask 설치본이면 분리(detached) 스크립트가 앱 종료 후 tap 갱신→업그레이드→재오픈.
            // 그 외(brew 미설치/비-cask 설치)면 릴리스 페이지를 연다.
            let brew = Self.allowsBrewCaskUpgrade
                ? await Task.detached { Self.brewCaskPath() }.value
                : nil
            if let brew {
                Self.launchDetachedUpgrade(brew: brew)
                NSApp.terminate(nil)
            } else {
                isUpdating = false
                AppLog.write(
                    "update: cask 업그레이드 비활성(포크)/brew cask 아님 → 릴리스 페이지 열기")
                if let u = URL(string: update.url) { NSWorkspace.shared.open(u) }
            }
        }
    }

    // MARK: 버전 비교

    /// a 가 b 보다 높은 semver 인가. ("2.0.10" > "2.0.9" 등 숫자 비교)
    nonisolated static func isNewer(_ a: String, than b: String) -> Bool {
        let pa = precedenceParts(a)
        let pb = precedenceParts(b)
        for i in 0..<max(pa.count, pb.count) {
            let x = i < pa.count ? pa[i] : 0
            let y = i < pb.count ? pb[i] : 0
            if x != y { return x > y }
        }
        return false
    }

    /// 버전에서 **우선순위 비교에 쓰이는 숫자 세그먼트만** 뽑는다 — semver 가 우선순위에서
    /// 제외하는 빌드 메타데이터(`+…`)와 프리릴리스(`-…`)를 먼저 잘라낸다.
    ///
    /// 그냥 `.` 으로 쪼개면 `"0+local"` 같은 세그먼트가 `Int()` 실패로 0 이 되어, 로컬 빌드
    /// 표기가 붙은 버전이 같은 릴리스보다 낮거나 높게 판정된다.
    ///
    /// 프리릴리스를 함께 버리는 것은 이 자리에선 안전한 방향이다: 같은 숫자의 `-rc1` 은
    /// "새 버전 아님"이 되고(semver 도 `2.5.3-rc1 < 2.5.3`), GitHub `releases/latest` 는
    /// 애초에 프리릴리스를 제외한다.
    private nonisolated static func precedenceParts(_ version: String) -> [Int] {
        version.prefix { $0 != "+" && $0 != "-" }
            .split(separator: ".").map { Int($0) ?? 0 }
    }

    // MARK: brew 적용 (nonisolated — 블로킹 Process 는 detached 에서)

    /// poke-token-bar 가 brew cask 로 설치돼 있으면 brew 경로 반환, 아니면 nil(→ 릴리스 페이지 폴백).
    private nonisolated static func brewCaskPath() -> String? {
        guard let brew = BinaryLocator.resolve("brew", staticPaths: [
            "/opt/homebrew/bin/brew", "/usr/local/bin/brew",
        ]) else { return nil }
        return run(brew, ["list", "--cask", "poke-token-bar"], timeout: 20) ? brew : nil
    }

    private nonisolated static func run(_ binary: String, _ args: [String], timeout: TimeInterval) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: binary)
        process.arguments = args
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return false }
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.1) }
        if process.isRunning { process.terminate(); return false }
        return process.terminationStatus == 0
    }

    /// 앱이 완전히 종료된 뒤 tap 갱신 + cask 업그레이드 + 재오픈을 수행하는 분리(detached) 스크립트 본문.
    /// - `brew update` 선행: auto-update 빈도 제한(기본 24h)으로 stale 한 로컬 tap 때문에 `brew upgrade`
    ///   가 no-op(exit 0) 되어 "업데이트 안 됨 + 앱만 종료"가 나던 문제를 막는다.
    /// - 앱 종료를 기다림(`kill -0 $3`): 실행 중 번들 교체 레이스 + 재오픈 LaunchServices(-600) 레이스 회피.
    ///   `pgrep -x` 대신 특정 PID를 감시하여 중복 인스턴스가 실행 중일 때도 20s 타임아웃 없이 즉시 진행 (#175).
    /// - brew 를 백그라운드+워치독(≤300s)으로 감싸 hang 시에도 reopen 이 반드시 실행되게 함
    ///   (앱이 종료된 채 영영 안 돌아오는 것 방지). 종료 직후 재오픈 실패 대비 `open` 재시도.
    /// 인자는 positional($1=brew, $2=bundlePath, $3=pid)로 전달 — 셸 인젝션 차단.
    nonisolated static let detachedUpgradeScript = """
    for i in $(seq 1 40); do kill -0 "$3" 2>/dev/null || break; sleep 0.5; done
    export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:$PATH"
    ( "$1" update; "$1" upgrade --cask poke-token-bar ) &
    brew_pid=$!
    for i in $(seq 1 300); do kill -0 "$brew_pid" 2>/dev/null || break; sleep 1; done
    kill "$brew_pid" 2>/dev/null
    for i in $(seq 1 15); do
      launchctl kickstart -k "gui/$(id -u)/io.github.sun007021.poketokenbarextended.login" 2>/dev/null && break
      open "$2" 2>/dev/null && break
      sleep 1
    done
    """

    nonisolated static func launchDetachedUpgrade(
        brew: String,
        pid: pid_t = ProcessInfo.processInfo.processIdentifier,
        bundlePath: String = Bundle.main.bundlePath
    ) {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = ["-c", detachedUpgradeScript, "sh", brew, bundlePath, String(pid)]
        try? task.run()
    }
}
