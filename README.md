# hnsmix

Captain-based ranked mix matches for CS:GO hide and seek servers. Anything from 1v1 up to
10v10, with an Elo system, a full stats database, and Discord embeds that update themselves.

Two captains volunteer, they pick teams, the match runs, and at the end everyone gets rated
and the results get posted. It is built for HNS servers, so it works alongside hidenseek and
hands control back and forth with the other gamemode plugins instead of fighting them.

## Install

Drop the `addons` folder into your `csgo` folder:

```
addons/sourcemod/plugins/hnsmix.smx                   the compiled plugin
addons/sourcemod/scripting/hnsmix.sp                  source
addons/sourcemod/translations/hnsmix.phrases.txt      all text, required
```

Needs a `mix` section in `databases.cfg` (falls back to `default`). Without a database it
still runs, stats just stay in memory and nothing persists. Discord embeds need the **REST in
Pawn** extension, and are off until you set a webhook.

## How a mix runs

1. `!mix` starts a vote, or an admin uses `!forcemix` to skip straight past it
2. Two players volunteer as captains with `!c`
3. Size and time get picked, then captains take turns with `!pick`
4. The match starts, teams get placed, and the round clock is pinned
5. It ends on the timer, a forfeit, or a surrender vote
6. Stats bank to the database, Elo moves, and the results embed posts

## Elo

Zero-sum, which is the important part. The average rating gap between the two teams prices a
pot, the winners split exactly `+pot` and the losers exactly `-pot`, so the total rating in
the system never inflates. Equal teams are worth 15 points a player, favourites win less and
lose more.

Inside a team, the pot is split by contribution:

```
70% stabs   25% survival time   5% clutches
```

Contribution only moves points **between teammates** around the even share. Carries take from
passengers on a win, anchors shield contributors on a loss, and the team total still equals
the pot exactly. Rounding uses largest remainder so it stays exact in integers, and a final
pass enforces the per-player cap without changing the total.

The pot is sized by the **smaller** live roster, so a short-handed side does not get
overcharged.

Casual mixes (below the ranked size threshold) still show the full end-of-match scoreboard,
but nothing persists. That verdict locks at match start, so growing a mix with `!add` does
not turn a casual game ranked halfway through.

## Rank tags in chat and on the scoreboard

Everyone's rank and Elo shows up next to their name, so you can see the table before a match
starts rather than having to run `!rank` on people.

hnsmix does not write the clan tag itself. It pushes a prefix into **HexTags**, which already
owns the clan tag and re-asserts it on a timer, so two plugins writing it directly would just
fight forever. Formats are configurable:

| Convar | Default |
|---|---|
| `hnsmix_elo_tag` | `1`, turns the whole thing on |
| `hnsmix_elo_tag_chat` | `{default}{rank} [{elo} ELO] ` |
| `hnsmix_elo_tag_score` | `{rank} [{elo} ELO] ` |

`{rank}` becomes `#N` and `{elo}` becomes the rating. HexTags color names work in the chat
format.

HexTags is optional. The native is feature-checked before every call, so without it the plugin
runs normally and the tag just does not appear. If HexTags loads or reloads later, hnsmix
notices and re-pushes every tag rather than leaving people blank.

There is a resend guard keyed on both formats together, so recalculating Elo after every mix
does not re-push a tag that has not actually changed.

## The messy parts, which is most of the work

**People disconnect.** A roster player dropping mid-mix pauses the match automatically and
their captain gets a menu: seat a replacement from spectator, or unpause short-handed. Doing
neither just waits, and the leaver is seated straight back onto their team when they
reconnect. A replacement steps into their exact spot: dead if they were dead, otherwise alive
at their position with their remaining health.

In a 1v1 there is no replacement pool, so the opponent waits, and the missing player forfeits
on a timer unless they come back. Captains can `!extend` that wait.

**Pausing has to freeze everything.** Not just player movement. Grenades in flight get their
velocity saved and their fuses suspended, molotov fires get snuffed and relit on unpause, and
the round clock is held by pushing the round start time forward one frame every frame. That
last bit sounds odd but the HUD clock reads `start + length - now`, so moving the start is
the only way to hold it perfectly still without the once-a-second flicker a timer would give
you.

**Nothing should be able to respawn people.** Deathmatch style plugins and rogue respawners
will happily bring players back mid-round. Any spawn hnsmix did not cause gets undone by
moving the player to spectator, because nothing can force-respawn a spectator.

**hidenseek owns the teams.** It swaps T and CT on CT wins and win streaks. hnsmix does not
fight that, it re-derives which side each roster is on at every round start, so even swaps it
never saw cannot desync it.

## Discord

Three separate embeds, all optional and all off with an empty webhook:

* **Results**, posted once per finished mix, with both rosters ordered by contribution
* **Leaderboards**, one standing embed per category, edited in place forever
* **Live status**, server population and mix state, edited in place and event-driven

The status embed only re-sends when something actually changed, so an idle or empty server
costs nothing. There is a slow safety-net refresh purely to repair a missed edit.

One quirk worth knowing: Discord will not make a `steam://connect` link clickable in a masked
link, and Steam's own linkfilter now shows a "Link Blocked" warning instead of connecting. So
the JOIN button needs an `http(s)` redirect you control, set with `hnsmix_status_join_url`.
Leave it empty and you just get the address with a one click copy button, which always works.

## Commands

Players:

```
!mix / !votemix      start a mix vote        !c / !captain     volunteer as captain
!pick                captain picking         !nomix / !noplay  opt out
!rank / !mixrank     your ranked stats       !mixtop / !lb     leaderboards
!replaceme           hand your spot over     !ff / !surrender  surrender vote
!pause / !unpause    captains only           !add              grow the mix by 1v1
```

Admin:

```
!forcemix            skip the vote           !forceadd         one-sided add
!cancelmix / !stop   end it                  !mixstatus        redraw the status embed
!mixtopdiscord       post a leaderboard      !mixreset         wipe stats (root only)
!mixresetplayer      reset one player        !extend           extend a disconnect wait
```

56 convars total, written to `cfg/sourcemod/hnsmix.cfg` on first run.

## Credits

Written by me. It reads the gamemode state from **hidenseek** (originally by ceLoFaN
([github.com/ceLoFaN](https://github.com/ceLoFaN)), my fork
is in CSGO-hnsova) and pushes rank tags through **HexTags** by Hexer10 rather than writing
clan tags directly, so the two do not fight over who owns the tag.

Discord and HTTP work goes through **REST in Pawn**.

## License

GPL-3.0, see `LICENSE`.
