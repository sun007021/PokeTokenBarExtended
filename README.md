<div align="center">

<img src="assets/icon.png" width="128" alt="PokeTokenBar Extended icon">

# PokeTokenBar Extended

**A [PokeTokenBar](https://github.com/chattymin/PokeTokenBar) fork with [Mobius](https://github.com/chussum/mobius) account switching built in.**

[![macOS](https://img.shields.io/badge/macOS-14%2B-0969da)](https://www.apple.com/macos/)
[![Swift](https://img.shields.io/badge/Swift-6-f05138)](https://swift.org)
[![License](https://img.shields.io/badge/license-MIT-3fb950)](LICENSE)

**English** · [한국어](README.ko.md) · [日本語](README.ja.md)

</div>

This is a personal fork of **[PokeTokenBar](https://github.com/chattymin/PokeTokenBar)** —
the macOS menu-bar app that turns your AI coding token usage into a growing Pokémon
companion — with the Claude/Codex **account auto-switching** engine from
**[Mobius](https://github.com/chussum/mobius)** merged in. Everything PokeTokenBar already
does (usage tracking, the companion, evolutions, the Pokédex, the shop) is unchanged; this
fork adds an **Accounts** tab that switches between multiple Claude Code / Codex accounts
for you when the active one hits its rate limit.

It is not a general-purpose release — it's built for one person's own multi-account setup
and published here so it's easy to rebuild and update. See
[docs/reference/mobius-integration.md](docs/reference/mobius-integration.md) for the full
integration design if you want to understand or extend it.

> Token usage is still read directly from local Claude Code, Codex, Gemini CLI,
> Antigravity, OpenCode, Hermes Agent, Cursor, Grok CLI, Copilot CLI, Kiro CLI, Pi Agent,
> and omp data — no external CLI needed. Unofficial, non-commercial Pokémon fan project —
> see [License & disclaimer](#license--disclaimer).

## Upstream projects

| Project | What it contributes here |
|---|---|
| [chattymin/PokeTokenBar](https://github.com/chattymin/PokeTokenBar) | The whole menu-bar app: usage tracking, the Pokémon companion, Pokédex, shop, everything under **Also in the box** below |
| [chussum/mobius](https://github.com/chussum/mobius) | The account-switching engine (`MobiusCore`) behind the new **Accounts** tab |

If you just want the original app, use upstream — it's actively maintained and has a
Homebrew cask. This fork exists solely to add account switching on top of it.

## What PokeTokenBar does

PokeTokenBar turns the AI coding tokens you're already burning — Claude Code, Codex,
Gemini CLI, Antigravity, OpenCode, Hermes Agent, Cursor, Grok CLI, Copilot CLI, Kiro CLI,
Pi Agent & omp — into a growing **Pokémon companion** in your macOS menu bar. Spend
tokens, hatch an egg, evolve it through its real evolution line, graduate it into your
Pokédex, and start again. Underneath the companion it's a precise usage tracker — today's
spend, cost, and official 5-hour / weekly limits, read straight from your local logs.

<div align="center">
<img src="assets/screenshot-home.gif" width="420" alt="Popover home — companion, today's tokens, official limits">
</div>

1. 🥚 **Code as usual.** The tokens you burn incubate an egg — nothing extra to run.
2. 🐣 **Hatch.** Eggs hatch into Pokémon with real evolution lines from
   [PokéAPI](https://pokeapi.co/), weighted by the official capture rate. Every hatch
   rolls one of 25 natures, and once in a rare while, hatches **✨ Shiny**.
3. ⚡ **Evolve.** Keep coding and it grows through its actual evolution tree.
4. 🎓 **Graduate & collect.** Final form + threshold archives it in your **Pokédex**, and a
   fresh egg arrives.
5. 🍬 **Max out, get a candy.** Fill a 5-hour or weekly usage limit and earn **Rare Candy**
   — spend it from the **Bag** to grow your current Pokémon.
6. 🛒 **Spend at the Shop.** Every token you've used is spendable currency for Rare Candy,
   a nature-rerolling Mint, a shiny-odds Shiny Charm, or a new egg (three grades).

## What this fork adds — Accounts tab

The **Accounts** tab (new popover tab, next to the existing ones) lets you register
multiple Claude Code and/or Codex accounts and:

- See each account's usage/rate-limit gauge and switch to it manually with one click.
- Turn on **auto-switch**: when the active account's usage hits its limit, the app
  transparently swaps credentials to a healthy fallback account and swaps back once the
  original recovers. The limit is detected both from the CLI's own rate-limit errors and
  from the usage API, so a switch still happens when you burn the window somewhere other
  than the CLI — or when you simply stop typing after getting blocked.
- Optionally get **advisory switching** — move to a fallback *before* you hit the limit,
  at a configurable threshold. This is off by default and is independent of the above:
  auto-switch at 100% works whether or not you turn it on.

★ **Auto-switch only moves within the same provider's pool.** Claude accounts only
auto-switch to other Claude accounts, and Codex accounts only to other Codex accounts —
there is no cross-provider switching (a Claude account never fails over to a Codex
account, or vice versa). Each provider keeps its own independent pool.

Credentials are handled the same way Mobius does it upstream: Claude tokens live in the
system Keychain plus `~/.claude.json`/`~/.claude/.credentials.json`, Codex tokens live in
`~/.codex/auth.json`, and switching swaps all of the relevant files/entries atomically.
See [docs/reference/mobius-integration.md](docs/reference/mobius-integration.md) for the
credential model, safety invariants, and known trade-offs in detail — this README doesn't
duplicate that.

## Install

### Download (recommended)

**[⬇️ Download PokeTokenBarExtended.dmg](https://github.com/sun007021/PokeTokenBarExtended/releases/latest/download/PokeTokenBarExtended.dmg)**
— always the latest release · macOS 14+ · Apple silicon

1. Download the DMG from the link above (older versions are on the
   [Releases page](https://github.com/sun007021/PokeTokenBarExtended/releases)).
2. Open it and drag `PokeTokenBarExtended.app` onto the **Applications** shortcut.
   Keep it in `/Applications` — launch at login and automatic restart after a crash point
   there.
3. Open it from Applications (or Spotlight). It's a menu-bar app: look for its icon in the
   menu bar — there is no Dock icon.

The app is signed with a Developer ID certificate and **notarized by Apple**, so it opens
without Gatekeeper warnings. When the Accounts tab first reads your Claude Code login,
macOS may ask for Keychain access — choose **Always Allow**.

**Updating:** when a new version is released, the app shows an update banner. Download the
new DMG and replace the app in `/Applications`. Your companion, Pokédex, and accounts live
in `~/Library/Application Support/PokeTokenBarExtended/` and are kept.

### Build from source

```bash
swift build          # debug
swift test            # unit tests
./scripts/build-app.sh   # release build → PokeTokenBarExtended.app → /Applications
```

`build-app.sh` signs the app so Keychain "always allow" choices survive rebuilds. Without
a certificate it falls back to ad-hoc signing automatically (fine for local use, but every
rebuild gets a new code identity, so macOS may re-prompt for Keychain access each time). If
you have your own Developer ID (or self-signed) certificate:

```bash
CODESIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" \
  PTB_REQUIRE_STABLE_SIGN=1 ./scripts/build-app.sh
```

`PTB_REQUIRE_STABLE_SIGN=1` refuses to fall back to ad-hoc silently if the identity isn't
found — useful to catch a typo'd certificate name.

Note: `./scripts/build-app.sh` ends by killing any running instance and installing straight
to `/Applications` — expected for a personal build/update loop, but worth knowing before
you run it on a machine where you don't want that.

## Data sources

Same as upstream PokeTokenBar, plus the two new credential/account sources this fork adds:

| Source | Used for |
|---|---|
| `~/.claude/projects/**/*.jsonl`, `~/.codex/sessions/**/*.jsonl`, and the other per-tool logs upstream reads | Usage tracking (today/blocks/weekly/monthly) — unchanged from upstream, see [upstream's Data sources table](https://github.com/chattymin/PokeTokenBar#data-sources) for the full per-tool list |
| Keychain `Claude Code-credentials`, `~/.claude.json`, `~/.claude/.credentials.json` | Claude account identity/tokens for the Accounts tab (read/write only when you add an account or a switch happens) |
| `~/.codex/auth.json` | Codex account identity/tokens for the Accounts tab |
| [PokéAPI](https://pokeapi.co/) / `raw.githubusercontent.com/PokeAPI/sprites` | Pokémon species, stats, evolutions & sprites — runtime fetch, cached locally, never bundled |

## Data location

This fork keeps its own data under
`~/Library/Application Support/PokeTokenBarExtended/`, with Mobius account data isolated
under the `mobius/` subdirectory so it never collides with your Pokédex/companion save.

The fork has its own bundle identifier (`io.github.sun007021.poketokenbarextended`), so it
installs alongside upstream instead of replacing it. On first launch it carries your
existing data over: the Application Support directory is renamed from the old name, and the
settings stored under the old bundle identifier are copied into the new domain once. Nothing
is deleted — the old `UserDefaults` domain stays behind. See
[docs/reference/mobius-integration.md](docs/reference/mobius-integration.md) for the
migration details and what is *not* carried over.

## Taking upstream updates

Upstream PokeTokenBar changes are brought in selectively (merged or cherry-picked), not by
installing upstream's releases — upstream's build is a separate app and does not update
this one. PokeTokenBar Extended is versioned independently of upstream, starting at
**1.0.0**, and its update banner only tracks this repository's releases. See
[docs/reference/mobius-integration.md](docs/reference/mobius-integration.md) for the
procedure and details.

## License & disclaimer

**MIT** — see [LICENSE](LICENSE) and [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md) for
the exact upstream notices this fork carries forward (PokeTokenBar and Mobius are both MIT,
this fork's own modifications are MIT too). The MIT license covers this project's source
code only; it grants no rights to any third-party trademarks, artwork, or data accessed
through the app.

PokeTokenBar (and this fork) is an **unofficial, non-commercial fan project**. It is **not
affiliated with, endorsed, sponsored, or approved by Nintendo, Game Freak, Creatures Inc.,
or The Pokémon Company.** "Pokémon" and all related names, characters, and imagery are
trademarks and copyrights of their respective owners. This project claims no ownership of,
and asserts no rights over, any Pokémon intellectual property.

- **The app binary and its release artifacts bundle no Pokémon assets.** Pokémon species
  data and sprites are fetched **at runtime** from the public
  [PokéAPI](https://pokeapi.co) and cached locally on your own device; sprite images served
  via PokéAPI remain the property of their respective owners.
- Any Pokémon imagery in this repository's documentation (screenshots/GIFs) is shown solely
  to illustrate the app's functionality.
- The app is provided free of charge for **personal, non-commercial use only.**
- If you are a rights holder with any concern about this project, please open an issue and
  it will be addressed promptly.

*Provided "as is", without warranty of any kind. This notice is not legal advice.*
