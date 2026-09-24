<div align="center">

<img src="assets/icon.png" width="128" alt="PokeTokenBar Extended 아이콘">

# PokeTokenBar Extended

**[PokeTokenBar](https://github.com/chattymin/PokeTokenBar) 포크 + [Mobius](https://github.com/chussum/mobius) 계정 자동 전환 통합.**

[![macOS](https://img.shields.io/badge/macOS-14%2B-0969da)](https://www.apple.com/macos/)
[![Swift](https://img.shields.io/badge/Swift-6-f05138)](https://swift.org)
[![License](https://img.shields.io/badge/license-MIT-3fb950)](LICENSE)

[English](README.md) · **한국어** · [日本語](README.ja.md)

</div>

이 저장소는 AI 코딩 토큰 사용량을 자라나는 포켓몬 companion으로 바꿔주는 메뉴바 앱
**[PokeTokenBar](https://github.com/chattymin/PokeTokenBar)** 를 개인적으로 포크해,
**[Mobius](https://github.com/chussum/mobius)** 의 Claude/Codex **계정 자동 전환** 엔진을
합친 것입니다. PokeTokenBar 의 기존 기능(사용량 추적, companion, 진화, 도감, 상점)은
전부 그대로이고, 이 포크는 활성 계정이 한도에 걸리면 자동으로 다른 계정으로 전환해 주는
**계정(Accounts)** 탭을 새로 더합니다.

범용 배포를 목표로 한 프로젝트가 아니라 개인의 멀티 계정 환경을 위해 만든 것이고, 다시
빌드하고 갱신하기 쉽도록 여기 공개해 둔 것입니다. 통합 설계 전체는
[docs/reference/mobius-integration.md](docs/reference/mobius-integration.md) 를 보세요
(이 문서는 한국어입니다).

> 토큰 사용량은 여전히 로컬 Claude Code·Codex·Gemini CLI·Antigravity·OpenCode·Hermes
> Agent·Cursor·Grok CLI·Copilot CLI·Kiro CLI·Pi Agent·omp 데이터에서 직접 읽습니다 — 외부
> CLI 불필요. 비공식·비상업 포켓몬 팬 프로젝트 — [라이선스 & 면책](#라이선스--면책) 참고.

## 상류(upstream) 프로젝트

| 프로젝트 | 이 저장소에 기여한 것 |
|---|---|
| [chattymin/PokeTokenBar](https://github.com/chattymin/PokeTokenBar) | 앱 전체: 사용량 추적, 포켓몬 companion, 도감, 상점 — 아래 "그 외 기능" 전부 |
| [chussum/mobius](https://github.com/chussum/mobius) | 새 **계정(Accounts)** 탭 뒤에 있는 계정 자동 전환 엔진(`MobiusCore`) |

원본 앱만 필요하다면 상류 저장소를 쓰세요 — 활발히 유지보수되고 Homebrew cask 도 있습니다.
이 포크는 오로지 그 위에 계정 전환을 얹기 위해서만 존재합니다.

## PokeTokenBar 가 하는 일

PokeTokenBar 는 당신이 이미 태우고 있는 AI 코딩 토큰(Claude Code · Codex · Gemini CLI ·
Antigravity · OpenCode · Hermes Agent · Cursor · Grok CLI · Copilot CLI · Kiro CLI ·
Pi Agent · omp)을 macOS 메뉴바 속 자라나는 **포켓몬 companion** 으로 바꿔줍니다. 토큰을
쓰면 알이 부화하고, 실제 진화 라인을 따라 진화하며, 최종 진화 후 도감에 졸업하고, 다시
새 알이 시작됩니다. companion 아래에는 정확한 사용량 트래커가 있습니다 — 오늘의
사용량·비용, 공식 5시간/주간 한도를 로컬 로그에서 직접 읽습니다.

<div align="center">
<img src="assets/screenshot-home.gif" width="420" alt="팝오버 홈 — companion, 오늘 토큰, 공식 한도">
</div>

1. 🥚 **평소처럼 코딩하세요.** 태우는 토큰이 알을 품습니다 — 따로 돌릴 건 없어요.
2. 🐣 **부화.** 알은 [PokéAPI](https://pokeapi.co/) 의 실제 진화 라인을 가진 포켓몬으로
   부화하며, 공식 포획률로 가중됩니다. 부화마다 25가지 성격 중 하나가 정해지고, 아주
   가끔 **✨ 이로치**로 부화합니다.
3. ⚡ **진화.** 계속 코딩하면 실제 진화 트리를 따라 자랍니다.
4. 🎓 **졸업 & 수집.** 최종 진화 + 임계치에 도달하면 **도감**에 영구 보관되고, 새 알이
   도착합니다.
5. 🍬 **한도를 채우면 사탕.** 5시간 또는 주간 사용 한도를 채우면 **이상한 사탕**을
   받습니다 — **가방**에서 써서 현재 포켓몬을 키우세요.
6. 🛒 **상점에서 소비.** 지금까지 쓴 토큰이 곧 화폐입니다. 이상한 사탕, 성격을 다시
   굴리는 박하사탕, 이로치 확률을 영구히 올리는 이로치 부적, 새 알(3등급)을 살 수 있어요.

## 이 포크가 더하는 것 — 계정(Accounts) 탭

새 **계정** 탭(기존 팝오버 탭 옆)에서 여러 Claude Code·Codex 계정을 등록하고:

- 각 계정의 사용량/한도 게이지를 보고 클릭 한 번으로 수동 전환합니다.
- **자동 전환**을 켜면, 활성 계정이 한도에 도달했을 때 앱이 자격증명을 건강한 폴백
  계정으로 조용히 바꾸고, 원래 계정이 회복되면 다시 되돌립니다. 한도 도달은 CLI 의
  한도 에러와 usage API **양쪽**으로 감지하므로, CLI 가 아닌 곳에서 사용량을 태웠거나
  막힌 뒤 입력을 멈춰도 전환이 일어납니다.
- 선택적으로 **미리 전환**(advisory switching)을 쓸 수 있습니다 — 설정 가능한 임계치에서
  한도에 도달하기 *전에* 폴백으로 미리 넘어갑니다. 기본은 꺼짐이고 위 동작과 독립입니다 —
  이걸 켜지 않아도 100% 소진 시 자동 전환은 동작합니다.

★ **자동 전환은 같은 프로바이더 풀 안에서만 동작합니다.** Claude 계정은 다른 Claude
계정으로만, Codex 계정은 다른 Codex 계정으로만 자동 전환됩니다 — 프로바이더를 넘나드는
전환(Claude 계정이 Codex 계정으로 넘어가는 식)은 없습니다. 각 프로바이더는 완전히
독립된 풀을 유지합니다.

자격증명 처리 방식은 Mobius 상류와 동일합니다: Claude 토큰은 시스템 Keychain +
`~/.claude.json`/`~/.claude/.credentials.json` 에, Codex 토큰은 `~/.codex/auth.json` 에
있고, 전환은 관련 파일/항목을 원자적으로 스왑합니다. 자격증명 모델·안전 불변식·알려진
트레이드오프의 전체 내용은
[docs/reference/mobius-integration.md](docs/reference/mobius-integration.md) 를
보세요 — 이 README 에서는 반복하지 않습니다.

## 설치

### 다운로드 (권장)

**[⬇️ PokeTokenBarExtended.dmg 다운로드](https://github.com/sun007021/PokeTokenBar/releases/latest/download/PokeTokenBarExtended.dmg)**
— 항상 최신 릴리스 · macOS 14+ · Apple silicon

1. 위 링크에서 DMG 를 받습니다 (이전 버전은
   [Releases 페이지](https://github.com/sun007021/PokeTokenBar/releases)에 있습니다).
2. DMG 를 열고 `PokeTokenBarExtended.app` 을 **Applications** 바로가기로 드래그합니다.
   반드시 `/Applications` 에 두세요 — 로그인 시 실행과 크래시 후 자동 재실행이 그 경로를
   가리킵니다.
3. 응용 프로그램 폴더(또는 Spotlight)에서 실행합니다. 메뉴바 앱이라 Dock 이 아니라
   **메뉴바**에 아이콘이 나타납니다.

앱은 Developer ID 인증서로 서명되고 **Apple 공증(notarization)** 을 받았으므로 Gatekeeper
경고 없이 열립니다. 계정 탭이 Claude Code 로그인 정보를 처음 읽을 때 macOS 가 Keychain 접근을
물을 수 있습니다 — **항상 허용**을 누르세요.

**업데이트:** 새 버전이 나오면 앱에 업데이트 배너가 뜹니다. 새 DMG 를 받아 `/Applications` 의
앱을 교체하면 됩니다. 포켓몬·도감·계정 데이터는
`~/Library/Application Support/PokeTokenBarExtended/` 에 있어 그대로 유지됩니다.

### 소스에서 빌드

```bash
swift build          # 디버그
swift test            # 유닛 테스트
./scripts/build-app.sh   # 릴리스 빌드 → PokeTokenBarExtended.app → /Applications
```

`build-app.sh` 는 리빌드해도 Keychain "항상 허용" 이 유지되도록 서명합니다. 인증서가
없으면 자동으로 ad-hoc 서명으로 내려갑니다(로컬 사용엔 문제없지만, 리빌드마다 코드 정체성이
바뀌어 macOS 가 Keychain 접근을 매번 다시 물을 수 있습니다). 본인 소유의 Developer ID(또는
자체 서명) 인증서가 있다면:

```bash
CODESIGN_IDENTITY="Developer ID Application: 이름 (팀ID)" \
  PTB_REQUIRE_STABLE_SIGN=1 ./scripts/build-app.sh
```

`PTB_REQUIRE_STABLE_SIGN=1` 을 주면 인증서를 못 찾았을 때 조용히 ad-hoc 으로 내려가는 대신
바로 실패합니다 — 인증서 이름 오타를 잡는 데 유용합니다.

참고: `./scripts/build-app.sh` 는 마지막에 실행 중인 인스턴스를 종료하고 곧바로
`/Applications` 에 설치합니다 — 개인적인 빌드/갱신 루틴이라면 자연스럽지만, 그걸 원치
않는 머신에서 돌리기 전에 알아두면 좋습니다.

## 데이터 소스

상류 PokeTokenBar 와 동일하고, 이 포크가 더하는 자격증명/계정 소스 둘이 추가됩니다:

| 소스 | 용도 |
|---|---|
| `~/.claude/projects/**/*.jsonl`, `~/.codex/sessions/**/*.jsonl` 등 상류가 읽는 도구별 로그 | 사용량 추적(오늘/블록/주간/월간) — 상류와 동일, 전체 도구 목록은 [상류의 Data sources 표](https://github.com/chattymin/PokeTokenBar#data-sources) 참고 |
| Keychain `Claude Code-credentials`, `~/.claude.json`, `~/.claude/.credentials.json` | 계정 탭용 Claude 계정 신원/토큰(계정 추가 또는 전환이 일어날 때만 읽고 씀) |
| `~/.codex/auth.json` | 계정 탭용 Codex 계정 신원/토큰 |
| [PokéAPI](https://pokeapi.co/) / `raw.githubusercontent.com/PokeAPI/sprites` | 포켓몬 종·능력치·진화·스프라이트 — 런타임에 받아 로컬에 캐시, 번들에 포함 안 됨 |

## 데이터 위치

이 포크는 `~/Library/Application Support/PokeTokenBarExtended/` 아래에 자기 데이터를
둡니다. Mobius 계정 데이터는 `mobius/` 하위 디렉터리에 격리돼 있어 도감·companion
세이브와 절대 충돌하지 않습니다.

이 포크는 자기 번들 ID(`io.github.sun007021.poketokenbarextended`)를 쓰므로 상류를
덮어쓰지 않고 나란히 설치됩니다. 첫 실행에 기존 데이터를 그대로 들고 옵니다 —
Application Support 디렉터리는 옛 이름에서 이름변경되고, 옛 번들 ID 도메인에 저장된
설정은 새 도메인으로 1회 복사됩니다. 지우는 것은 없습니다(구 `UserDefaults` 도메인은
그대로 남습니다). 이전 세부와 **넘어오지 않는 것**은
[docs/reference/mobius-integration.md](docs/reference/mobius-integration.md) 를 보세요.

## 상류 업데이트 가져오기

상류 PokeTokenBar 의 변경은 필요한 것만 골라(merge 또는 cherry-pick) 가져옵니다 — 상류
릴리스를 설치해 이 앱을 갱신하지 않습니다(그건 다른 앱입니다). PokeTokenBar Extended 는
상류와 별개로 **1.0.0** 부터 버전을 매기며, 업데이트 배너는 이 저장소의 릴리스만 봅니다.
절차와 세부 사항은 [docs/reference/mobius-integration.md](docs/reference/mobius-integration.md)
를 보세요.

## 라이선스 & 면책

**MIT** — [LICENSE](LICENSE) 와, 이 포크가 그대로 승계한 상류 고지 원문은
[THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md) 를 보세요(PokeTokenBar·Mobius 모두
MIT, 이 포크 자신의 수정분도 MIT). MIT 라이선스는 이 프로젝트의 소스 코드에만
적용되며, 앱이 접근하는 제3자 상표·아트워크·데이터에는 어떤 권리도 부여하지 않습니다.

PokeTokenBar(와 이 포크)는 **비공식·비상업 팬 프로젝트**입니다. **Nintendo, Game Freak,
Creatures Inc., The Pokémon Company 와 무관하며 그들의 승인·후원을 받지 않았습니다.**
"포켓몬"과 관련된 모든 이름·캐릭터·이미지는 각 소유자의 상표이자 저작물입니다. 이
프로젝트는 어떤 포켓몬 지적재산에 대해서도 소유권이나 권리를 주장하지 않습니다.

- **앱 바이너리와 릴리스 산출물에는 포켓몬 에셋이 포함되지 않습니다.** 포켓몬 종 데이터와
  스프라이트는 공개 [PokéAPI](https://pokeapi.co) 에서 **런타임에** 받아 사용자 자신의
  기기에만 로컬 캐시되며, PokéAPI 를 통해 제공되는 스프라이트 이미지는 각 소유자의
  재산으로 남습니다.
- 이 저장소 문서(스크린샷/GIF)에 등장하는 포켓몬 이미지는 오직 앱 기능을 설명하기 위해
  실려 있습니다.
- 이 앱은 **개인적·비상업적 용도**로만 무료로 제공됩니다.
- 이 프로젝트에 우려가 있는 권리자는 이슈를 열어 주시면 신속히 대응하겠습니다.

*"있는 그대로" 제공되며 어떤 종류의 보증도 하지 않습니다. 이 고지는 법률 자문이
아닙니다.*
