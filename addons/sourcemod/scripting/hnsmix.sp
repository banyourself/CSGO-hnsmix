/**
	MIX - captain-based team matches (1v1 up to 10v10)

	!mix      - guided setup: captains (via chat), team size, round time, picks
	!mixmenu  - admin panel:
		Start Mix
		Stop Mix
		Lock/Unlock Team Switch (locked by default)
		Move Player(s) to Spec
 */

#pragma semicolon 1

#define VOTE_YES "###yes###"
#define VOTE_NO "###no###"

#include <sourcemod>
#include <sdktools>
#include <sdkhooks>
#include <cstrike>
#include <mapchooser>
#include <clientprefs>
#include <colors>
#include <geoip>

// Elo rank tag goes into HexTags rather than the clan tag directly: HexTags owns that and
// re-asserts it on a timer, so two writers would fight. Soft dependency, feature-checked.
#include <hextags>

// Every Discord embed goes through REST in Pawn. It used to be split between discord-api and
// ripext, two HTTP stacks and two JSON libraries doing one job. ripext is required regardless
// (only it has PATCH, which edit-in-place embeds need), so the others are gone. Feature-checked.
#undef REQUIRE_EXTENSIONS
#include <ripext>
#define REQUIRE_EXTENSIONS

// No PrintToConsoleAll polyfill here: the include set's console.inc provides
// it (this bundle's version_auto.inc misreports 1.8, so version defines can't
// gate it, and spcomp can't #if-defined a function symbol).

enum struct Player_t {
	int clientIdx;
}

// A mix player who disconnected mid-match, remembered by SteamID: the mix
// auto-pauses, their captain may replace them, and on reconnect they either
// get their roster spot back or (if replaced) are locked to spectator.
enum struct DcPlayer_t {
	char sAuth[32];              // Steam2 auth of the player who left
	char sName[MAX_NAME_LENGTH]; // name at the time they left, for menus/chat
	int iRosterTeam;             // CS_TEAM_T / CS_TEAM_CT roster side
	bool bReplaced;              // captain seated a replacement - reconnect goes to spectator
	char sFlag[12];              // country flag captured while they were still connected
	char sAuth64[24];            // SteamID64, same - the results embed links their name
	bool bDeadWhenLeft;          // had died this round when they left - re-seated dead in the same round
	int iLeftRound;              // g_iRoundSerial at the time they left
	bool bHasSpot;               // was alive when they left: faPos/faAng hold where they stood
	float faPos[3];
	float faAng[3];
	int iHealth;                 // health they had when they left (0 = unknown/dead)
}

enum eGameState_t {
	eGameState_None = 0,
	eGameState_PickingPlayers,
	eGameState_DonePickingPlayers,
	eGameState_Match
}

Panel g_pSurvivalPanel = null;
bool g_bWantsToPlay[MAXPLAYERS+1] = {true, ...};
Handle g_hNoMixCookie = null; // clientprefs cookie: persists the !nomix choice across map changes and restarts

eGameState_t g_gameState = eGameState_None;
int g_iLastPickedTeam = CS_TEAM_CT;

int g_iCTCaptain = -1;
int g_iTCaptain = -1;

int g_iLastWinningTeam = -1;

#define PLAYER_TEAM_CT 0
#define PLAYER_TEAM_T 1
#define PLAYER_TEAM_MAX 2

#define __TEAM_T 0
#define __TEAM_CT 1

bool g_bDidSwitchTeams = false;

ArrayList g_alPlayers[PLAYER_TEAM_MAX] = {null, ...};
float g_TeamTimer[PLAYER_TEAM_MAX] = {900.0, ...};

int g_iCurrentPlayerMode = 1;

// Knife rounds: captains 1v1 for the first pick, then full teams for the
// starting side. Selection rounds only - no stats, elo or scoreboard.
#define KNIFE_NONE 0
#define KNIFE_CAPTAINS 1
#define KNIFE_TEAMS 2
#define KNIFE_SIDE_MENU_TIME 30
#define KNIFE_ROUND_TIME 5.0 // knife round mp_roundtime (minutes)
int g_iKnifeStage = KNIFE_NONE;       // knife round currently being fought
bool g_bTeamsKnifeDone = false;       // teams knife decided - StartMatch may go live
bool g_bKnifeSideSwap = false;        // knife winner chose the opposite of the default sides
bool g_bKnifeSidePickPending = false; // a side pick is being waited on
int g_iKnifeSideWinnerTeam = 0;       // roster CS_TEAM_* that won the teams knife
int g_iKnifeSideChooser = -1;         // client holding the side pick (menu or chat)
Handle g_hKnifeSideTimer = null;      // deadline timer - auto-picks T when it fires
float g_fPrevHnsCountdownTime = -1.0; // hidenseek's hns_countdown_time, saved while a knife round zeroes it (-1 = not saved)
int g_iPrevEasySpawnProtection = -1;  // sm_easysp_enabled before a knife round (-1 = not saved)

ConVar cv_TimePerPlayer;
ConVar cv_RoundStartPause;
ConVar cv_LoneTFlashbang;
ConVar cv_ScoreboardTimer;
ConVar cv_LockTeams;
ConVar cv_EndRoundOnStop;
ConVar cv_QueuedMatchmaking;
ConVar cv_ConnectSpec;
ConVar cv_NadeOverride;
ConVar cv_DecoyMax;
ConVar cv_DecoyChance;
ConVar cv_MolotovChance;
ConVar cv_FlashChance;
ConVar cv_FlashMax;
ConVar cv_HeChance;
ConVar cv_MolotovMax;
ConVar cv_SmokeMax;
ConVar cv_HeMax;
ConVar cv_SmokeChance;
ConVar cv_RoundTime;
ConVar cv_VoteMixPercent;
ConVar cv_CtRespawnDelay;
ConVar cv_ChatPrefix;
ConVar cv_SurrenderVoteLimit;
ConVar cv_SurrenderCooldown;
ConVar cv_SurrenderVoteTime;
ConVar cv_DcForfeitTime;
ConVar cv_AdminFlag;

// Cached bits parsed from hnsmix_admin_flag; any one of them grants mix admin
// access (root always passes). The "hnsmix_admin" admin_overrides.cfg entry
// takes priority over these bits.
int g_iMixAdminFlags = ADMFLAG_SLAY;

// Cached copy of hnsmix_chat_prefix; shown as [PREFIX] before every message.
char g_sChatPrefix[32] = "MIX";

// Team labels for chat texts: Team 1 is always orange, Team 2 always blue.
// (\x10 = orange, \x0B = blue, \x08 returns to the gray body text.)
#define MIX_TEAM1_CHAT "\x10Team 1\x08"
#define MIX_TEAM2_CHAT "\x0BTeam 2\x08"

#define MAX_PLAYERS_IN_1V1 20
#define MAX_PLAYERS_IN_1V1_PER_TEAM 10

float fTimeSurvived[MAXPLAYERS+1] = {0.0, ...};

bool g_IsMapChanging;
bool g_IsTeamsLocked = false; // locks when an admin starts a mix (!mix / Start Mix), unlocks when the mix stops
bool g_IsTimerPaused = true;
bool g_bEnginePaused = false;
bool g_bQueuedMatchmakingSet = false;

// !pause / !unpause (captains + admins)
bool g_bMatchPaused = false;  // match is frozen by a captain/admin
int g_iUnpauseCountdown = 0;  // seconds left in the !unpause countdown (0 = none)

// Round-start CT freeze vs pauses: a pause banks what's left of the freeze
// window, the CTs serve that remainder after the unpause.
float g_fCtFreezeEndsAt = 0.0;             // deadline of the current round's CT freeze window
float g_fPostUnpauseCtFreeze = 0.0;        // CT freeze seconds owed when the pause landed
bool g_bPostUnpauseCtFreezeActive = false; // owed freeze being served right now
bool g_baMixMenuOpen[MAXPLAYERS + 1]; // has the mix panel open - refreshed when the pause state changes
bool g_baRosterPanelOpen[MAXPLAYERS + 1]; // has the live picking-phase roster panel open

// Auto-pause on disconnect (see DcPlayer_t). Entries live until the player
// reconnects unreplaced, the mix ends, or the map changes; replaced entries
// stay so a returning player is locked to spectator for the rest of the mix.
ArrayList g_alDcPlayers = null;
// Every roster swap this mix, preformatted as leaver -> replacement. Both paths feed it: a
// captain seating a replacement, and a player handing their spot over with !replaceme (which
// creates no DC entry). Display only, cleared with the mix.
ArrayList g_alMixSwaps = null;
bool g_baReplacedSpectator[MAXPLAYERS + 1]; // reconnected after being replaced - spectator until the mix ends
int g_iaPendingSeatTeam[MAXPLAYERS + 1];    // roster team to re-seat a reconnecting player onto next frame
bool g_baPendingSeatDead[MAXPLAYERS + 1];   // re-seat dead: they died this round and it's still that round
bool g_baPendingSeatSpot[MAXPLAYERS + 1];   // re-seat at the exact spot they disconnected from (same round)
float g_faPendingSeatPos[MAXPLAYERS + 1][3];
float g_faPendingSeatAng[MAXPLAYERS + 1][3];
int g_iaPendingSeatHealth[MAXPLAYERS + 1];  // health to restore after the re-seat respawn (0 = fresh spawn)
int g_iaPendingSeatRound[MAXPLAYERS + 1];   // round the spot/health belong to - stale restores are dropped
int g_iaSeatRespawnTries[MAXPLAYERS + 1];   // re-seat respawn retry counter

// The disconnect kill zeroes a player's live health before OnClientDisconnect
// runs, so the last health seen while actually playing is tracked here
// (updated on spawn and every player_hurt).
int g_iaLastKnownHealth[MAXPLAYERS + 1];

// Per-mix accumulators, shown in the end-of-mix scoreboard and persisted cumulatively by
// SteamID. Survival time reuses fTimeSurvived. DB config is the mix section of databases.cfg,
// falling back to default; stats stay in memory only if nothing connects.
Database g_hStatsDb = null;
ConVar cv_SqlPrefix;
ConVar cv_LbEntries;
ConVar cv_LbMinGames;
ConVar cv_EloContribAvg;   // contribution points at exactly average play (rho 1.0)
ConVar cv_EloContribSlope; // points per unit of rho above/below average
ConVar cv_EloContribMax;   // cap on contribution points
ConVar cv_EloCasualMaxSize; // team sizes at or below this play CASUAL: no elo, no penalties, no banked stats
ConVar cv_EloCurve;         // rating-gap divisor: how fast expectation grows with the elo gap
ConVar cv_SelectionPhase;   // knife rounds: 0=off, 1=on, 2=off for ranked, 3=off for casual
ConVar cv_EloTag;           // show the elo rank tag in chat/scoreboard at all
ConVar cv_EloTagChat;       // chat prefix format: {rank} {elo} substituted, HexTags color names allowed
ConVar cv_EloTagScore;      // scoreboard clan-tag prefix format (no colors - the engine strips them)

// Discord results embed, all optional - an empty webhook turns it off. Leaderboard categories
// are shared by !mixtop and the embeds, declared here because the standing embed arrays below
// are sized from MIX_LB_CLUTCHES.
#define MIX_LB_ELO 1
#define MIX_LB_WL 2
#define MIX_LB_SURVIVAL 3
#define MIX_LB_STABS 4
#define MIX_LB_FALLDMG 5
#define MIX_LB_CLUTCHES 6

ConVar cv_DiscordWebhook;
ConVar cv_DiscordMapImage;
ConVar cv_DiscordName;
ConVar cv_DiscordLbWebhook;
ConVar cv_DiscordLbAuto;
ConVar cv_DiscordPrefix;
ConVar cv_DiscordNameMax;
ConVar cv_StatusWebhook, cv_StatusInterval, cv_StatusIp, cv_StatusLocation, cv_StatusImage, cv_StatusMaxPlayers, cv_StatusJoinUrl;
ConVar cv_AllowSelfReset, cv_AbandonPenalty;

// Logged once, not every status refresh, when the JOIN url is unusable.
bool g_bJoinUrlWarned = false;

// Re-issue window for !resetmystats, same style as sm_mixreset all.
float g_faSelfResetConfirmAt[MAXPLAYERS + 1];

// Status embed sidebar colors while no mix is running. hnsova reports which
// gamemode is live and KevFJ reports funjump; a mix overrides all three with
// green/gold.
#define MIX_STATUS_COLOR_HNS 6013150   // light blue (#5BC0DE)
#define MIX_STATUS_COLOR_OVA 10181046  // purple
#define MIX_STATUS_COLOR_FJ  15158332  // red (#E74C3C)

// hnsova exposes this while One Versus All is the running gamemode. Optional,
// so hnsmix still loads on a server without it.
native int HNS_IsOvaActive();

// KevFJ exposes this while funjump is running. Optional for the same reason.
native int kev_isFJActive();

bool MixOvaActive() {
	return (GetFeatureStatus(FeatureType_Native, "HNS_IsOvaActive") == FeatureStatus_Available && HNS_IsOvaActive() != 0);
}

bool MixFJActive() {
	return (GetFeatureStatus(FeatureType_Native, "kev_isFJActive") == FeatureStatus_Available && kev_isFJActive() != 0);
}
char g_sStatusMessageId[32];
// Holds the rendered status signature: three 1024-char rosters plus the header
// fields. Must not truncate, or a change past the cut compares equal and the
// embed silently stops updating.
char g_sStatusLastBody[6144];
Handle g_hStatusTimer = null;
Handle g_hStatusDebounce = null; // pending coalesced refresh, null when idle
// One standing embed per leaderboard category. Empty id = nothing posted yet,
// so the next refresh creates it; otherwise the refresh edits it in place.
char g_saLbMessageId[MIX_LB_CLUTCHES + 1][32];
char g_saLbLastBody[MIX_LB_CLUTCHES + 1][3072]; // last body sent - skips no-op edits
float g_fMixMatchStart = 0.0;     // wall-clock time the live match began
float g_fMixConfiguredTime = 0.0; // per-team hiding time the match started with
char g_sSqlPrefix[16] = "mix";
bool g_bStatsDbInit = false;

// Driver-portable SQL, set on connect. MySQL is the default; SQLite works
// too (databases.cfg "mix" entry with the sqlite driver).
bool g_bStatsDbSQLite = false;
char g_sSqlMax[12] = "GREATEST";           // scalar two-arg max function
char g_sSqlNow[24] = "UNIX_TIMESTAMP()";   // current unix-time expression

// Shared cooldown for the DB-reading commands (!mixtop / !mixrank) so chat
// spam can't queue up threaded queries.
float g_faNextLbQuery[MAXPLAYERS + 1];

// !mixtop paging state: the last viewed category/page per client, and how
// long the bare "next"/"back" chat words keep being captured for paging.
int g_iaLbCategory[MAXPLAYERS + 1];
int g_iaLbPage[MAXPLAYERS + 1];
float g_faLbSessionEnd[MAXPLAYERS + 1];

// Chat leaderboard lines, drained in timed batches - the engine silently
// drops chat messages past the first few sent in one frame.
ArrayList g_alLbChatQueue[MAXPLAYERS + 1];
Handle g_haLbChatTimer[MAXPLAYERS + 1];

// Elo: ZERO-SUM. The average-elo gap prices a pot via K*(result-expected), equal teams giving
// 15/player and favourites winning less. Winners split exactly +pot, losers exactly -pot, so
// the economy never inflates. Contribution C = 0.70 stabs + 0.25 survival + 0.05 clutches of
// TEAM totals spreads each pot between teammates. Deltas bounded 0..ELO_MAX_DELTA, DB floored.
#define ELO_K 30.0
#define ELO_MAX_DELTA 30
#define ELO_FLOOR 100
#define ELO_ABANDON_PENALTY 25     // left mid-mix and never got their spot back
#define ELO_SELFREPLACE_PENALTY 10 // bailed via !replaceme

// Everyone starts here; also the fallback when no stats row exists yet.
// (MIX_LB_* live further up, next to the Discord embed globals they size.)
#define MIX_DEFAULT_ELO 1000
int g_iaElo[MAXPLAYERS + 1] = {MIX_DEFAULT_ELO, ...};
int g_iaEloRank[MAXPLAYERS + 1];      // leaderboard position, 0 = unranked/unknown
char g_saEloTag[MAXPLAYERS + 1][132]; // last chat+score prefix pushed to HexTags - resend guard

// Casual/ranked verdict, fixed at match start so !add can't flip it mid-mix.
// -1 = unset (fall back to the live team size), 1 = casual, 0 = ranked.
int g_iMixCasualLock = -1;
// Pending "sm_mixreset all" confirmation, per command source. Index 0 is the
// server console, which is a real caller here, not a sentinel.
#define MIX_RESET_CONFIRM_WINDOW 30.0
float g_faResetConfirmAt[MAXPLAYERS + 1];
// Ranked when it went live. An !add / !forceadd that leaves the teams uneven
// downgrades the match to casual, and the results embed reports that rather
// than silently showing no ELO.
bool g_bMixWentLiveRanked = false;
// Was the losing side still alive when the round ended? Captured in a Pre hook
// because hidenseek physically swaps every player during its own round_end
// handler - see EventRoundEndPre.
bool g_bKnifeLoserAliveAtEnd = false;
int g_iForceAddTeam = CS_TEAM_CT; // team chosen in the !forceadd menu

// Self-replace stat takeover: the replacement inherits the leaver's current-mix stats so team
// totals stay whole, but the inherited part is subtracted when banking - only post-replacement
// gains count toward their own !rank.
float g_faInhSurvival[MAXPLAYERS + 1];
int g_iaInhStabsGiven[MAXPLAYERS + 1];
int g_iaInhStabsTaken[MAXPLAYERS + 1];
int g_iaInhFallDamage[MAXPLAYERS + 1];
int g_iaInhClutches[MAXPLAYERS + 1];
int g_iaInhTRounds[MAXPLAYERS + 1];

// Which captain currently holds the team-size menu - re-rendered live when
// the willing-player pool changes (!yesmix / !nomix), so sizes un-gray.
int g_iModeMenuClient = -1;

// Self-replace (!replaceme): a non-captain roster player offers their spot
// to one or all willing spectators. First Yes wins; the requester is told
// Rejected only once EVERY offered spectator said No (or the offer expired).
#define SELF_REPLACE_TIMEOUT 30.0
int g_iaSelfOfferFrom[MAXPLAYERS + 1];         // per-SPECTATOR: userid of the player asking to be replaced (0 = none)
bool g_baSelfOfferMenuOpen[MAXPLAYERS + 1];    // per-SPECTATOR: the yes/no offer menu is up
bool g_baSelfReplaceActive[MAXPLAYERS + 1];    // per-REQUESTER: an offer round is outstanding
int g_iaSelfReplacePending[MAXPLAYERS + 1];    // per-REQUESTER: spectators still holding the offer
bool g_baSelfWaitPanelOpen[MAXPLAYERS + 1];    // per-REQUESTER: the Waiting/Accepted/Rejected panel is up
Handle g_haSelfReplaceTimeout[MAXPLAYERS + 1]; // per-REQUESTER: offer expiry timer

// !add: both captains seat one extra spectator each, growing the mix by 1v1. The match pauses
// for the picks, a coin flip decides who picks first, and either captain may Cancel Add, which
// un-seats anyone added and resumes where the pause caught the round.
bool g_bAddActive = false;
int g_iAddStep = 0;           // 0 = first captain picking, 1 = second
int g_iaAddTeamOrder[2];      // roster teams in pick order
int g_iAddPicker = -1;        // captain holding the menu right now
int g_iaAddedUserId[2];       // seated so far - the cancel path un-seats them
bool g_bAddWasPaused = false; // already paused before !add - stays paused after

int g_iaMixStabsGiven[MAXPLAYERS + 1];
int g_iaMixStabsTaken[MAXPLAYERS + 1];
int g_iaMixFallDamage[MAXPLAYERS + 1];
int g_iaMixClutches[MAXPLAYERS + 1];    // rounds survived to the end while playing the T side
int g_iaMixTRounds[MAXPLAYERS + 1];     // T-side rounds played this mix - the average-survival denominator
bool g_bMixRoundWasLive = false;        // the current round STARTED while the mix was live (skips the mp_restartgame artifact round)
int g_iLastClutchRound = -1;            // g_iRoundSerial already counted - clutches award once per round
int g_iPendingStatsWinner = -1; // __TEAM_* index handed from EndMixWithWinner to Stop1v1 (-1 = no winner)
// How the mix ended, as passed to EndMixWithWinner: "time", "forfeit" or
// "surrender". The results embed labels the losing team with it, so a match
// that ended early does not read as a normal timer win.
char g_sMixEndReason[24];
char g_saDcMenuAuth[MAXPLAYERS + 1][32];    // which DC entry a captain's replace-menu currently targets
bool g_baDcMenuOpen[MAXPLAYERS + 1];        // has a DC menu open - refreshed when the missing player returns

int g_iRoundSerial = 0; // bumped every round_start - detects "still the same round" on re-seats

// !surrender: a whole-team vote, offered only to the initiator's roster team,
// must pass unanimously. g_alSurrenderVoteStarts holds one auth per vote
// STARTED (counts against hnsmix_surrender_votes; survives reconnects).
ArrayList g_alSurrenderVoteStarts = null;
bool g_bSurrenderVoteActive = false;
int g_iSurrenderVoteTeam = 0;          // roster team voting to give up
int g_iaSurrenderVote[MAXPLAYERS + 1]; // 0 = no vote yet, 1 = yes, 2 = no
float g_faSurrenderNextVote[2];        // per-team cooldown gate (GetGameTime), indexed __TEAM_*
Handle g_hSurrenderVoteTimer = null;   // vote timeout

// Steam2 auth cache: filled on connect/post-admin-check, read by everything
// that would otherwise call GetClientAuthId repeatedly.
char g_saClientAuth[MAXPLAYERS + 1][32];
bool g_baDcCheckDone[MAXPLAYERS + 1]; // returning-player check already ran with a valid auth

// 1v1 disconnect wait: no replacement pool, so unpausing is blocked (admins
// override). The leaver has hnsmix_dc_forfeit_time secs to return or forfeit;
// !extend adds more. Active while g_hDcWaitTimer != null.
Handle g_hDcWaitTimer = null;
int g_iDcWaitSecondsLeft = 0;
int g_iDcWaitTeam = 0;                  // roster team of the missing player
char g_sDcWaitAuth[32];
char g_sDcWaitName[MAX_NAME_LENGTH];
bool g_baDcWaitMenuOpen[MAXPLAYERS + 1]; // has the wait menu open - re-rendered each tick so the countdown is live

// While a disconnect pause holds, win conditions are suspended so the leaver's
// death can't end (elimination win) the round they're meant to resume into.
bool g_bWinCondsSuspended = false;

// Grenades frozen during a pause (7 cells each: entref, vel x/y/z, origin
// x/y/z). Movetype is left alone (writing it via props permanently unregisters
// physics) - instead the origin is re-pinned each frame, velocity restored on unpause.
ArrayList g_alFrozenNades = null;

// Molotov fire is client-side/wall-clock, so it can't be frozen (would ghost:
// invisible flame + endless sound). Snuffed at pause, re-lit on unpause.
// 4 cells each: origin x/y/z + thrower userid.
ArrayList g_alPausedInfernos = null;

// Popped smokes have the same client-side problem: snuffed at pause,
// re-deployed on unpause. Same 4-cell block layout.
ArrayList g_alPausedSmokes = null;

static const char g_szNadeProjectiles[][] = {
	"hegrenade_projectile",
	"flashbang_projectile",
	"smokegrenade_projectile",
	"decoy_projectile",
	"molotov_projectile" // covers incendiary grenades too
};

// !mix guided setup
#define MIX_STAGE_NONE 0
#define MIX_STAGE_CT_CAPTAIN 1
#define MIX_STAGE_T_CAPTAIN 2
int g_iMixSetupAdmin = -1;
int g_iMixSetupStage = MIX_STAGE_NONE;
float g_fMixRoundTime = 0.0;
bool g_bVotedMix = false;        // setup came from !votemix: auto-start when picks complete
bool g_bAwaitingCaptains = false; // votemix passed; players volunteer as captains via !c

// Real team scores saved at match start / restored at stop - the score slots
// display each team's remaining time during a mix.
int g_iPrevTeamScoreT = 0;
int g_iPrevTeamScoreCT = 0;

// Team balancing convars saved at match start, forced off during the mix, restored at stop.
int g_iPrevAutoTeamBalance = -1;
int g_iPrevLimitTeams = -1;

// The game's instant respawns for both teams, saved at match start, forced off during the mix -
// the dead stay dead until the next round - and restored at stop. Respawn wave times go sky-high
// too: deathmatch modes respawn on the wave timer and ignore mp_respawn_on_death_* entirely.
int g_iPrevRespawnOnDeathCT = -1;
int g_iPrevRespawnOnDeathT = -1;
float g_fPrevRespawnWaveCT = -1.0;
float g_fPrevRespawnWaveT = -1.0;

// Hard anti-respawn enforcement during a live mix: any unauthorized spawn is undone by moving
// the player to spectator, since nothing can force-respawn a spectator. Round-end re-seats
// roster players and round-start respawns them.
bool g_bBetweenRounds = true;                    // between round_end and round_start (spawns legit)
float g_fRoundStartedAt = 0.0;                   // spawns shortly after round_start are legit
bool g_baAuthorizedSpawn[MAXPLAYERS + 1];        // set right before hnsmix respawns someone itself

// Anti forced-spectate: during a live mix, roster players moved to spectator
// by anything OTHER than hnsmix itself (e.g. an AFK manager) are moved back.
bool g_baAuthorizedSpecMove[MAXPLAYERS + 1];     // set right before hnsmix spec-moves someone itself
float g_faLastDeathTime[MAXPLAYERS + 1];         // distinguishes real deaths from the kill a forced team-switch causes
bool g_baDeadThisRound[MAXPLAYERS + 1];          // died mid-round; cleared by any legitimate spawn - catches "revives" that skip player_spawn

// Admin-panel replace flow: the picked player chosen in step one, per admin. (userid)
int g_iReplaceOldUserId[MAXPLAYERS+1];

// Temporary hidenseek.sp convar overrides while a mix is live. Originals are saved at match
// start, re-asserted every round so nothing mid-mix wins, and restored at stop. Indexes 0-9 are
// grenade convars; the last two suppress HNS-Anti-Frag's CT stab cooldown and hit color.
#define HNS_NADE_CVAR_COUNT 10
static const char g_szHnsCvarNames[][] = {
	"hns_decoy_maximum_amount",
	"hns_decoy_chance",
	"hns_flashbang_chance",
	"hns_flashbang_maximum_amount",
	"hns_he_grenade_chance",
	"hns_he_grenade_maximum_amount",
	"hns_molotov_chance",
	"hns_molotov_maximum_amount",
	"hns_smoke_grenade_maximum_amount",
	"hns_smoke_grenade_chance",
	"hns_f_ct_cooldown",
	"hns_f_enable_transparent"
};
float g_fHnsCvarPrevValues[sizeof(g_szHnsCvarNames)];
bool g_bHnsCvarFound[sizeof(g_szHnsCvarNames)];
bool g_bHnsCvarsOverridden = false;

// Lone-terrorist flashbang (once per round)
bool g_bGaveLoneTFlash = false;

int g_MenuAccess = -1;
int g_MenuAccessTo = -1;

Handle g_HudSyncMatchIsLive;
Handle g_1v1Ticker;
Handle g_hPauseTimer = null;

bool g_Init = false;

public Plugin myinfo = {
	name = "[MIX] Ranked/Casual Matches", 
	author = "Kevin", 
	description = "Captain-based ranked MIX matches from 1v1 up to 10v10", 
	version = "1.17.0",
	url = "https://steamcommunity.com/id/iamarealplayer/"
};

public void OnPluginStart() {
	LoadTranslations("common.phrases");
	LoadTranslations("basevotes.phrases");

	// End-of-mix scoreboard texts live in translations/hnsmix.phrases.txt
	// (auto-created with the defaults if missing) - edit that file to change
	// wording and colors, no recompile needed.
	write_default_mix_phrases();
	LoadTranslations("hnsmix.phrases");

	// Stale-cache guard: if this file was parsed earlier in the session (a reload mid-map),
	// SourceMod keeps serving the OLD phrase set until the next map change, so new phrases stay
	// invisible and every %t on them throws. Detect it via a phrase this build needs and force a
	// synchronous re-parse. The probe is a version phrase renamed on every change, so edits to
	// existing phrases are detected too.
	if(!TranslationPhraseExists("Mix Phrases V15")) {
		InsertServerCommand("sm_reload_translations");
		ServerExecute();
		if(TranslationPhraseExists("Mix Phrases V15")) {
			LogMessage("[MIX] Reloaded translation files to pick up the upgraded hnsmix phrases.");
		}
		else {
			LogError("[MIX] hnsmix phrases are still stale after a reload - change the map (or restart the server) to load them.");
		}
	}

	cv_TimePerPlayer = CreateConVar("hnsmix_time_per_player", "300", "Fallback seconds of match time per player per team when no round time was chosen in the setup.", FCVAR_NOTIFY, true, 30.0);
	cv_RoundStartPause = CreateConVar("hnsmix_roundstart_pause", "5.0", "Seconds the mix timer stays paused at round start while CTs are frozen.", FCVAR_NOTIFY, true, 0.0);
	cv_LoneTFlashbang = CreateConVar("hnsmix_lone_t_flashbang", "1", "Give the last alive terrorist 1 flashbang. (1 = on, 0 = off)", FCVAR_NOTIFY, true, 0.0, true, 1.0);
	cv_ScoreboardTimer = CreateConVar("hnsmix_scoreboard_timer", "1", "Show each team's remaining time in the scoreboard score slots. (1 = on, 0 = off)", FCVAR_NOTIFY, true, 0.0, true, 1.0);
	cv_LockTeams = CreateConVar("hnsmix_lock_teams", "1", "Automatically lock team switching while a mix is being set up or running. (1 = on, 0 = off)", FCVAR_NOTIFY, true, 0.0, true, 1.0);
	cv_EndRoundOnStop = CreateConVar("hnsmix_end_round_on_stop", "1", "End the current round when a live mix is stopped. (1 = on, 0 = off)", FCVAR_NOTIFY, true, 0.0, true, 1.0);
	cv_QueuedMatchmaking = CreateConVar("hnsmix_queued_matchmaking", "1", "Mark the game as queued matchmaking while a mix is live. (1 = on, 0 = off)", FCVAR_NOTIFY, true, 0.0, true, 1.0);
	cv_ConnectSpec = CreateConVar("hnsmix_connect_spec", "1", "Move players to spectator when they fully connect. (1 = on, 0 = off)", FCVAR_NOTIFY, true, 0.0, true, 1.0);
	cv_NadeOverride = CreateConVar("hnsmix_nade_override", "1", "Temporarily override the hidenseek grenade convars while a mix is live. (1 = on, 0 = off)", FCVAR_NOTIFY, true, 0.0, true, 1.0);
	cv_DecoyMax = CreateConVar("hnsmix_decoy_max", "0", "Value for hns_decoy_maximum_amount while a mix is live.", FCVAR_NOTIFY, true, 0.0);
	cv_DecoyChance = CreateConVar("hnsmix_decoy_chance", "0", "Value for hns_decoy_chance while a mix is live.", FCVAR_NOTIFY, true, 0.0, true, 1.0);
	cv_MolotovChance = CreateConVar("hnsmix_molotov_chance", "0", "Value for hns_molotov_chance while a mix is live.", FCVAR_NOTIFY, true, 0.0, true, 1.0);
	cv_FlashChance = CreateConVar("hnsmix_flash_chance", "0.33", "Value for hns_flashbang_chance while a mix is live.", FCVAR_NOTIFY, true, 0.0, true, 1.0);
	cv_FlashMax = CreateConVar("hnsmix_flash_max", "1", "Value for hns_flashbang_maximum_amount while a mix is live.", FCVAR_NOTIFY, true, 0.0);
	cv_HeChance = CreateConVar("hnsmix_he_chance", "0.0005", "Value for hns_he_grenade_chance while a mix is live.", FCVAR_NOTIFY, true, 0.0, true, 1.0);
	cv_HeMax = CreateConVar("hnsmix_he_max", "1", "Value for hns_he_grenade_maximum_amount while a mix is live.", FCVAR_NOTIFY, true, 0.0);
	cv_SmokeChance = CreateConVar("hnsmix_smoke_chance", "0", "Value for hns_smoke_grenade_chance while a mix is live.", FCVAR_NOTIFY, true, 0.0, true, 1.0);
	cv_MolotovMax = CreateConVar("hnsmix_molotov_max", "0", "Value for hns_molotov_maximum_amount while a mix is live.", FCVAR_NOTIFY, true, 0.0);
	cv_SmokeMax = CreateConVar("hnsmix_smoke_max", "0", "Value for hns_smoke_grenade_maximum_amount while a mix is live.", FCVAR_NOTIFY, true, 0.0);
	cv_RoundTime = CreateConVar("hnsmix_mp_roundtime", "2.5", "mp_roundtime in minutes, enforced permanently whether a mix is running or not. (2.5 = 2:30)", FCVAR_NOTIFY, true, 1.0, true, 60.0);
	cv_VoteMixPercent = CreateConVar("hnsmix_votemix_percent", "0.80", "Fraction of all players on the server that must vote yes for !votemix to pass.", FCVAR_NOTIFY, true, 0.05, true, 1.0);
	cv_CtRespawnDelay = CreateConVar("hnsmix_ct_respawn_delay", "0", "Seconds before a dead CT respawns during a live mix round. (0 = default: nobody respawns until the next round; the game's instant respawns are disabled while a mix is live)", FCVAR_NOTIFY, true, 0.0, true, 60.0);
	cv_SurrenderVoteLimit = CreateConVar("hnsmix_surrender_votes", "2", "How many surrender votes each player may start per mix. (0 = surrender voting disabled)", FCVAR_NOTIFY, true, 0.0, true, 10.0);
	cv_SurrenderCooldown = CreateConVar("hnsmix_surrender_cooldown", "60.0", "Seconds a team must wait after a failed surrender vote before another can start.", FCVAR_NOTIFY, true, 0.0, true, 600.0);
	cv_SurrenderVoteTime = CreateConVar("hnsmix_surrender_votetime", "30.0", "Seconds a surrender vote stays open before it fails.", FCVAR_NOTIFY, true, 5.0, true, 120.0);
	cv_DcForfeitTime = CreateConVar("hnsmix_dc_forfeit_time", "300", "Seconds a disconnected 1v1 player has to reconnect before they forfeit; !extend adds the same amount.", FCVAR_NOTIFY, true, 30.0, true, 1800.0);
	cv_AdminFlag = CreateConVar("hnsmix_admin_flag", "o", "Admin flag(s) that grant full mix control (mix/forcemix/stop/pause/unpause/replace and the menu's admin items). Any listed flag grants access; root always passes. An 'hnsmix_admin' entry in admin_overrides.cfg overrides this. sm_mixreset stays root-only.", FCVAR_NOTIFY);
	RefreshMixAdminFlags();
	cv_AdminFlag.AddChangeHook(OnMixAdminFlagChanged);
	cv_SqlPrefix = CreateConVar("hnsmix_sql_prefix", "mix", "Table prefix for the mix stats MySQL tables (created as <prefix>_stats). Read once when the database connects at plugin start.", FCVAR_NOTIFY);
	cv_LbEntries = CreateConVar("hnsmix_lb_entries", "10", "How many players each mix leaderboard category lists.", FCVAR_NOTIFY, true, 1.0, true, 25.0);
	cv_LbMinGames = CreateConVar("hnsmix_lb_min_games", "5", "Minimum finished mixes before a player appears on the Win/Loss Ratio leaderboard.", FCVAR_NOTIFY, true, 0.0, true, 100.0);
	cv_EloContribAvg = CreateConVar("hnsmix_elo_contrib_avg", "3.0", "Contribution points at exactly average play (rho 1.0). Deltas are mean-centered per team (zero-sum), so this mainly positions the 0..max clamp window.", FCVAR_NOTIFY, true, 0.0, true, 15.0);
	cv_EloContribSlope = CreateConVar("hnsmix_elo_contrib_slope", "3.0", "Contribution points per unit of rho above/below average - how far carries and passengers spread from their team's even pot share.", FCVAR_NOTIFY, true, 0.0, true, 15.0);
	cv_EloContribMax = CreateConVar("hnsmix_elo_contrib_max", "7.0", "Cap on contribution points (bounds the within-team spread).", FCVAR_NOTIFY, true, 0.0, true, 15.0);
	cv_EloCasualMaxSize = CreateConVar("hnsmix_elo_casual_max_size", "3", "Mixes at or below this team size are CASUAL: no elo changes, no abandon/self-replace penalties, and no stats banked toward !rank/!lb (the end-of-mix scoreboard still shows them). 3 = 1v1/2v2/3v3 casual, 4v4+ ranked. 0 = every size is ranked.", FCVAR_NOTIFY, true, 0.0, true, 10.0);
	cv_SelectionPhase = CreateConVar("hnsmix_selection_phase", "1", "Selection phase (knife rounds for first pick + starting side): 0 = disabled, 1 = enabled for all mixes, 2 = disabled for RANKED mixes, 3 = disabled for CASUAL mixes.", FCVAR_NOTIFY, true, 0.0, true, 3.0);
	cv_EloTag = CreateConVar("hnsmix_elo_tag", "1", "Show every player's rank/elo as a tag in chat and on the scoreboard. Needs HexTags loaded. (1 = on, 0 = off)", FCVAR_NOTIFY, true, 0.0, true, 1.0);
	cv_EloTagChat = CreateConVar("hnsmix_elo_tag_chat", "{default}{rank} [{elo} ELO] ", "Chat tag format. {rank} becomes #N (or the unranked text), {elo} the rating. HexTags color names such as {orange}/{default}/{green} work here.");
	cv_EloTagScore = CreateConVar("hnsmix_elo_tag_score", "{rank} [{elo} ELO] ", "Scoreboard clan-tag format. Same {rank}/{elo} tokens; colors are stripped by the engine so don't use them here.");
	cv_EloTag.AddChangeHook(OnEloTagCvarChanged);
	cv_EloTagChat.AddChangeHook(OnEloTagCvarChanged);
	cv_EloTagScore.AddChangeHook(OnEloTagCvarChanged);
	cv_EloCurve = CreateConVar("hnsmix_elo_curve", "825", "Rating-gap divisor for the expected-result curve: higher = gentler favorite/underdog adjustment. 825 prices a 362 AVERAGE-elo gap (e.g. 7990 vs 6540 total in a 4v4) at 8/player if the favorites win and 22/player on an upset; classic chess Elo is 400.", FCVAR_NOTIFY, true, 200.0, true, 10000.0);

	cv_DiscordWebhook = CreateConVar("hnsmix_discord_webhook", "", "Discord webhook URL the end-of-mix results embed posts to. Empty = disabled. Needs the REST in Pawn extension.", FCVAR_PROTECTED);
	cv_DiscordMapImage = CreateConVar("hnsmix_discord_map_image", "https://image.gametracker.com/images/maps/160x120/csgo/{MAP}.jpg", "Embed thumbnail URL pattern; {MAP} is replaced with the current map name. Empty = no thumbnail.");
	cv_DiscordName = CreateConVar("hnsmix_discord_name", "HNS Mix", "Username the results webhook posts as.");
	cv_DiscordLbWebhook = CreateConVar("hnsmix_discord_lb_webhook", "", "Webhook the !mixtopdiscord leaderboard posts to. Empty = reuse hnsmix_discord_webhook.", FCVAR_PROTECTED);
	cv_DiscordPrefix = CreateConVar("hnsmix_discord_prefix", "Kevin", "Community name shown in the Discord embed titles, e.g. \"Kevin MIX - Final Results\".");
	cv_StatusWebhook = CreateConVar("hnsmix_status_webhook", "", "Webhook for the live server-status embed. Empty = the status embed is disabled entirely.", FCVAR_PROTECTED);
	cv_StatusInterval = CreateConVar("hnsmix_status_interval", "90.0", "Seconds between server-status SAFETY-NET refreshes. The embed is event-driven (joins, leaves, mix phase, map change), so this only repairs a missed edit and advances the round clock. Unchanged content is never re-sent, so an idle or empty server costs nothing here.", FCVAR_NOTIFY, true, 30.0, true, 1800.0);
	cv_StatusIp = CreateConVar("hnsmix_status_ip", "", "Connect address shown in the status embed. Empty = read the real ip/port from the server.");
	cv_AllowSelfReset = CreateConVar("hnsmix_allow_self_reset", "0", "Let players clear their own survival time and stabs with !resetmystats. Elo, wins/losses, fall damage and clutches are never self-resettable. (1 = on, 0 = off)", FCVAR_NOTIFY, true, 0.0, true, 1.0);
	cv_AbandonPenalty = CreateConVar("hnsmix_abandon_penalty", "1", "Charge the elo penalty to players who leave a ranked mix and never reclaim their spot. (1 = on, 0 = abandoning costs nothing)", FCVAR_NOTIFY, true, 0.0, true, 1.0);
	cv_StatusJoinUrl = CreateConVar("hnsmix_status_join_url", "", "URL the status embed's JOIN button points at. MUST be http:// or https:// - Discord renders a steam:// masked link as literal text, and Steam's own linkfilter is now blocked, so this needs an http(s) redirect you control that forwards to steam://connect/<address>. Use {IP} to mark where the connect address goes (e.g. https://your.site/join?s={IP}); without {IP} the address is appended to the end. Empty = no JOIN link, address only.");
	cv_StatusLocation = CreateConVar("hnsmix_status_location", "", "Override the status embed's location line. Empty = detect it from the server's own IP via GeoIP, which is what you normally want.");
	cv_StatusImage = CreateConVar("hnsmix_status_image", "", "Large map image URL for the status embed; {MAP} is replaced with the map name. Empty = no image.");
	cv_DiscordNameMax = CreateConVar("hnsmix_discord_name_max", "8", "Longest player name shown in the narrow Discord embed columns (leaderboards, status rosters). Shorter names stop a column wrapping and losing step with the one beside it. The results embed has wider columns and keeps its own limit.", FCVAR_NOTIFY, true, 6.0, true, 32.0);
	cv_StatusMaxPlayers = CreateConVar("hnsmix_status_maxplayers", "16", "Player slots shown in the status embed. Set manually: MaxClients reports the engine's allocated slots (64) and sv_visiblemaxplayers is unset, so neither reflects the real limit.", FCVAR_NOTIFY, true, 1.0, true, 64.0);
	cv_StatusWebhook.AddChangeHook(OnStatusCvarChanged);
	cv_StatusInterval.AddChangeHook(OnStatusCvarChanged);
	cv_DiscordLbAuto = CreateConVar("hnsmix_discord_lb_auto", "1", "Keep every Discord leaderboard category up to date automatically: after each RANKED mix, edit each category's existing embed in place, or post it once if it does not exist yet. Categories whose table did not change are skipped. (1 = on, 0 = off)", FCVAR_NOTIFY, true, 0.0, true, 1.0);
	cv_ChatPrefix = CreateConVar("hnsmix_chat_prefix", "MIX", "Chat/menu prefix for all mix messages, shown in brackets. e.g. MIX shows as [MIX], TEST shows as [TEST].");
	cv_ChatPrefix.GetString(g_sChatPrefix, sizeof(g_sChatPrefix));
	cv_ChatPrefix.AddChangeHook(OnChatPrefixChanged);
	AutoExecConfig(true, "hnsmix");

	// OnMapStart does not fire on a mid-map plugin reload, so without these the
	// reloaded plugin would forget its message ids and orphan every embed by
	// posting a fresh set alongside them.
	LoadMixLbMessageIds();
	LoadMixStatusMessageId();

	RegConsoleCmd("sm_mixmenu", Command_MixMenu, "Opens the mix menu. (admins + captains)");
	RegConsoleCmd("sm_menu", Command_MixMenu, "Opens the mix menu. (alias)");
	RegConsoleCmd("sm_mm", Command_MixMenu, "Opens the mix menu. (alias)");
	RegAdminCmd("sm_mix", Command_Mix, g_iMixAdminFlags, "Starts a guided mix setup: captains, team size, round time, then picks.");
	RegConsoleCmd("sm_startmix", Command_StartMix, "Starts the match once teams are ready (admins + captains); admins can also begin a new setup.");
	RegConsoleCmd("sm_start", Command_StartMix, "Starts the match once teams are ready. (alias)");
	RegConsoleCmd("sm_c", Command_Captain);
	RegConsoleCmd("sm_captain", Command_Captain);
	RegConsoleCmd("sm_uc", Command_Uncaptain);
	RegConsoleCmd("sm_uncaptain", Command_Uncaptain);
	RegConsoleCmd("sm_pick", Command_PickPlayer);
	RegConsoleCmd("sm_replace", Command_ReplacePlayer);
	RegConsoleCmd("sm_replaceme", Command_ReplaceMe, "Offer your mix spot to a spectator (self-replace).");
	RegAdminCmd("sm_mixreset", Command_MixResetStats, ADMFLAG_ROOT, "Resets mix leaderboard stats. Usage: sm_mixreset <all|elo|winloss|stabs|falldmg|clutches|survivaltime> ('all' must be run twice to confirm). Not allowed while a mix is live.");
	RegConsoleCmd("sm_stopmix", Command_StopMix, "Stops the mix: cancels team selection or stops a live match. (admins + captains)");
	RegConsoleCmd("sm_cancelmix", Command_StopMix, "Stops the mix: cancels team selection or stops a live match. (alias)");
	RegConsoleCmd("sm_stop", Command_StopMix, "Stops the mix. (alias)");
	RegConsoleCmd("sm_votemix", Command_VoteMix);
	RegAdminCmd("sm_forcemix", Command_ForceMix, g_iMixAdminFlags, "Force-starts a mix as if a !votemix passed: players volunteer as captains with !c.");
	RegConsoleCmd("sm_pause", Command_PauseMix, "Pauses the live mix: players frozen, timers held. (captains + admins)");
	RegConsoleCmd("sm_pausemix", Command_PauseMix, "Pauses the live mix. (alias)");
	RegConsoleCmd("sm_unpause", Command_UnpauseMix, "Resumes the live mix after a 5 second countdown. (captains + admins)");
	RegConsoleCmd("sm_unpausemix", Command_UnpauseMix, "Resumes the live mix. (alias)");
	RegConsoleCmd("sm_resume", Command_UnpauseMix, "Resumes the live mix. (alias)");
	RegConsoleCmd("sm_nomix", Command_NoMix, "Opt out of mixes: you can't be picked or made captain until you type !yesmix.");
	RegConsoleCmd("sm_yesmix", Command_YesMix, "Opt back into mixes after !nomix.");
	RegConsoleCmd("sm_yesplay", Command_YesMix, "Opt back into mixes after !nomix. (alias)");
	RegConsoleCmd("sm_noplay", Command_NoPlayToggle, "Toggle between !nomix and !yesmix.");
	RegConsoleCmd("sm_surrender", Command_Surrender, "Start a surrender vote for your team; unanimous yes hands the other team the win. In a 1v1 the other team wins immediately.");
	RegConsoleCmd("sm_ff", Command_Surrender, "Start a surrender vote for your team. (alias)");
	RegConsoleCmd("sm_extend", Command_Extend, "Add 3 minutes to the wait for a disconnected 1v1 player. (captains + admins)");
	RegConsoleCmd("sm_dcmenu", Command_DcMenu, "Reopen the disconnect/surrender menu: the 1v1 wait menu, or the replace menu for a missing player. (captains + admins)");
	RegConsoleCmd("sm_add", Command_AddPlayers, "Grow the live mix by one player per team: both captains pick a spectator. (captains + admins)");
	RegConsoleCmd("sm_addplayer", Command_AddPlayers, "Grow the live mix by one player per team. (alias)");
	RegConsoleCmd("sm_addplayers", Command_AddPlayers, "Grow the live mix by one player per team. (alias)");
	RegConsoleCmd("sm_canceladd", Command_CancelAdd, "Cancel an add in progress and resume the mix. (captains + admins)");
	RegAdminCmd("sm_forceadd", Command_ForceAdd, g_iMixAdminFlags, "Force one player onto a team you choose, even if it unbalances the mix. Stays paused until you unpause; unbalanced teams drop the match to casual.");
	RegAdminCmd("sm_forceaddplayer", Command_ForceAdd, g_iMixAdminFlags, "Force-add one player to a chosen team. (alias)");
	RegConsoleCmd("sm_mixtop", Command_MixLeaderboard, "Opens the mix leaderboard menu.");
	RegConsoleCmd("sm_topmix", Command_MixLeaderboard, "Opens the mix leaderboard menu. (alias)");
	RegConsoleCmd("sm_mixlb", Command_MixLeaderboard, "Opens the mix leaderboard menu. (alias)");
	RegConsoleCmd("sm_lbmix", Command_MixLeaderboard, "Opens the mix leaderboard menu. (alias)");
	RegConsoleCmd("sm_lb", Command_MixLeaderboard, "Opens the mix leaderboard menu. (alias)");
	RegConsoleCmd("sm_leaderboard", Command_MixLeaderboard, "Opens the mix leaderboard menu. (alias)");
	RegAdminCmd("sm_mixtopdiscord", Command_MixLbDiscord, g_iMixAdminFlags, "Post a leaderboard to Discord as an embed. Usage: sm_mixtopdiscord [elo|winloss|survival|stabs|falldmg|clutches|all]");
	RegAdminCmd("sm_lbdiscord", Command_MixLbDiscord, g_iMixAdminFlags, "Post a leaderboard to Discord. (alias)");
	RegAdminCmd("sm_mixstatus", Command_MixStatusDiscord, g_iMixAdminFlags, "Force the Discord server-status embed to refresh now. Usage: sm_mixstatus [new] - 'new' reposts it as a fresh message.");
	RegAdminCmd("sm_statusdiscord", Command_MixStatusDiscord, g_iMixAdminFlags, "Force the Discord server-status embed to refresh. (alias)");
	RegConsoleCmd("sm_mixrank", Command_MixRank, "Shows a player's mix ranked status. Usage: sm_mixrank [player]");
	RegConsoleCmd("sm_rankmix", Command_MixRank, "Shows a player's mix ranked status. (alias)");
	RegConsoleCmd("sm_rank", Command_MixRank, "Shows a player's mix ranked status. (alias)");
	RegConsoleCmd("sm_resetmystats", Command_MixResetMine, "Clear your own survival time and/or stabs, if the server allows it.");
	RegConsoleCmd("sm_mixresetme", Command_MixResetMine, "Clear your own stats. (alias)");
	RegAdminCmd("sm_mixresetplayer", Command_MixResetPlayer, ADMFLAG_ROOT, "Reset one stat, or every stat except elo, for a player or all players");
	RegConsoleCmd("sm_hnsmix", Command_HelpMix, "Lists every mix command in chat. (alias)");
	RegConsoleCmd("sm_helpmix", Command_HelpMix, "Lists every mix command in chat, with captain/admin tags.");
	RegConsoleCmd("sm_mixhelp", Command_HelpMix, "Lists every mix command in chat. (alias)");
	RegConsoleCmd("sm_mixcmds", Command_HelpMix, "Lists every mix command in chat. (alias)");
	RegConsoleCmd("sm_cmds", Command_HelpMix, "Lists every mix command in chat. (alias)");
	RegConsoleCmd("sm_next", Command_MixLbNext, "Next leaderboard page.");
	RegConsoleCmd("sm_back", Command_MixLbBack, "Previous leaderboard page.");

	g_hNoMixCookie = RegClientCookie("hnsmix_nomix", "1 = player opted out of mixes (!nomix)", CookieAccess_Protected);

	// Late load: restore the saved choice of players already on the server and attach the damage
	// hook OnClientPutInServer would have added, or a reload leaves every connected player unhooked
	// with their fall damage stat frozen at 0.
	for(int i = 1; i <= MaxClients; i++) {
		if(IsClientInGame(i)) {
			LoadNoMixPreference(i);
			if(!IsFakeClient(i)) {
				SDKHook(i, SDKHook_OnTakeDamagePost, OnTakeDamagePost_Mix);
			}
		}
	}

	// Only one synchronizer here. Source exposes six HUD channels total and
	// SourceMod hands them out per sync object, so an unused one is a channel
	// taken from MHUD and everything else that draws.
	g_HudSyncMatchIsLive = CreateHudSynchronizer();

	HookEvent("round_end", EventRoundEndPre, EventHookMode_Pre);
	HookEvent("round_end", EventRoundEnd, EventHookMode_Post);
	HookEvent("round_start", EventRoundStart, EventHookMode_Pre);
	HookEvent("player_connect_full", EventPlayerConnectFull, EventHookMode_Post);
	HookEvent("player_death", EventPlayerDeath, EventHookMode_Post);
	HookEvent("player_hurt", EventPlayerHurt_Mix, EventHookMode_Post);
	HookEvent("player_spawn", EventPlayerSpawn_Mix, EventHookMode_Post);
	HookEvent("player_team", EventPlayerTeam_Mix, EventHookMode_Post);

	AddCommandListener(CommandList_JoinTeam, "jointeam");

	// Captures bare chat words: "votemix" starts a mix vote, and "next"/
	// "back" page a recently viewed leaderboard. Everything else passes
	// through as normal chat.
	AddCommandListener(ChatListener_MixWords, "say");
	AddCommandListener(ChatListener_MixWords, "say_team");
	g_alPlayers[__TEAM_CT] = new ArrayList(sizeof(Player_t));
	g_alPlayers[__TEAM_T] = new ArrayList(sizeof(Player_t));
	g_alDcPlayers = new ArrayList(sizeof(DcPlayer_t));
	g_alMixSwaps = new ArrayList(ByteCountToCells(320));
	g_alSurrenderVoteStarts = new ArrayList(ByteCountToCells(32));
	g_alFrozenNades = new ArrayList(7);
	g_alPausedInfernos = new ArrayList(4);
	g_alPausedSmokes = new ArrayList(4);

	g_iCTCaptain = -1;
	g_iTCaptain = -1;
	g_gameState = eGameState_None;

	Stop1v1();
}

bool IsMixActive() {
	return (g_Init || g_1v1Ticker != null || g_iMixSetupStage != MIX_STAGE_NONE || g_gameState != eGameState_None || g_bAwaitingCaptains);
}

public void OnChatPrefixChanged(ConVar convar, const char[] oldValue, const char[] newValue) {
	strcopy(g_sChatPrefix, sizeof(g_sChatPrefix), newValue);
}

// All regular mix chat and scoreboard headers use this path, so the [PREFIX]
// comes from hnsmix_chat_prefix in one place.
void EmitMixChat(int client, bool bPrefix, const char[] sMsg, bool bBroadcastStyle = false) {
	if(client < 1 || client > MaxClients || !IsClientInGame(client) || IsFakeClient(client)) {
		return;
	}

	if(bPrefix) {
		if(bBroadcastStyle) {
			PrintToChat(client, " \x0F[%s]\x08 %s", g_sChatPrefix, sMsg);
		}
		else {
			PrintToChat(client, " \x01[\x07%s\x01]\x08 %s", g_sChatPrefix, sMsg);
		}
	}
	else {
		PrintToChat(client, " %s", sMsg);
	}
}

void MixPrintToChat(int client, const char[] format, any ...) {
	char sMsg[192];
	SetGlobalTransTarget(client);
	VFormat(sMsg, sizeof(sMsg), format, 3);
	EmitMixChat(client, true, sMsg);
}

void MixPrintToChatAll(const char[] format, any ...) {
	char sMsg[192];
	for(int i = 1; i <= MaxClients; i++) {
		if(!IsClientInGame(i) || IsFakeClient(i)) {
			continue;
		}
		SetGlobalTransTarget(i);
		VFormat(sMsg, sizeof(sMsg), format, 2);
		EmitMixChat(i, true, sMsg, true);
	}
}

public Action EventPlayerConnectFull(Event event, const char[] name, bool bDontBroadcast) {
	int client = GetClientOfUserId(event.GetInt("userid"));

	if (client < 1 || !IsMixActive()) {
		return Plugin_Continue;
	}

	// A mix player reconnecting mid-match gets their roster spot back - unless
	// their captain replaced them meanwhile, which locks them to spectator for
	// the rest of this mix.
	if(g_Init && !g_baDcCheckDone[client] && TryHandleReturningMixPlayer(client)) {
		return Plugin_Continue; // being seated back - skip the spectator move
	}

	// Mid-pick joiners become pickable - repaint menus a frame later.
	if(g_gameState == eGameState_PickingPlayers) {
		RequestFrame(Frame_RefreshPickPhase, 0);
	}

	// Only force joiners to spectator while a mix is being set up or running,
	// so normal play keeps the regular team-select menu.
	if(!cv_ConnectSpec.BoolValue) {
		return Plugin_Continue;
	}
	SetEntPropFloat(client, Prop_Send, "m_fForceTeam", 0.0);

	// Move the player to the desired team on the next game frame
	RequestFrame(Utils_MoveClientToSpec, GetClientUserId(client));
	return Plugin_Continue;
}

// Matches a connecting client against the disconnect list. True only when they are being seated
// back onto their team; replaced or surrendered matches are messaged but still go to spectator.
// Retried from OnClientPostAdminCheck when auth was not ready.
bool TryHandleReturningMixPlayer(int client) {
	if(g_alDcPlayers == null || g_alDcPlayers.Length == 0) {
		return false;
	}

	char sAuth[32];
	if(!GetClientAuthCached(client, sAuth, sizeof(sAuth))) {
		return false; // auth not ready yet - OnClientPostAdminCheck retries
	}
	g_baDcCheckDone[client] = true;

	int idx = FindDcEntryByAuth(sAuth);
	if(idx == -1) {
		return false;
	}

	DcPlayer_t dc;
	g_alDcPlayers.GetArray(idx, dc, sizeof(DcPlayer_t));

	if(dc.bReplaced) {
		g_baReplacedSpectator[client] = true;
		MixPrintToChat(client, "You were replaced while disconnected - you're a spectator until this MIX ends.");
		return false;
	}

	bool bSameRound = (dc.iLeftRound == g_iRoundSerial && !g_bBetweenRounds);

	g_iaPendingSeatTeam[client] = dc.iRosterTeam;
	// Died this round and it's still that round: they come back dead, not
	// with a free respawn.
	g_baPendingSeatDead[client] = (dc.bDeadWhenLeft && bSameRound);
	// Alive when they left and still the same round: back to their old spot
	// with their old health. A new round means a fresh spawn instead.
	g_baPendingSeatSpot[client] = (dc.bHasSpot && bSameRound);
	g_iaPendingSeatHealth[client] = (bSameRound && !dc.bDeadWhenLeft) ? dc.iHealth : 0;
	g_iaPendingSeatRound[client] = g_iRoundSerial;
	if(g_baPendingSeatSpot[client]) {
		for(int i = 0; i < 3; i++) {
			g_faPendingSeatPos[client][i] = dc.faPos[i];
			g_faPendingSeatAng[client][i] = dc.faAng[i];
		}
	}
	g_alDcPlayers.Erase(idx);
	RequestFrame(Frame_SeatReturningPlayer, GetClientUserId(client));
	return true;
}

bool GetClientAuthCached(int client, char[] sBuffer, int iMaxLen) {
	if(g_saClientAuth[client][0] != '\0') {
		strcopy(sBuffer, iMaxLen, g_saClientAuth[client]);
		return true;
	}
	if(GetClientAuthId(client, AuthId_Steam2, sBuffer, iMaxLen)) {
		strcopy(g_saClientAuth[client], sizeof(g_saClientAuth[]), sBuffer);
		return true;
	}
	return false;
}

// Put a player back onto their roster team. They always land DEAD first: a respawn in the same
// frame a client finished connecting fails silently, so players who deserve their life back get
// it via Timer_FinishSeatRespawn - respawn, teleport to their old spot, then old health.
void SeatRosterPlayer(int client, int iRosterTeam, bool bSeatDead) {
	Player_t player;
	player.clientIdx = client;
	g_alPlayers[(iRosterTeam == CS_TEAM_CT) ? __TEAM_CT : __TEAM_T].PushArray(player, sizeof(Player_t));

	ChangeClientTeam(client, GetInGameTeamFor(iRosterTeam)); // joins dead

	if(bSeatDead) {
		g_baDeadThisRound[client] = true; // still the round they died in
	}
}

public Action Timer_FinishSeatRespawn(Handle timer, any userid) {
	int client = GetClientOfUserId(userid);
	if(client < 1 || !g_Init || !IsClientInGame(client) || GetClientTeam(client) < CS_TEAM_T) {
		return Plugin_Stop;
	}

	// The round moved on while this seat was in flight: the engine's fresh
	// spawn is the correct one - a stale teleport would drop them mid-air at
	// LAST round's position with last round's health.
	if(g_iaPendingSeatRound[client] != g_iRoundSerial || g_bBetweenRounds) {
		g_baPendingSeatSpot[client] = false;
		g_iaPendingSeatHealth[client] = 0;
	}

	if(!IsPlayerAlive(client)) {
		if(g_iaSeatRespawnTries[client]++ >= 6) {
			// Give up - they spawn next round like anyone else.
			g_baPendingSeatSpot[client] = false;
			g_iaPendingSeatHealth[client] = 0;
			return Plugin_Stop;
		}
		g_baAuthorizedSpawn[client] = true;
		CS_RespawnPlayer(client);
		return Plugin_Continue; // verify on the next tick, retry if needed
	}

	// Alive: put them back where - and how healthy - they were.
	if(g_baPendingSeatSpot[client]) {
		float faNoVel[3];
		TeleportEntity(client, g_faPendingSeatPos[client], g_faPendingSeatAng[client], faNoVel);
	}
	if(g_iaPendingSeatHealth[client] > 0) {
		SetEntityHealth(client, g_iaPendingSeatHealth[client]);
		g_iaLastKnownHealth[client] = g_iaPendingSeatHealth[client];
	}
	g_baPendingSeatSpot[client] = false;
	g_iaPendingSeatHealth[client] = 0;
	return Plugin_Stop;
}

// One frame after full connect: put the returning player back on their roster
// team, alive (MovePlayerToTeam respawns with the authorized-spawn pass). If
// the match is still paused they freeze in place with everyone else.
void Frame_SeatReturningPlayer(int userid) {
	int client = GetClientOfUserId(userid);
	if(client < 1 || !g_Init || !IsClientInGame(client)) {
		return;
	}

	int iRosterTeam = g_iaPendingSeatTeam[client];
	bool bSeatDead = g_baPendingSeatDead[client];
	g_iaPendingSeatTeam[client] = 0;
	g_baPendingSeatDead[client] = false;
	if(iRosterTeam != CS_TEAM_CT && iRosterTeam != CS_TEAM_T) {
		return;
	}

	SeatRosterPlayer(client, iRosterTeam, bSeatDead);

	// Alive when they left: respawn shortly (same-frame respawns fail for
	// just-connected clients), then restore their spot and health.
	if(!bSeatDead) {
		g_iaSeatRespawnTries[client] = 0;
		CreateTimer(0.5, Timer_FinishSeatRespawn, userid, TIMER_REPEAT | TIMER_FLAG_NO_MAPCHANGE);
	}
	else {
		g_baPendingSeatSpot[client] = false;
		g_iaPendingSeatHealth[client] = 0;
	}

	// If this was the player a 1v1 wait was holding for, the wait is over and
	// the match resumes on its own - they're back exactly where they stood,
	// so there is nothing left to wait for.
	bool bWasWaitedFor = false;
	if(g_hDcWaitTimer != null) {
		char sAuth[32];
		if(GetClientAuthCached(client, sAuth, sizeof(sAuth)) && StrEqual(sAuth, g_sDcWaitAuth)) {
			CancelDcWait();
			bWasWaitedFor = true;
		}
	}

	if(bWasWaitedFor && g_bMatchPaused && g_iUnpauseCountdown == 0) {
		MixPrintToChatAll("\x0F%N\x08 reconnected and got their %s spot back - resuming!", client, iRosterTeam == CS_TEAM_CT ? MIX_TEAM2_CHAT : MIX_TEAM1_CHAT);
		DoMatchUnpause(client);
	}
	else if(g_bMatchPaused) {
		MixPrintToChatAll("\x0F%N\x08 reconnected and got their %s spot back - \x0F!unpause\x08 when ready!", client, iRosterTeam == CS_TEAM_CT ? MIX_TEAM2_CHAT : MIX_TEAM1_CHAT);
	}
	else {
		MixPrintToChatAll("\x0F%N\x08 reconnected and got their %s spot back.", client, iRosterTeam == CS_TEAM_CT ? MIX_TEAM2_CHAT : MIX_TEAM1_CHAT);
	}

	// Anyone still holding the disconnect menu for this player gets it
	// refreshed - with the entry resolved it degrades to a plain
	// "Unpause Mix", so nobody acts on a stale "short-handed" menu.
	char sSeatedAuth[32];
	if(GetClientAuthCached(client, sSeatedAuth, sizeof(sSeatedAuth))) {
		for(int i = 1; i <= MaxClients; i++) {
			if(i != client && g_baDcMenuOpen[i] && IsClientInGame(i) && !IsFakeClient(i)
			&& StrEqual(g_saDcMenuAuth[i], sSeatedAuth)) {
				OpenDcReplaceMenu(i, sSeatedAuth);
			}
		}
	}
}

stock void Utils_MoveClientToSpec(int userid) {
	int client = GetClientOfUserId(userid);
	// Note this will only move to CT or T; To move to spectator use ChangeClientTeam()
	ChangeClientTeam(client, CS_TEAM_SPECTATOR);
}

public Action CommandList_JoinTeam(int client, const char[] sCommand, int argc) {
	if(argc < 1) {
		return Plugin_Stop;
	}
	
	char sArg[16];
	GetCmdArg(1, sArg, sizeof(sArg));
	int iTeamJoin = StringToInt(sArg);
 
	if(g_1v1Ticker != null) {
		MixPrintToChat(client, "A MIX is currently active, you are not allowed to switch teams.");
		g_baAuthorizedSpecMove[client] = true;
		ChangeClientTeam(client, CS_TEAM_SPECTATOR);
		return Plugin_Stop;
	}

	if(g_gameState == eGameState_PickingPlayers || g_gameState == eGameState_DonePickingPlayers) {
		MixPrintToChat(client, "Teams are being picked, you are not allowed to switch teams.");
		return Plugin_Stop;
	}

	if(g_IsTeamsLocked) {
		MixPrintToChat(client, "Teams are currently locked, you aren't allowed to switch teams.");
		return Plugin_Stop;
	}

	if(IsMixActive() && iTeamJoin != CS_TEAM_SPECTATOR) {
		MixPrintToChat(client, "A MIX is being set up, you can't join a team.");
		return Plugin_Stop;
	}

	return Plugin_Continue;
}

public void OnClientPutInServer(int client) {
	// Client indexes are recycled: a pending self-reset confirmation must not
	// carry over to whoever takes the slot next.
	g_faSelfResetConfirmAt[client] = 0.0;

	RequestMixStatusRefresh(); // player count changed
	LoadNoMixPreference(client);
	g_baAuthorizedSpawn[client] = false;
	g_baAuthorizedSpecMove[client] = false;
	g_faLastDeathTime[client] = 0.0;
	g_baDeadThisRound[client] = false;
	g_baReplacedSpectator[client] = false;
	g_iaPendingSeatTeam[client] = 0;
	g_baPendingSeatDead[client] = false;
	g_baPendingSeatSpot[client] = false;
	g_iaPendingSeatHealth[client] = 0;
	g_iaSeatRespawnTries[client] = 0;
	g_iaLastKnownHealth[client] = 0;
	g_baDcWaitMenuOpen[client] = false;
	g_baDcMenuOpen[client] = false;
	g_baDcCheckDone[client] = false;
	g_faNextLbQuery[client] = 0.0;
	g_faLbSessionEnd[client] = 0.0;
	delete g_alLbChatQueue[client]; // a leftover drain timer self-stops
	g_haLbChatTimer[client] = null;
	g_iaSelfOfferFrom[client] = 0;
	g_baSelfOfferMenuOpen[client] = false;
	g_baSelfReplaceActive[client] = false;
	g_iaSelfReplacePending[client] = 0;
	g_baSelfWaitPanelOpen[client] = false;
	g_haSelfReplaceTimeout[client] = null; // callback resolves by userid; a stale slot handle is inert
	g_iaElo[client] = MIX_DEFAULT_ELO; // real rating loads async post-admin-check
	g_iaEloRank[client] = 0;
	g_faResetConfirmAt[client] = 0.0; // a recycled slot must not inherit a pending wipe
	g_saEloTag[client][0] = '\0'; // fresh slot: force the next tag push through
	// Push again now the client is fully in game. OnClientPostAdminCheck fires BEFORE this, so a fast
	// elo query can have pushed a prefix that something else then cleared, with nothing to re-push
	// it - the player spent the session on their own Steam clan tag.
	RefreshEloTag(client);
	g_faInhSurvival[client] = 0.0;
	g_iaInhStabsGiven[client] = 0;
	g_iaInhStabsTaken[client] = 0;
	g_iaInhFallDamage[client] = 0;
	g_iaInhClutches[client] = 0;
	g_iaInhTRounds[client] = 0;

	// Fresh slot: never inherit the previous occupant's mix stats.
	g_iaMixStabsGiven[client] = 0;
	g_iaMixStabsTaken[client] = 0;
	g_iaMixFallDamage[client] = 0;
	g_iaMixClutches[client] = 0;
	g_iaMixTRounds[client] = 0;

	SDKHook(client, SDKHook_OnTakeDamagePost, OnTakeDamagePost_Mix);

	// Fresh slot: never inherit the previous occupant's auth; cache this
	// client's if it's already available (post-admin-check refreshes it).
	g_saClientAuth[client][0] = '\0';
	GetClientAuthId(client, AuthId_Steam2, g_saClientAuth[client], sizeof(g_saClientAuth[]));
}

// Steam auth is guaranteed by now - cache it, and give the returning-mix-
// player check a second chance if it couldn't run at connect time.
public void OnClientPostAdminCheck(int client) {
	GetClientAuthId(client, AuthId_Steam2, g_saClientAuth[client], sizeof(g_saClientAuth[]));

	LoadClientElo(client);

	if(g_Init && !g_baDcCheckDone[client]) {
		TryHandleReturningMixPlayer(client);
	}
}

public void OnClientCookiesCached(int client) {
	LoadNoMixPreference(client);
}

// Default is "wants to play"; the saved !nomix choice overrides it once the
// client's cookies arrive (OnClientCookiesCached re-runs this at that point).
void LoadNoMixPreference(int client) {
	g_bWantsToPlay[client] = true;

	if(g_hNoMixCookie != null && AreClientCookiesCached(client)) {
		char sVal[8];
		GetClientCookie(client, g_hNoMixCookie, sVal, sizeof(sVal));
		if(StrEqual(sVal, "1")) {
			g_bWantsToPlay[client] = false;
		}
	}
}

public void OnPluginEnd() {
	// Unloaded mid-mix: bank the accumulators first. Each queued threaded query holds its own
	// database reference, so the INSERTs complete even as the plugin goes away. A knife round has
	// nothing worth banking.
	if(g_Init && g_iKnifeStage == KNIFE_NONE) {
		FlushAllMixStats(-1, true);
		LogMessage("[MIX] Plugin unloaded mid-mix - banked the mix stats without a result.");
	}
	g_Init = false;

	ClearAllHuds();

	g_iCTCaptain = -1;
	g_iTCaptain = -1;
	g_gameState = eGameState_None;
	SetHnsCountdownSuppressed(false);

	delete g_alPlayers[__TEAM_CT];
	delete g_alPlayers[__TEAM_T];
	delete g_pSurvivalPanel;
}

public Action Command_StopMix(int client, int args) {
	if(client == 0) {
		ReplyToCommand(client, "[%s] This command must be used in-game.", g_sChatPrefix);
		return Plugin_Handled;
	}

	if(!HasMixMenuAccess(client)) {
		MixPrintToChat(client, "Only admins and captains can stop the MIX.");
		return Plugin_Handled;
	}

	StopMix(client);
	return Plugin_Handled;
}

// !startmix: captains start the match once teams are picked. Admins can also use it to kick
// off a fresh guided setup.
public Action Command_StartMix(int client, int args) {
	if(client == 0) {
		ReplyToCommand(client, "[%s] This command must be used in-game.", g_sChatPrefix);
		return Plugin_Handled;
	}

	if(!HasMixMenuAccess(client)) {
		MixPrintToChat(client, "Only admins and captains can start the MIX.");
		return Plugin_Handled;
	}

	if(g_gameState == eGameState_DonePickingPlayers && CheckCanStart1v1()) {
		StartMatch(client);
		return Plugin_Handled;
	}

	if(HasMixAdminAccess(client)) {
		BeginMixSetup(client);
	}
	else {
		MixPrintToChat(client, "Teams are not ready yet.");
	}
	return Plugin_Handled;
}

public Action Command_ReplacePlayer(int client, int args) {
	if(!IsClientCaptain(client)) {
		// Non-captain roster players in a live mix get the self-replace flow.
		if(client >= 1 && g_Init && (IsPlayerInTeam(client, CS_TEAM_CT) || IsPlayerInTeam(client, CS_TEAM_T))) {
			OpenSelfReplaceMenu(client);
			return Plugin_Handled;
		}
		MixPrintToChat(client, "You are not a captain.");
		return Plugin_Handled;
	}

	if(args < 2) {
		MixPrintToChat(client, "Usage: \x0F!replace <your picked player> <spectator>");
		return Plugin_Handled;
	}

	char sArgOld[128]; char sArgNew[128];
	GetCmdArg(1, sArgOld, sizeof(sArgOld));
	GetCmdArg(2, sArgNew, sizeof(sArgNew));

	int oldPlayer = FindPlayerByName(sArgOld);
	if(oldPlayer == -2) {
		MixPrintToChat(client, "Multiple players match \x0F%s\x08, be more specific.", sArgOld);
		return Plugin_Handled;
	}
	if(oldPlayer == -1) {
		MixPrintToChat(client, "Could not find a player matching \x0F%s\x08.", sArgOld);
		return Plugin_Handled;
	}

	int newPlayer = FindPlayerByName(sArgNew);
	if(newPlayer == -2) {
		MixPrintToChat(client, "Multiple players match \x0F%s\x08, be more specific.", sArgNew);
		return Plugin_Handled;
	}
	if(newPlayer == -1) {
		MixPrintToChat(client, "Could not find a player matching \x0F%s\x08.", sArgNew);
		return Plugin_Handled;
	}

	if(IsClientCaptain(oldPlayer) || IsClientCaptain(newPlayer)) {
		MixPrintToChat(client, "Captains cannot be part of a replacement.");
		return Plugin_Handled;
	}

	// The captain's team, based on captaincy rather than current in-game team.
	int iTeam = (g_iCTCaptain == client) ? CS_TEAM_CT : CS_TEAM_T;

	if(!IsPlayerInTeam(oldPlayer, iTeam)) {
		MixPrintToChat(client, "\x0F%N\x08 is not a picked player on your team.", oldPlayer);
		return Plugin_Handled;
	}

	// The replacement must be unpicked - never a picked player from either team.
	if(IsPlayerInTeam(newPlayer, CS_TEAM_CT) || IsPlayerInTeam(newPlayer, CS_TEAM_T)) {
		MixPrintToChat(client, "\x0F%N\x08 has already been picked. Choose a spectator.", newPlayer);
		return Plugin_Handled;
	}

	if(!g_bWantsToPlay[newPlayer]) {
		MixPrintToChat(client, "\x0B%N\x08 doesn't want to play.", newPlayer);
		return Plugin_Handled;
	}

	// Players whose own roster spot is still open can't fill someone else's.
	// (Players replaced out of the mix ARE eligible again.)
	if(HasPendingDcEntryClient(newPlayer)) {
		MixPrintToChat(client, "\x0B%N\x08 still has their own spot open and can't be a replacement.", newPlayer);
		return Plugin_Handled;
	}

	if(GetClientTeam(newPlayer) != CS_TEAM_SPECTATOR) {
		MixPrintToChat(client, "\x0B%N\x08 is not spectating. Replacements must come from spectator.", newPlayer);
		return Plugin_Handled;
	}

	PerformReplace(client, oldPlayer, newPlayer, iTeam);
	return Plugin_Handled;
}

void PerformReplace(int actor, int oldPlayer, int newPlayer, int iTeam, bool bSelf = false) {
	// Capture the outgoing player's state BEFORE benching them (the
	// spectator move kills them): mid-round, the replacement inherits it so
	// the swap doesn't change the round - same rules as a DC replacement.
	bool bMidRound = (g_Init && !g_bBetweenRounds);
	bool bOldDeadThisRound = (bMidRound && g_baDeadThisRound[oldPlayer]);
	int iOldHealth = 0;
	float faOldPos[3]; float faOldAng[3];
	if(bMidRound && !bOldDeadThisRound && IsPlayerAlive(oldPlayer)) {
		iOldHealth = GetClientHealth(oldPlayer);
		GetClientAbsOrigin(oldPlayer, faOldPos);
		GetClientEyeAngles(oldPlayer, faOldAng);
	}

	FindAndRemovePlayer(oldPlayer, iTeam);
	g_baAuthorizedSpecMove[oldPlayer] = true; // replaced players leave the roster deliberately
	ChangeClientTeam(oldPlayer, CS_TEAM_SPECTATOR);

	// The replacement sheds any leftover disconnect state of their own (e.g.
	// they were replaced out of this mix earlier and are being seated again).
	ClearDcStateFor(newPlayer);

	Player_t player;
	player.clientIdx = newPlayer;

	int teamIndex = (iTeam == CS_TEAM_CT ? __TEAM_CT : __TEAM_T);
	g_alPlayers[teamIndex].PushArray(player, sizeof(Player_t));

	if(bOldDeadThisRound) {
		// The outgoing player was already dead this round - their stand-in
		// is too, exactly like a reconnecting dead player.
		ChangeClientTeam(newPlayer, GetInGameTeamFor(iTeam)); // joins dead
		g_baDeadThisRound[newPlayer] = true;
	}
	else {
		MovePlayerToTeam(newPlayer, GetInGameTeamFor(iTeam));

		// Mid-round with a living outgoing player: same spot, same health.
		if(iOldHealth > 0) {
			g_iaPendingSeatHealth[newPlayer] = iOldHealth;
			g_baPendingSeatSpot[newPlayer] = true;
			g_iaPendingSeatRound[newPlayer] = g_iRoundSerial;
			for(int i = 0; i < 3; i++) {
				g_faPendingSeatPos[newPlayer][i] = faOldPos[i];
				g_faPendingSeatAng[newPlayer][i] = faOldAng[i];
			}
			g_iaSeatRespawnTries[newPlayer] = 0;
			CreateTimer(0.2, Timer_FinishSeatRespawn, GetClientUserId(newPlayer), TIMER_REPEAT | TIMER_FLAG_NO_MAPCHANGE);
		}
	}

	if(bSelf) {
		MixPrintToChatAll("\x0F%N\x08 gave their spot to \x0F%N\x08 on the %s team. (self-replace)", oldPlayer, newPlayer, iTeam == CS_TEAM_CT ? MIX_TEAM2_CHAT : MIX_TEAM1_CHAT);
	}
	else {
		MixPrintToChatAll("\x0F%N\x08 replaced \x0F%N\x08 with \x0F%N\x08 on the %s team.", actor, oldPlayer, newPlayer, iTeam == CS_TEAM_CT ? MIX_TEAM2_CHAT : MIX_TEAM1_CHAT);

		// A captain-forced replacement keeps their own earned stats: bank
		// them now (self-replace transfers them to the incoming player
		// instead, before this runs).
		if(g_Init) {
			FlushPlayerMixStats(oldPlayer, 0, 0, true);
		}
	}
}

// Self-replace (!replaceme, or !replace for non-captains): a roster player offers their spot to
// a chosen spectator or to all willing ones. The accepted swap goes through PerformReplace, so
// it behaves like any replacement: dead stays dead, alive hands over the exact spot and health.

// Resolution modes for an outstanding offer round.
#define SELFREP_ACCEPTED 0
#define SELFREP_REJECTED 1
#define SELFREP_CANCELLED 2
#define SELFREP_VOID 3      // silent cleanup (disconnect, mix end, map end)

bool IsEligibleReplacementSpec(int client, int requester) {
	return client != requester
		&& client >= 1 && client <= MaxClients
		&& IsClientInGame(client) && !IsFakeClient(client) && !IsClientSourceTV(client)
		&& GetClientTeam(client) == CS_TEAM_SPECTATOR
		&& g_bWantsToPlay[client]
		&& !IsPlayerInTeam(client, CS_TEAM_CT) && !IsPlayerInTeam(client, CS_TEAM_T)
		&& !HasPendingDcEntryClient(client);
}

public Action Command_ReplaceMe(int client, int args) {
	if(client == 0) {
		ReplyToCommand(client, "[%s] This command must be used in-game.", g_sChatPrefix);
		return Plugin_Handled;
	}

	if(!g_Init || (!IsPlayerInTeam(client, CS_TEAM_CT) && !IsPlayerInTeam(client, CS_TEAM_T))) {
		MixPrintToChat(client, "You are not a roster player in a live MIX.");
		return Plugin_Handled;
	}

	if(IsClientCaptain(client)) {
		MixPrintToChat(client, "Captains can't self-replace - use \x0F!replace <picked> <spectator>\x08.");
		return Plugin_Handled;
	}

	OpenSelfReplaceMenu(client);
	return Plugin_Handled;
}

void OpenSelfReplaceMenu(int client) {
	// An offer round is already out - show its status instead of a new menu.
	if(g_baSelfReplaceActive[client]) {
		ShowSelfWaitPanel(client, "Waiting for a spectator to accept...");
		return;
	}

	Menu menu = new Menu(MenuHandler_SelfReplace);
	menu.SetTitle("[%s] Replace yourself:", g_sChatPrefix);
	menu.AddItem("pick", "Pick a spectator");
	menu.AddItem("offer", "Offer my spot to all spectators");
	menu.ExitButton = true;
	menu.Display(client, MENU_TIME_FOREVER);
}

public int MenuHandler_SelfReplace(Menu menu, MenuAction action, int param1, int param2) {
	if(action == MenuAction_Select) {
		char sInfo[8];
		menu.GetItem(param2, sInfo, sizeof(sInfo));

		if(!g_Init || (!IsPlayerInTeam(param1, CS_TEAM_CT) && !IsPlayerInTeam(param1, CS_TEAM_T))) {
			MixPrintToChat(param1, "You are no longer a roster player.");
		}
		else if(StrEqual(sInfo, "pick")) {
			OpenSelfReplaceSpecList(param1);
		}
		else if(StrEqual(sInfo, "offer")) {
			StartSelfReplaceOffer(param1, 0); // 0 = broadcast to all willing specs
		}
	}
	else if(action == MenuAction_End) {
		delete menu;
	}
	return 0;
}

void OpenSelfReplaceSpecList(int client) {
	Menu menu = new Menu(MenuHandler_SelfReplaceSpecList);
	menu.SetTitle("[%s] Choose a spectator to ask:", g_sChatPrefix);

	char sInfo[16], sName[MAX_NAME_LENGTH];
	int iCount = 0;
	for(int i = 1; i <= MaxClients; i++) {
		if(!IsEligibleReplacementSpec(i, client)) {
			continue;
		}
		IntToString(GetClientUserId(i), sInfo, sizeof(sInfo));
		GetClientName(i, sName, sizeof(sName));
		menu.AddItem(sInfo, sName);
		iCount++;
	}

	if(iCount == 0) {
		delete menu;
		MixPrintToChat(client, "No spectators are available to replace you.");
		return;
	}

	menu.ExitBackButton = true;
	menu.Display(client, MENU_TIME_FOREVER);
}

public int MenuHandler_SelfReplaceSpecList(Menu menu, MenuAction action, int param1, int param2) {
	if(action == MenuAction_Select) {
		char sInfo[16];
		menu.GetItem(param2, sInfo, sizeof(sInfo));
		int spec = GetClientOfUserId(StringToInt(sInfo));

		if(!IsEligibleReplacementSpec(spec, param1)) {
			MixPrintToChat(param1, "That spectator is no longer available.");
			OpenSelfReplaceSpecList(param1);
		}
		else {
			StartSelfReplaceOffer(param1, spec);
		}
	}
	else if(action == MenuAction_Cancel && param2 == MenuCancel_ExitBack) {
		OpenSelfReplaceMenu(param1);
	}
	else if(action == MenuAction_End) {
		delete menu;
	}
	return 0;
}

// Sends the offer to one spectator (targetSpec) or to every willing
// spectator (targetSpec = 0), then parks the requester on the Waiting panel.
void StartSelfReplaceOffer(int requester, int targetSpec) {
	if(g_baSelfReplaceActive[requester]) {
		ShowSelfWaitPanel(requester, "Waiting for a spectator to accept...");
		return;
	}

	int iSent = 0;
	for(int i = 1; i <= MaxClients; i++) {
		if(targetSpec != 0 && i != targetSpec) {
			continue;
		}
		if(!IsEligibleReplacementSpec(i, requester)) {
			continue;
		}
		SendSelfReplaceOfferTo(i, requester);
		iSent++;
	}

	if(iSent == 0) {
		MixPrintToChat(requester, "No spectators are available to replace you.");
		return;
	}

	g_baSelfReplaceActive[requester] = true;
	g_iaSelfReplacePending[requester] = iSent;
	g_haSelfReplaceTimeout[requester] = CreateTimer(SELF_REPLACE_TIMEOUT, Timer_SelfReplaceTimeout, GetClientUserId(requester), TIMER_FLAG_NO_MAPCHANGE);

	MixPrintToChat(requester, "Replace offer sent to \x0F%d\x08 spectator%s.", iSent, iSent == 1 ? "" : "s");
	ShowSelfWaitPanel(requester, "Waiting for a spectator to accept...");
}

void SendSelfReplaceOfferTo(int spec, int requester) {
	// This spectator may still hold an unanswered offer from someone else -
	// that older round loses this spectator, so give it its No now instead of
	// leaving it hanging until the timeout.
	int iOldRequester = GetClientOfUserId(g_iaSelfOfferFrom[spec]);
	if(iOldRequester >= 1 && iOldRequester != requester && g_baSelfReplaceActive[iOldRequester]) {
		DecrementSelfReplacePending(iOldRequester);
	}

	g_iaSelfOfferFrom[spec] = GetClientUserId(requester);

	Menu menu = new Menu(MenuHandler_SelfOffer);
	menu.SetTitle("[%s] %N wants YOU to replace them in the mix.\nTake their spot?", g_sChatPrefix, requester);
	menu.AddItem("yes", "Yes");
	menu.AddItem("no", "No");
	menu.ExitButton = true; // exiting is 'no answer', not a rejection - chat yes/no still works
	menu.Display(spec, RoundToCeil(SELF_REPLACE_TIMEOUT));
	g_baSelfOfferMenuOpen[spec] = true;

	MixPrintToChat(spec, "\x0F%N\x08 wants you to \x0Freplace them\x08 in the MIX - answer with the menu or type \x04yes\x08 / \x02no\x08 in chat.", requester);
}

public int MenuHandler_SelfOffer(Menu menu, MenuAction action, int param1, int param2) {
	if(action == MenuAction_Select) {
		g_baSelfOfferMenuOpen[param1] = false;
		char sInfo[8];
		menu.GetItem(param2, sInfo, sizeof(sInfo));
		HandleSelfReplaceAnswer(param1, StrEqual(sInfo, "yes"));
	}
	else if(action == MenuAction_Cancel) {
		// Menu closed without an answer (exit/another menu/timeout): the offer
		// itself stays valid until the round resolves - chat yes/no still counts.
		g_baSelfOfferMenuOpen[param1] = false;
	}
	else if(action == MenuAction_End) {
		delete menu;
	}
	return 0;
}

// A spectator answered (menu or chat). First Yes wins the race - the offer
// round is resolved before the swap runs, so a second Yes in the same frame
// finds the round inactive and does nothing.
void HandleSelfReplaceAnswer(int spec, bool bYes) {
	int requester = GetClientOfUserId(g_iaSelfOfferFrom[spec]);
	g_iaSelfOfferFrom[spec] = 0;
	if(g_baSelfOfferMenuOpen[spec]) {
		g_baSelfOfferMenuOpen[spec] = false;
		CancelClientMenu(spec); // answered via chat while the menu was still up
	}

	if(requester < 1 || !g_baSelfReplaceActive[requester]) {
		return; // round already resolved (someone else was faster, or it expired)
	}

	if(!bYes) {
		MixPrintToChat(spec, "Offer declined.");
		DecrementSelfReplacePending(requester);
		return;
	}

	// The requester must still be a seated roster player.
	if(!g_Init || (!IsPlayerInTeam(requester, CS_TEAM_CT) && !IsPlayerInTeam(requester, CS_TEAM_T))) {
		ResolveSelfReplace(requester, SELFREP_CANCELLED);
		return;
	}

	// The spectator must still be eligible (could have joined a team, gone
	// !nomix, or gotten their own DC spot meanwhile).
	if(!IsEligibleReplacementSpec(spec, requester)) {
		MixPrintToChat(spec, "You can no longer take that spot.");
		DecrementSelfReplacePending(requester);
		return;
	}

	ResolveSelfReplace(requester, SELFREP_ACCEPTED, spec);
}

void DecrementSelfReplacePending(int requester) {
	if(!g_baSelfReplaceActive[requester]) {
		return;
	}
	if(--g_iaSelfReplacePending[requester] <= 0) {
		// Every offered spectator said No - only now is the requester told.
		ResolveSelfReplace(requester, SELFREP_REJECTED);
	}
}

// Ends an offer round: clears every outstanding spectator offer/menu, stops
// the expiry timer, updates the requester's panel and - on accept - runs the
// actual swap through PerformReplace.
void ResolveSelfReplace(int requester, int iMode, int spec = 0) {
	if(!g_baSelfReplaceActive[requester]) {
		return;
	}
	g_baSelfReplaceActive[requester] = false;
	g_iaSelfReplacePending[requester] = 0;

	if(g_haSelfReplaceTimeout[requester] != null) {
		KillTimer(g_haSelfReplaceTimeout[requester]);
		g_haSelfReplaceTimeout[requester] = null;
	}

	// Pull the offer back from every spectator still holding it.
	int uid = GetClientUserId(requester);
	for(int i = 1; i <= MaxClients; i++) {
		if(g_iaSelfOfferFrom[i] != uid) {
			continue;
		}
		g_iaSelfOfferFrom[i] = 0;
		if(g_baSelfOfferMenuOpen[i]) {
			g_baSelfOfferMenuOpen[i] = false;
			if(IsClientInGame(i)) {
				CancelClientMenu(i);
			}
		}
	}

	switch(iMode) {
		case SELFREP_ACCEPTED: {
			ShowSelfWaitPanel(requester, "Accepted!");
			CreateTimer(3.0, Timer_CloseSelfWaitPanel, uid, TIMER_FLAG_NO_MAPCHANGE);
			int iRosterTeam = IsPlayerInTeam(requester, CS_TEAM_CT) ? CS_TEAM_CT : CS_TEAM_T;

			// The replacement carries the leaver's current-mix stats onward
			// (inherited amounts never bank to the replacement's own record),
			// and bailing costs the leaver a flat rating penalty.
			TransferMixStats(requester, spec);
			PerformReplace(requester, requester, spec, iRosterTeam, true);

			char sOutTag[192], sInTag[192];
			BuildMixDiscordNameTagClient(requester, sOutTag, sizeof(sOutTag));
			BuildMixDiscordNameTagClient(spec, sInTag, sizeof(sInTag));
			RecordMixSwap(sOutTag, sInTag);
			// Casual sizes carry no rating stakes, so bailing is free there -
			// and so is bailing during a knife round (nothing counts yet).
			if(!IsCasualMix() && g_iKnifeStage == KNIFE_NONE) {
				ApplyOnlineEloPenalty(requester, ELO_SELFREPLACE_PENALTY, "left via self-replace");
			}
		}
		case SELFREP_REJECTED: {
			ShowSelfWaitPanel(requester, "Rejected");
			MixPrintToChat(requester, "Your replace offer was \x02rejected\x08 - no spectator accepted.");
			CreateTimer(3.0, Timer_CloseSelfWaitPanel, uid, TIMER_FLAG_NO_MAPCHANGE);
		}
		case SELFREP_CANCELLED: {
			MixPrintToChat(requester, "Your replace offer was cancelled.");
			if(g_baSelfWaitPanelOpen[requester]) {
				g_baSelfWaitPanelOpen[requester] = false;
				CancelClientMenu(requester);
			}
		}
		case SELFREP_VOID: {
			// Silent cleanup - the requester is gone or the mix is over.
			if(g_baSelfWaitPanelOpen[requester]) {
				g_baSelfWaitPanelOpen[requester] = false;
				if(IsClientInGame(requester)) {
					CancelClientMenu(requester);
				}
			}
		}
	}
}

public Action Timer_SelfReplaceTimeout(Handle timer, any userid) {
	int requester = GetClientOfUserId(userid);
	if(requester >= 1) {
		g_haSelfReplaceTimeout[requester] = null;
		if(g_baSelfReplaceActive[requester]) {
			// Expired = nobody accepted: same outcome as everyone saying No.
			ResolveSelfReplace(requester, SELFREP_REJECTED);
		}
	}
	return Plugin_Stop;
}

// The requester's status panel. Re-sent (not updated in place) whenever the
// offer state changes: Waiting -> Accepted!/Rejected.
void ShowSelfWaitPanel(int client, const char[] sStatus) {
	char sTitle[64];
	FormatEx(sTitle, sizeof(sTitle), "[%s] Self-Replace", g_sChatPrefix);

	Panel panel = new Panel();
	panel.SetTitle(sTitle);
	panel.DrawText(" ");
	panel.DrawText(sStatus);
	panel.DrawText(" ");
	if(g_baSelfReplaceActive[client]) {
		panel.DrawItem("Cancel offer");
	}
	else {
		panel.DrawItem("Close");
	}
	panel.Send(client, PanelHandler_SelfWait, MENU_TIME_FOREVER);
	delete panel;

	g_baSelfWaitPanelOpen[client] = true;
}

public int PanelHandler_SelfWait(Menu menu, MenuAction action, int param1, int param2) {
	if(action == MenuAction_Select) {
		g_baSelfWaitPanelOpen[param1] = false;
		if(param2 == 1 && g_baSelfReplaceActive[param1]) {
			ResolveSelfReplace(param1, SELFREP_CANCELLED);
		}
	}
	else if(action == MenuAction_Cancel) {
		g_baSelfWaitPanelOpen[param1] = false;
	}
	return 0;
}

public Action Timer_CloseSelfWaitPanel(Handle timer, any userid) {
	int client = GetClientOfUserId(userid);
	if(client >= 1 && g_baSelfWaitPanelOpen[client] && IsClientInGame(client)) {
		g_baSelfWaitPanelOpen[client] = false;
		CancelClientMenu(client);
	}
	return Plugin_Stop;
}

public Action Command_PickPlayer(int client, int args) {
	if(!IsClientCaptain(client)) {
		MixPrintToChat(client, "This command is restricted to captains.");
		return Plugin_Handled;
	}

	if(g_gameState != eGameState_PickingPlayers) {
		MixPrintToChat(client, "Teampicking is not active.");
		return Plugin_Handled;
	}

	if(g_iLastPickedTeam == CS_TEAM_CT) {
		if(client != g_iTCaptain) {
			MixPrintToChat(client, "Wait for your turn.");
			return Plugin_Handled;
		}
		OpenPlayersMenu(g_iTCaptain, CS_TEAM_T);
		return Plugin_Handled;
	}

	if(g_iLastPickedTeam == CS_TEAM_T) {
		if(client != g_iCTCaptain) {
			MixPrintToChat(client, "Wait for your turn.");
			return Plugin_Handled;
		}
		OpenPlayersMenu(g_iCTCaptain, CS_TEAM_CT);
		return Plugin_Handled;
	}
	return Plugin_Handled;
}

public Action Command_Uncaptain(int client, int args) {

	if(IsClientCaptain(client)) {
		RemoveTeamCaptain(client);
		// MixPrintToChat(client, "You are no longer a captain.");

		for(int i = 1; i <= MaxClients; i++) {
			if(!IsClientInGame(i) || i == client) {
				continue;
			}
			MixPrintToChat(i, "\x0F%N\x08 is no longer a captain!", client);
		}
		
		MixPrintToChat(client, "You are no longer a captain.");
		return Plugin_Handled;
	}
	MixPrintToChat(client, "This command is restricted to captains.");

	return Plugin_Handled;
}

public Action Command_Captain(int client, int args) {
	if(args > 0) {
		return Plugin_Handled;
	}

	// !c volunteers a captain while a voted mix is gathering captains, or
	// fills a vacant captain slot during team picking.
	if(g_gameState != eGameState_PickingPlayers && !g_bAwaitingCaptains) {
		MixPrintToChat(client, "Mix team selection is not active.");
		return Plugin_Handled;
	}

	if(IsClientCaptain(client)) {
		MixPrintToChat(client, "You are already a captain.");
		return Plugin_Handled;
	}

	if(!g_bWantsToPlay[client]) {
		MixPrintToChat(client, "You opted out with \x0F!nomix\x08 - type \x0F!yesmix\x08 first.");
		return Plugin_Handled;
	}

	int iCaptainTeam = GetRandomInt(CS_TEAM_T, CS_TEAM_CT);

	if(TeamHasCaptain(iCaptainTeam)) {
		iCaptainTeam = GetOppositeTeam(iCaptainTeam);

		if(TeamHasCaptain(iCaptainTeam)) {
			MixPrintToChat(client, "\x0FSorry! Both teams already have captains.");
			return Plugin_Handled;
		}
	}

	AddTeamCaptain(client, iCaptainTeam);
	return Plugin_Handled;
}

void AddTeamCaptain(int client, int team, bool bAutoContinue = true) {
	// Check CT
	int teamIndex = (team == CS_TEAM_CT ? __TEAM_CT : __TEAM_T);

	Player_t player;
	player.clientIdx = client;
	g_alPlayers[teamIndex].PushArray(player, sizeof(Player_t));

	SetTeamCaptainForTeam(team, client);

	// Captains are deliberately NOT forced onto their side here - they keep playing where they are
	// until the match starts, when SetupTeams and the game restart place everyone. Placing earlier
	// would strand the CT captain in spectator, since hidenseek blocks mid-round CT joins.

	MixPrintToChatAll("\x0F%N\x08 is now the %s captain!", client, team == CS_TEAM_T ? MIX_TEAM1_CHAT : MIX_TEAM2_CHAT);

	if(bAutoContinue) {
		CheckBothTeamsHaveCaptains();
	}
}

void MoveNonCaptainsToSpec() {
	for(int i = 1; i <= MaxClients; i++) {
		if(!IsClientInGame(i) || IsClientCaptain(i) || IsClientSourceTV(i)) {
			continue;
		}
		ChangeClientTeam(i, CS_TEAM_SPECTATOR);
	}
}

bool CheckBothTeamsHaveCaptains() {
	if(g_iTCaptain != -1 && g_iCTCaptain != -1) {
		MoveNonCaptainsToSpec();

		// Voted mix: both volunteers are in - continue with the team size,
		// after which the normal round-time/picking chain takes over.
		if(g_bAwaitingCaptains) {
			g_bAwaitingCaptains = false;
			MixPrintToChatAll("Captains are set! \x0F%N\x08 is choosing the team size.", g_iCTCaptain);
			OpenMixModeMenu(g_iCTCaptain);
			return true;
		}

		if(g_iCurrentPlayerMode > 1) {
			OpenPlayersMenu(g_iCTCaptain, CS_TEAM_CT);
		}
		return true;
	}

	if(g_bAwaitingCaptains) {
		MixPrintToChatAll("One more captain needed - type \x0F!c\x08 to volunteer!");
	}
	return false;
}

int GetOppositeTeam(int iTeam) {
	return iTeam == CS_TEAM_T ? CS_TEAM_CT : CS_TEAM_T;
}

// Resolve which in-game side a roster team is playing on. hidenseek.sp swaps the actual teams on
// CT wins, including during picking, so placements anchor on the captain's live team rather
// than the raw CS_TEAM_* constants.
int GetInGameTeamFor(int rosterTeam) {
	// Flag is false outside a live match, except StartMatch pre-loads it with
	// the teams-knife side choice so the match-start seating honors it.
	return g_bDidSwitchTeams ? GetOppositeTeam(rosterTeam) : rosterTeam;
}

bool TeamHasCaptain(int team) {

	if(team == CS_TEAM_CT) {
		return g_iCTCaptain != -1;
	}
	else if(team == CS_TEAM_T) {
		return g_iTCaptain != -1;
	}
	return false;
}

bool IsClientCaptain(int client) {
	return (g_iCTCaptain == client || g_iTCaptain == client);
}

bool RemoveTeamCaptain(int client) {
	if(g_iCTCaptain == client) {
		g_iCTCaptain = -1;
		return true;
	}

	if(g_iTCaptain == client) {
		g_iTCaptain = -1;
		return true;
	}
	return false;
}

bool SetTeamCaptainForTeam(int team, int client) {
	if(team == CS_TEAM_CT) {
		g_iCTCaptain = client;
		return true;
	}
	
	if(team == CS_TEAM_T) {
		g_iTCaptain = client;
		return true;
	} 
	return false;
}

public void OnMapStart() {
	// Without this every map would orphan the standing leaderboard embeds and
	// post a fresh set.
	LoadMixLbMessageIds();
	for(int cat = 0; cat <= MIX_LB_CLUTCHES; cat++) {
		g_saLbLastBody[cat][0] = '\0'; // per-session cache; one redundant edit at most
	}

	// Same idea for the status embed: keep editing the same message across maps.
	LoadMixStatusMessageId();
	g_sStatusLastBody[0] = '\0'; // map changed, so the body has too
	RestartMixStatusTimer();

	g_iCTCaptain = -1;
	g_iTCaptain = -1;
	g_iLastWinningTeam = -1;
	g_gameState = eGameState_None;
	g_Init = false;

	g_hDcWaitTimer = null;        // TIMER_FLAG_NO_MAPCHANGE: already dead with the old map
	g_hSurrenderVoteTimer = null; // same
	g_bWinCondsSuspended = false; // the map change re-executes configs anyway
	CancelDcWait();
	EndSurrenderVote(false);
	g_faSurrenderNextVote[__TEAM_T] = 0.0;
	g_faSurrenderNextVote[__TEAM_CT] = 0.0;
	if(g_alDcPlayers != null) {
		g_alDcPlayers.Clear();
	}
	if(g_alMixSwaps != null) {
		g_alMixSwaps.Clear();
	}
	if(g_alSurrenderVoteStarts != null) {
		g_alSurrenderVoteStarts.Clear();
	}
	for(int i = 1; i <= MaxClients; i++) {
		g_baReplacedSpectator[i] = false;
		g_iaPendingSeatTeam[i] = 0;
		g_baPendingSeatDead[i] = false;
		g_baPendingSeatSpot[i] = false;
		g_iaPendingSeatHealth[i] = 0;
		g_iaSelfOfferFrom[i] = 0;
		g_baSelfOfferMenuOpen[i] = false;
		g_baSelfReplaceActive[i] = false;
		g_iaSelfReplacePending[i] = 0;
		g_baSelfWaitPanelOpen[i] = false;
		g_haSelfReplaceTimeout[i] = null; // TIMER_FLAG_NO_MAPCHANGE: already dead across maps
	}

	for(int i = 1; i <= MaxClients; i++) {
		if(!IsClientInGame(i)) {
			continue;
		}
		LoadNoMixPreference(i);
		// A client who rode the map change out keeps whatever the per-client reset would have cleared.
		// The drain timer is NO_MAPCHANGE and already dead, but the non-null handle made
		// LbChatFlushQueue early-return forever, so that player got no leaderboard chat all session.
		delete g_alLbChatQueue[i];
		g_haLbChatTimer[i] = null;
	}

	g_iMixSetupAdmin = -1;
	g_iMixSetupStage = MIX_STAGE_NONE;
	g_fMixRoundTime = 0.0;
	g_iModeMenuClient = -1;
	g_bVotedMix = false;
	g_bAwaitingCaptains = false;

	Stop1v1();

	g_IsMapChanging = false;
	delete g_pSurvivalPanel;
}

public void OnMapEnd() {
	// A mix still live at map end would lose every accumulator, so bank everything now without a
	// result. The queued threaded queries finish on SourceMod's DB thread through the changelevel.
	// A mix that ended normally already flushed in Stop1v1, so nothing double-counts.
	if(g_Init && g_iKnifeStage == KNIFE_NONE) {
		FlushAllMixStats(-1, true);
		LogMessage("[MIX] Map ended mid-mix - banked the mix stats without a result.");
	}
	g_Init = false;

	g_iCTCaptain = -1;
	g_iTCaptain = -1;
	g_iLastWinningTeam = -1;
	g_gameState = eGameState_None;

	for(int i = 1; i <= MaxClients; i++) {
		if(!IsClientInGame(i)) {
			continue;
		}
		LoadNoMixPreference(i);
	}

	g_IsMapChanging = true;
	g_1v1Ticker = null;
	g_hPauseTimer = null;
	g_hKnifeSideTimer = null; // TIMER_FLAG_NO_MAPCHANGE: already dead
	g_bEnginePaused = false;
	g_bMatchPaused = false;
	g_iUnpauseCountdown = 0;
	g_bQueuedMatchmakingSet = false;
	delete g_pSurvivalPanel;
}

public APLRes AskPluginLoad2(Handle myself, bool late, char[] error, int err_max) {
	// General community stuff
	CreateNative("kev_isMatchRunning", Native_isMatchRunning);
	CreateNative("kev_isMixActive", Native_isMixActive);
	// KevFJ calls this when funjump toggles. The status embed is event-driven
	// and FJ is not one of its events, so without the nudge the color would sit
	// stale until the next safety-net refresh (hnsmix_status_interval, 90s).
	CreateNative("kev_refreshMixStatus", Native_RefreshMixStatus);

	// HexTags is optional - without it the elo tag is simply not shown.
	MarkNativeAsOptional("HexTags_SetClientPrefix");
	MarkNativeAsOptional("HNS_IsOvaActive");
	MarkNativeAsOptional("kev_isFJActive");

	return APLRes_Success;
}

public void OnAllPluginsLoaded() {
	RefreshAllEloTags();
}

public void OnLibraryAdded(const char[] name) {
	// HexTags loaded after us (or reloaded): re-push every elo tag.
	if(StrEqual(name, "hextags")) {
		RefreshAllEloTags();
	}
}

public int Native_isMatchRunning(Handle plugin, int numParams) {
	return g_Init ? 1 : 0;
}

// Like kev_isMatchRunning, but also true during mix setup / team picking, so
// other plugins (e.g. RTV) can avoid disrupting a mix that is being formed.
public int Native_isMixActive(Handle plugin, int numParams) {
	return IsMixActive() ? 1 : 0;
}

// Debounced by RequestMixStatusRefresh, so callers may fire it freely.
public int Native_RefreshMixStatus(Handle plugin, int numParams) {
	RequestMixStatusRefresh();
	return 0;
}

public Action Command_MixMenu(int client, int args) {
	if(client == 0) {
		ReplyToCommand(client, "[%s] This command must be used in-game.", g_sChatPrefix);
		return Plugin_Handled;
	}
	OpenMixMenu(client);
	return Plugin_Handled;
}

public Action Command_Mix(int client, int args) {
	if(client == 0) {
		ReplyToCommand(client, "[%s] This command must be used in-game.", g_sChatPrefix);
		return Plugin_Handled;
	}
	BeginMixSetup(client);
	return Plugin_Handled;
}

void BeginMixSetup(int client) {
	if(g_1v1Ticker != null) {
		MixPrintToChat(client, "A match is currently live. Stop it before setting up a new MIX.");
		return;
	}

	g_alPlayers[__TEAM_T].Clear();
	g_alPlayers[__TEAM_CT].Clear();
	g_iCTCaptain = -1;
	g_iTCaptain = -1;
	g_gameState = eGameState_None;
	g_fMixRoundTime = 0.0;
	ResetKnifeState();

	if(cv_LockTeams.BoolValue) {
		g_IsTeamsLocked = true;
	}

	g_iMixSetupAdmin = client;
	g_iMixSetupStage = MIX_STAGE_CT_CAPTAIN;

	MixPrintToChatAll("\x0F%N\x08 is setting up a MIX!", client);
	AnnounceNoMixPlayers();
	MixPrintToChat(client, "Type the name of the \x0BTeam 2\x08 captain in chat. (or type \x0Fcancel\x08)");
}

public Action OnClientSayCommand(int client, const char[] command, const char[] sArgs) {
	// Knife side pick by chat: the chooser types ct / t (or !ct / !t), any case.
	if(g_bKnifeSidePickPending && client == g_iKnifeSideChooser) {
		char sPick[8];
		strcopy(sPick, sizeof(sPick), sArgs);
		TrimString(sPick);
		if(sPick[0] == '!' || sPick[0] == '/') {
			strcopy(sPick, sizeof(sPick), sPick[1]);
		}
		if(StrEqual(sPick, "ct", false)) {
			ApplyKnifeSidePick(CS_TEAM_CT);
			return Plugin_Handled;
		}
		if(StrEqual(sPick, "t", false)) {
			ApplyKnifeSidePick(CS_TEAM_T);
			return Plugin_Handled;
		}
	}

	// The captain on the clock for !add may type a spectator's name instead of
	// using the menu.
	if(g_bAddActive && client == g_iAddPicker) {
		char sAddName[MAX_NAME_LENGTH];
		strcopy(sAddName, sizeof(sAddName), sArgs);
		TrimString(sAddName);
		if(sAddName[0] == '\0' || sAddName[0] == '!' || sAddName[0] == '/') {
			return Plugin_Continue;
		}

		int addTarget = FindPlayerByName(sAddName);
		if(addTarget == -2) {
			MixPrintToChat(client, "Multiple players match \x0F%s\x08, be more specific.", sAddName);
			return Plugin_Handled;
		}
		if(addTarget == -1 || !IsEligibleReplacement(addTarget)) {
			MixPrintToChat(client, "No addable spectator matches \x0F%s\x08.", sAddName);
			return Plugin_Handled;
		}

		SeatAddedPlayer(client, addTarget);
		return Plugin_Handled;
	}

	if(client != g_iMixSetupAdmin || g_iMixSetupStage == MIX_STAGE_NONE) {
		return Plugin_Continue;
	}

	char sText[MAX_NAME_LENGTH];
	strcopy(sText, sizeof(sText), sArgs);
	TrimString(sText);

	// Let empty messages and chat-trigger commands (!x / /x) pass through untouched.
	if(sText[0] == '\0' || sText[0] == '!' || sText[0] == '/') {
		return Plugin_Continue;
	}

	if(StrEqual(sText, "cancel", false)) {
		g_iMixSetupAdmin = -1;
		g_iMixSetupStage = MIX_STAGE_NONE;
		MixPrintToChatAll("Mix setup cancelled.");
		return Plugin_Handled;
	}

	int target = FindPlayerByName(sText);

	if(target == -2) {
		MixPrintToChat(client, "Multiple players match \x0F%s\x08, be more specific.", sText);
		return Plugin_Handled;
	}

	if(target == -1) {
		MixPrintToChat(client, "No player found matching \x0F%s\x08, try again.", sText);
		return Plugin_Handled;
	}

	if(!g_bWantsToPlay[target]) {
		MixPrintToChat(client, "\x0B%N\x08 doesn't want to play.", target);
		return Plugin_Handled;
	}

	if(g_iMixSetupStage == MIX_STAGE_CT_CAPTAIN) {
		AddTeamCaptain(target, CS_TEAM_CT, false);
		g_iMixSetupStage = MIX_STAGE_T_CAPTAIN;
		MixPrintToChat(client, "Now type the name of the \x10Team 1\x08 captain in chat. (or type \x0Fcancel\x08)");
		return Plugin_Handled;
	}

	if(g_iMixSetupStage == MIX_STAGE_T_CAPTAIN) {
		if(target == g_iCTCaptain) {
			MixPrintToChat(client, "\x0F%N\x08 is already the \x0BTeam 2\x08 captain, pick someone else.", target);
			return Plugin_Handled;
		}

		AddTeamCaptain(target, CS_TEAM_T, false);
		g_iMixSetupStage = MIX_STAGE_NONE;

		if(g_iCTCaptain == -1) {
			// CT captain left between the two picks; start over from stage one.
			g_iMixSetupStage = MIX_STAGE_CT_CAPTAIN;
			MixPrintToChat(client, "The \x0BTeam 2\x08 captain left. Type a new \x0BTeam 2\x08 captain name in chat.");
			return Plugin_Handled;
		}

		MoveNonCaptainsToSpec();
		MixPrintToChatAll("Captains are set! \x0F%N\x08 is choosing the team size.", g_iCTCaptain);
		OpenMixModeMenu(g_iCTCaptain);
		return Plugin_Handled;
	}

	return Plugin_Handled;
}

int FindPlayerByName(const char[] name) {
	char sName[MAX_NAME_LENGTH];
	int found = -1;
	int count = 0;

	for(int i = 1; i <= MaxClients; i++) {
		if(!IsClientInGame(i) || IsFakeClient(i) || IsClientSourceTV(i)) {
			continue;
		}
		GetClientName(i, sName, sizeof(sName));

		if(StrEqual(sName, name, false)) {
			return i;
		}

		if(StrContains(sName, name, false) != -1) {
			found = i;
			count++;
		}
	}

	if(count > 1) {
		return -2;
	}
	return (count == 1) ? found : -1;
}

void OpenMixModeMenu(int client) {
	// Remembered so the menu re-renders live when the willing-player pool
	// changes (!yesmix / !nomix) - grayed-out sizes unlock without reopening.
	g_iModeMenuClient = client;

	Menu menu = new Menu(MenuHandler_MixMode);
	menu.SetTitle("[%s] Choose the team size:", g_sChatPrefix);

	int willing = GetTotalPlayerCount(true);

	char sInfo[8]; char sDisplay[16];
	for(int i = 1; i <= MAX_PLAYERS_IN_1V1_PER_TEAM; i++) {
		IntToString(i, sInfo, sizeof(sInfo));
		FormatEx(sDisplay, sizeof(sDisplay), "%dv%d", i, i);
		menu.AddItem(sInfo, sDisplay, (willing >= i * 2) ? ITEMDRAW_DEFAULT : ITEMDRAW_DISABLED);
	}

	menu.ExitButton = false;
	menu.Display(client, MENU_TIME_FOREVER);
}

public int MenuHandler_MixMode(Menu menu, MenuAction action, int param1, int param2) {
	switch (action) {
		case MenuAction_Select: {
			g_iModeMenuClient = -1; // size chosen - stop live-refreshing
			char sInfo[8];
			menu.GetItem(param2, sInfo, sizeof(sInfo));
			g_iCurrentPlayerMode = StringToInt(sInfo);

			MixPrintToChatAll("Mode set to \x0F%d\x08v\x0F%d\x08.", g_iCurrentPlayerMode, g_iCurrentPlayerMode);
			OpenMixTimeMenu(param1);
		}
		case MenuAction_End: {
			delete menu;
		}
	}
	return 0;
}

void OpenMixTimeMenu(int client) {
	Menu menu = new Menu(MenuHandler_MixTime);
	menu.SetTitle("[%s] Choose the round time:", g_sChatPrefix);

	char sInfo[8]; char sDisplay[24];
	for(int t = 300; t <= 900; t += 100) {
		IntToString(t, sInfo, sizeof(sInfo));
		FormatEx(sDisplay, sizeof(sDisplay), "%d seconds", t);
		menu.AddItem(sInfo, sDisplay);
	}

	menu.ExitButton = false;
	menu.Display(client, MENU_TIME_FOREVER);
}

public int MenuHandler_MixTime(Menu menu, MenuAction action, int param1, int param2) {
	switch (action) {
		case MenuAction_Select: {
			char sInfo[8];
			menu.GetItem(param2, sInfo, sizeof(sInfo));
			g_fMixRoundTime = StringToFloat(sInfo);

			MixPrintToChatAll("Round time set to \x0F%d\x08 seconds.", RoundToNearest(g_fMixRoundTime));

			if(g_iCurrentPlayerMode > 1) {
				if(IsSelectionPhaseEnabled()) {
					// Captains knife 1v1 for the first pick; ConcludeKnifeRound
					// opens the picking phase once it's decided.
					StartKnifeRound(KNIFE_CAPTAINS);
				}
				else {
					// Selection phase off: Team 2's captain picks first.
					BeginPickingPhase(CS_TEAM_CT);
				}
			}
			else {
				g_gameState = eGameState_DonePickingPlayers;
				MixPrintToChatAll("Teams are ready!");
				FinishMixSetup();
			}
		}
		case MenuAction_End: {
			delete menu;
		}
	}
	return 0;
}

void FinishMixSetup() {
	// Picking is over - the live roster panels come down.
	CloseMixRosterPanels();

	// Captains are NOT placed on their sides here: hidenseek blocks joining CT mid-round, so a
	// setup-complete placement would dump the CT captain into spectator until the next round.
	// StartMatch does the real placement.

	// A voted mix has no admin to press Start Mix - start automatically once teams are ready.
	if(g_bVotedMix) {
		g_bVotedMix = false;
		g_iMixSetupAdmin = -1;

		if(CheckCanStart1v1()) {
			MixPrintToChatAll("Teams are ready - starting the MIX!");
			StartMatch(g_iCTCaptain);
		}
		return;
	}

	int iAdmin = g_iMixSetupAdmin;
	g_iMixSetupAdmin = -1;

	if(iAdmin != -1 && IsClientInGame(iAdmin)) {
		MixPrintToChat(iAdmin, "Setup complete! Select \x0FStart Mix\x08 to begin the match.");
		OpenMixMenu(iAdmin);
	}

	// Both captains get the Start Mix panel too - any of the three may
	// begin the match, not just the admin who ran !mix.
	int iaCaptains[2];
	iaCaptains[0] = g_iCTCaptain;
	iaCaptains[1] = g_iTCaptain;
	for(int i = 0; i < sizeof(iaCaptains); i++) {
		int c = iaCaptains[i];
		if(c >= 1 && c != iAdmin && IsClientInGame(c) && !IsFakeClient(c)) {
			MixPrintToChat(c, "Teams are ready! Select \x0FStart Mix\x08 to begin the match.");
			OpenMixMenu(c);
		}
	}
}

public Action Command_VoteMix(int client, int args) {
	if(client == 0) {
		ReplyToCommand(client, "[%s] This command must be used in-game.", g_sChatPrefix);
		return Plugin_Handled;
	}

	if(IsMixActive()) {
		MixPrintToChat(client, "A MIX is already running or being set up.");
		return Plugin_Handled;
	}

	if(IsVoteInProgress()) {
		MixPrintToChat(client, "Another vote is already in progress.");
		return Plugin_Handled;
	}

	// Only players who want to play (not !noplay) count toward a mix vote.
	if(GetTotalPlayerCount(true) < 2) {
		MixPrintToChat(client, "Not enough players to start a MIX vote.");
		return Plugin_Handled;
	}

	Menu menu = new Menu(MenuHandler_VoteMix);
	menu.SetTitle("Start a mix? (from %N)", client);

	menu.AddItem(VOTE_YES, "Yes");
	menu.AddItem(VOTE_NO, "No");

	menu.ExitButton = false;
	menu.DisplayVoteToAll(20);

	MixPrintToChatAll("\x0F%N\x08 started a MIX vote! \x0F%d%%\x08 of all players must vote yes.", client, RoundToNearest(cv_VoteMixPercent.FloatValue * 100.0));
	return Plugin_Handled;
}

// !forcemix - admin shortcut that skips the vote and jumps to the passed-votemix state: captains
// volunteer with !c, then the normal size/time/picking chain runs. Different from !mix, where
// the admin names the captains.
public Action Command_ForceMix(int client, int args) {
	if(client == 0) {
		ReplyToCommand(client, "[%s] This command must be used in-game.", g_sChatPrefix);
		return Plugin_Handled;
	}

	if(IsMixActive()) {
		MixPrintToChat(client, "A MIX is already running or being set up.");
		return Plugin_Handled;
	}

	if(GetTotalPlayerCount(false) < 2) {
		MixPrintToChat(client, "Not enough players to start a MIX.");
		return Plugin_Handled;
	}

	MixPrintToChatAll("\x0F%N\x08 force-started a MIX!", client);
	StartVotedMix();
	return Plugin_Handled;
}

public Action Command_NoMix(int client, int args) {
	if(client == 0) {
		ReplyToCommand(client, "[%s] This command must be used in-game.", g_sChatPrefix);
		return Plugin_Handled;
	}

	if(!g_bWantsToPlay[client]) {
		MixPrintToChat(client, "You are already opted out. Type \x0F!yesmix\x08 to play again.");
		return Plugin_Handled;
	}

	// Players already committed to the current mix can't silently opt out.
	// Only relevant while a mix actually exists - stale roster/captain state
	// from an ended mix must never block opting out.
	if(IsMixActive() && (IsClientCaptain(client) || IsPlayerInTeam(client, CS_TEAM_CT) || IsPlayerInTeam(client, CS_TEAM_T))) {
		MixPrintToChat(client, "You are part of the current MIX. Ask for a \x0F!replace\x08 first.");
		return Plugin_Handled;
	}

	g_bWantsToPlay[client] = false;
	SetClientCookie(client, g_hNoMixCookie, "1");

	MixPrintToChat(client, "You opted out of MIXes - you can't be picked. Type \x0F!yesmix\x08 to play again.");

	// Let everyone (especially the captains) know during an active setup.
	if(g_iMixSetupStage != MIX_STAGE_NONE || g_gameState == eGameState_PickingPlayers) {
		MixPrintToChatAll("\x0F%N\x08 is not participating. (\x0F!nomix\x08)", client);
		RefreshPickingPhaseMenus();
	}

	// The pool shrank - the size menu re-renders so oversized modes gray out.
	if(g_iModeMenuClient != -1 && IsClientInGame(g_iModeMenuClient)) {
		OpenMixModeMenu(g_iModeMenuClient);
	}
	return Plugin_Handled;
}

public Action Command_YesMix(int client, int args) {
	if(client == 0) {
		ReplyToCommand(client, "[%s] This command must be used in-game.", g_sChatPrefix);
		return Plugin_Handled;
	}

	if(g_bWantsToPlay[client]) {
		MixPrintToChat(client, "You are already opted in.");
		return Plugin_Handled;
	}

	g_bWantsToPlay[client] = true;
	SetClientCookie(client, g_hNoMixCookie, "0");

	MixPrintToChat(client, "Welcome back - you can be picked for MIXes again.");

	if(g_iMixSetupStage != MIX_STAGE_NONE || g_gameState == eGameState_PickingPlayers) {
		MixPrintToChatAll("\x0F%N\x08 is participating again. (\x0F!yesmix\x08)", client);
		RefreshPickingPhaseMenus();
	}

	// A captain holding the team-size menu sees larger sizes unlock live.
	if(g_iModeMenuClient != -1 && IsClientInGame(g_iModeMenuClient)) {
		OpenMixModeMenu(g_iModeMenuClient);
	}
	return Plugin_Handled;
}

// !noplay: one command that toggles the !nomix / !yesmix state. Routes to the
// same handlers, so every guard and message stays identical.
public Action Command_NoPlayToggle(int client, int args) {
	if(client == 0) {
		ReplyToCommand(client, "[%s] This command must be used in-game.", g_sChatPrefix);
		return Plugin_Handled;
	}

	if(g_bWantsToPlay[client]) {
		return Command_NoMix(client, args);
	}
	return Command_YesMix(client, args);
}

// Chat list of everyone sitting out via !nomix, shown when picking starts.
void AnnounceNoMixPlayers() {
	char sList[512]; char sName[MAX_NAME_LENGTH];
	int count = 0;

	for(int i = 1; i <= MaxClients; i++) {
		if(!IsClientInGame(i) || IsFakeClient(i) || IsClientSourceTV(i) || g_bWantsToPlay[i]) {
			continue;
		}

		GetClientName(i, sName, sizeof(sName));
		if(count > 0) {
			StrCat(sList, sizeof(sList), "\x08, \x0F");
		}
		StrCat(sList, sizeof(sList), sName);
		count++;
	}

	if(count > 0) {
		MixPrintToChatAll("Not participating (\x0F!nomix\x08): \x0F%s\x08", sList);
	}
}

public int MenuHandler_VoteMix(Menu menu, MenuAction action, int param1, int param2) {
	switch (action) {
		case MenuAction_VoteEnd: {
			int winningVotes, totalVotes;
			GetMenuVoteInfo(param2, winningVotes, totalVotes);

			char sInfo[32];
			menu.GetItem(param1, sInfo, sizeof(sInfo));

			int yesVotes = StrEqual(sInfo, VOTE_YES) ? winningVotes : (totalVotes - winningVotes);
			// Threshold is a fraction of the players who WANT to play - !noplay
			// players are not counted toward the required yes-votes.
			int playerCount = GetTotalPlayerCount(true);

			// A !noplay player could still click yes in the vote panel; clamp so
			// their vote can't push the yes-count past the willing total.
			if(yesVotes > playerCount) {
				yesVotes = playerCount;
			}

			float fPercent = (playerCount > 0) ? (float(yesVotes) / float(playerCount)) : 0.0;

			if(fPercent >= cv_VoteMixPercent.FloatValue) {
				MixPrintToChatAll("Mix vote \x04passed\x08! (%d of %d players)", yesVotes, playerCount);
				StartVotedMix();
			}
			else {
				MixPrintToChatAll("Mix vote \x02failed\x08. (%d of %d players, %d%% needed)", yesVotes, playerCount, RoundToNearest(cv_VoteMixPercent.FloatValue * 100.0));
			}
		}

		case MenuAction_VoteCancel: {
			if(param1 == VoteCancel_NoVotes) {
				MixPrintToChatAll("Mix vote failed. (no votes)");
			}
		}

		case MenuAction_End: {
			delete menu;
		}
	}
	return 0;
}

void StartVotedMix() {
	if(IsMixActive()) {
		return;
	}

	g_alPlayers[__TEAM_T].Clear();
	g_alPlayers[__TEAM_CT].Clear();
	g_iCTCaptain = -1;
	g_iTCaptain = -1;
	g_gameState = eGameState_None;
	g_fMixRoundTime = 0.0;
	ResetKnifeState();

	if(cv_LockTeams.BoolValue) {
		g_IsTeamsLocked = true;
	}

	g_iMixSetupAdmin = -1;
	g_iMixSetupStage = MIX_STAGE_NONE;
	g_bVotedMix = true;

	// No random captains: players volunteer with !c, first come first served.
	g_bAwaitingCaptains = true;
	MixPrintToChatAll("Mix setup has started! Type \x0F!c\x08 to become a captain - \x0F2\x08 captains are needed.");
	AnnounceNoMixPlayers(); // !votemix + !forcemix
}

bool CheckCanStart1v1() {
	bool bHasEnoughCTPlayers = (CountPlayersInTeam(CS_TEAM_CT) == g_iCurrentPlayerMode);
	bool bHasEnoughTPlayers = (CountPlayersInTeam(CS_TEAM_T) == g_iCurrentPlayerMode);

	bool bCTHasCaptain = TeamHasCaptain(CS_TEAM_CT);
	bool bTHasCaptain = TeamHasCaptain(CS_TEAM_T);

	return (bHasEnoughCTPlayers && bHasEnoughTPlayers && bCTHasCaptain && bTHasCaptain);
}

int CountPlayersInTeam(int team) {
	int teamIndex = (team == CS_TEAM_CT ? __TEAM_CT : __TEAM_T);

	if(g_alPlayers[teamIndex] == null) {
		return -1;
	}
	int len = g_alPlayers[teamIndex].Length;

	if(len == 0) {
		return -1;
	}

	int count = 0;

	Player_t player;
	for(int i = 0; i < len; i++) {
		g_alPlayers[teamIndex].GetArray(i, player, sizeof(Player_t));

		if(player.clientIdx != -1) {
			count++;
		}
	}
	return count;
}

stock int GetTotalPlayerCount(bool bWantsToPlay = true) {
	int count = 0;
	for(int i = 1; i <= MaxClients; i++) {
		if(IsClientInGame(i) && IsClientConnected(i) && !IsFakeClient(i)) {
			if(!g_bWantsToPlay[i] && bWantsToPlay) {
				continue;
			}
			count++;
		}
	}
	return count;
}

bool HasMixAdminAccess(int client) {
	// Dedicated override key so admins can grant mix control without also handing
	// out the shared sm_admin menu. Falls back to the hnsmix_admin_flag bits.
	return CheckCommandAccess(client, "hnsmix_admin", g_iMixAdminFlags, false);
}

// Parse hnsmix_admin_flag into a bitmask; empty/invalid falls back to slay.
// bLive is true only on a runtime cvar change (not the initial load, when the
// RegAdminCmd commands do not exist yet).
void RefreshMixAdminFlags(bool bLive = false) {
	char sFlags[16];
	cv_AdminFlag.GetString(sFlags, sizeof(sFlags));
	int bits = ReadFlagString(sFlags);
	g_iMixAdminFlags = (bits != 0) ? bits : ADMFLAG_SLAY;

	// The two RegAdminCmd commands are gated by the engine before their callback, so a runtime flag
	// change needs an admin-access override to take effect. The console and captain commands read
	// g_iMixAdminFlags live. A file entry in admin_overrides.cfg still wins on the next reload.
	if (bLive) {
		AddCommandOverride("sm_mix", Override_Command, g_iMixAdminFlags);
		AddCommandOverride("sm_forcemix", Override_Command, g_iMixAdminFlags);
	}
}

public void OnMixAdminFlagChanged(ConVar cv, const char[] oldVal, const char[] newVal) {
	RefreshMixAdminFlags(true);
}

// The mix menu and match-control commands are open to admins AND the two
// current captains.
bool HasMixMenuAccess(int client) {
	return HasMixAdminAccess(client) || IsClientCaptain(client);
}

void OpenMixMenu(int client) {
	if(!HasMixMenuAccess(client)) {
		MixPrintToChat(client, "You do not have access to this menu.");
		return;
	}

	Menu menu = new Menu(MenuHandler_MixMenu);

	char sTitleBuffer[256];
	FormatEx(sTitleBuffer, sizeof(sTitleBuffer), "[%s Panel]", g_sChatPrefix);
	if(g_iCTCaptain != -1) {
		FormatEx(sTitleBuffer, sizeof(sTitleBuffer), "%s\nCT: %N", sTitleBuffer, g_iCTCaptain);
	}

	if(g_iTCaptain != -1) {
		FormatEx(sTitleBuffer, sizeof(sTitleBuffer), "%s\nT:  %N", sTitleBuffer, g_iTCaptain);
	}

	if(g_iTCaptain != -1 && g_iCTCaptain != -1) {
		FormatEx(sTitleBuffer, sizeof(sTitleBuffer), "%s\n ", sTitleBuffer);
	}

	if(g_iTCaptain == -1 && g_iCTCaptain == -1) {
		FormatEx(sTitleBuffer, sizeof(sTitleBuffer), "%s\nCT: <no captain>\nT:  <no captain>\n ", sTitleBuffer);
	}

	menu.SetTitle(sTitleBuffer);

	bool isGameLive = (g_1v1Ticker != null);
	bool isSettingUp = (g_iMixSetupStage != MIX_STAGE_NONE || g_gameState == eGameState_PickingPlayers);
	bool isReady = (g_gameState == eGameState_DonePickingPlayers && CheckCanStart1v1());

	// 1. Start Mix - begins the guided setup, or starts the match once teams are ready.
	if(isReady && !isGameLive) {
		char sMode[64];
		FormatEx(sMode, sizeof(sMode), "Start Mix (%dv%d)", g_iCurrentPlayerMode, g_iCurrentPlayerMode);
		menu.AddItem("start_mix", sMode);
	}
	else {
		menu.AddItem("start_mix", "Start Mix", (isGameLive || isSettingUp) ? ITEMDRAW_DISABLED : ITEMDRAW_DEFAULT);
	}

	// 2. Stop Mix - cancels a setup in progress or stops a live match.
	bool bAnythingToStop = (isGameLive || isSettingUp || g_gameState != eGameState_None || g_iCTCaptain != -1 || g_iTCaptain != -1);
	menu.AddItem("stop_mix", "Stop Mix", bAnythingToStop ? ITEMDRAW_DEFAULT : ITEMDRAW_DISABLED);

	// 3. Pause / Unpause the live match. While the 5s unpause countdown runs
	// the match is still technically paused - show that state explicitly
	// instead of a misleading "Unpause".
	if(g_bMatchPaused && g_iUnpauseCountdown > 0) {
		menu.AddItem("pause_mix", "Resuming...", ITEMDRAW_DISABLED);
	}
	else {
		menu.AddItem("pause_mix", g_bMatchPaused ? "Unpause Match" : "Pause Match", (isGameLive && g_Init) ? ITEMDRAW_DEFAULT : ITEMDRAW_DISABLED);
	}

	// 3. Replace a picked player with a spectator.
	bool bHasPickedPlayers = ((g_alPlayers[__TEAM_CT] != null && g_alPlayers[__TEAM_CT].Length > 0) || (g_alPlayers[__TEAM_T] != null && g_alPlayers[__TEAM_T].Length > 0));
	menu.AddItem("replace", "Replace Player", bHasPickedPlayers ? ITEMDRAW_DEFAULT : ITEMDRAW_DISABLED);

	// 3. Add Players - grow a live mix by one player per team. Command_AddPlayers
	// re-checks the rest (spectator count, size cap, missing players) and says why.
	menu.AddItem("add", "Add Players", (g_Init && g_iKnifeStage == KNIFE_NONE && !g_bAddActive) ? ITEMDRAW_DEFAULT : ITEMDRAW_DISABLED);

	// 3. Force Add - admins only, one player onto a chosen team. Kept separate
	// from "Add Players" so an admin who is also a captain can't unbalance the
	// match without meaning to.
	menu.AddItem("forceadd", "Force Add Player (admin)", (HasMixAdminAccess(client) && g_Init && g_iKnifeStage == KNIFE_NONE && !g_bAddActive) ? ITEMDRAW_DEFAULT : ITEMDRAW_DISABLED);

	// 3. Team switch lock - admins only.
	menu.AddItem("teams", g_IsTeamsLocked ? "Unlock Team Switch" : "Lock Team Switch", HasMixAdminAccess(client) ? ITEMDRAW_DEFAULT : ITEMDRAW_DISABLED);

	// 4. Spectator tools - admins only; captains never move anyone to spec.
	menu.AddItem("spec", "Move Player(s) to Spec", HasMixAdminAccess(client) ? ITEMDRAW_DEFAULT : ITEMDRAW_DISABLED);

	menu.ExitButton = true;

	menu.Display(client, MENU_TIME_FOREVER);
	// Set AFTER Display: displacing a previous menu fires its Cancel first,
	// which would otherwise clear the flag we just set.
	g_baMixMenuOpen[client] = true;
}

// A menu is a static snapshot, so when the pause state changes - possibly by the OTHER captain -
// everyone holding the panel gets it re-rendered and the labels never go stale. Also slams shut
// every open mix/DC menu when the match starts or resumes.
void CloseAllMixMenus() {
	for(int i = 1; i <= MaxClients; i++) {
		if((g_baMixMenuOpen[i] || g_baDcMenuOpen[i] || g_baDcWaitMenuOpen[i] || g_baRosterPanelOpen[i]) && IsClientInGame(i) && !IsFakeClient(i)) {
			CancelClientMenu(i);
		}
		g_baMixMenuOpen[i] = false;
		g_baDcMenuOpen[i] = false;
		g_baDcWaitMenuOpen[i] = false;
		g_baRosterPanelOpen[i] = false;
	}
}

void RefreshOpenMixMenus() {
	for(int i = 1; i <= MaxClients; i++) {
		if(!g_baMixMenuOpen[i] || !IsClientInGame(i) || IsFakeClient(i)) {
			continue;
		}

		// Lost access since opening it (e.g. the mix ended and they are no
		// longer a captain) - drop the tracking quietly, no denial spam.
		if(!HasMixMenuAccess(i)) {
			g_baMixMenuOpen[i] = false;
			continue;
		}

		OpenMixMenu(i);
	}
}

public int MenuHandler_MixMenu(Menu menu, MenuAction action, int param1, int param2) {
	switch (action) {
		case MenuAction_Cancel: {
			g_baMixMenuOpen[param1] = false;
		}
		case MenuAction_Select: {
			g_baMixMenuOpen[param1] = false; // reopened below where applicable

			if(!HasMixMenuAccess(param1)) {
				MixPrintToChat(param1, "You do not have access to this menu.");
				return 0;
			}

			char sInfo[32];
			menu.GetItem(param2, sInfo, sizeof(sInfo));

			if (StrEqual(sInfo, "start_mix", false)) {
				if(g_gameState == eGameState_DonePickingPlayers && CheckCanStart1v1()) {
					StartMatch(param1);
					OpenMixMenu(param1);
				}
				else if(HasMixAdminAccess(param1)) {
					// Beginning a brand-new guided setup stays admin-only.
					BeginMixSetup(param1);
				}
				else {
					MixPrintToChat(param1, "Teams are not ready yet.");
				}
			}
			else if (StrEqual(sInfo, "stop_mix", false)) {
				StopMix(param1);
				OpenMixMenu(param1);
			}
			else if (StrEqual(sInfo, "pause_mix", false)) {
				if(g_bMatchPaused) {
					DoMatchUnpause(param1);
				}
				else {
					DoMatchPause(param1);
				}
				OpenMixMenu(param1);
			}
			else if (StrEqual(sInfo, "replace", false)) {
				OpenReplaceOldMenu(param1);
			}
			else if (StrEqual(sInfo, "add", false)) {
				Command_AddPlayers(param1, 0);
			}
			else if (StrEqual(sInfo, "teams", false)) {
				if(!HasMixAdminAccess(param1)) {
					MixPrintToChat(param1, "Only admins can toggle team switching.");
					return 0;
				}
				ToggleTeamLock(param1);
				OpenMixMenu(param1);
			}
			else if (StrEqual(sInfo, "spec", false)) {
				if(!HasMixAdminAccess(param1)) {
					MixPrintToChat(param1, "Only admins can move players to spectator.");
					return 0;
				}
				OpenSpecMenu(param1);
			}
			else if (StrEqual(sInfo, "forceadd", false)) {
				Command_ForceAdd(param1, 0);
			}
		}
		case MenuAction_End: {
			delete menu;
		}
	}
	return 0;
}

void StopMix(int client) {
	// Live match: full stop.
	if(g_Init || g_1v1Ticker != null) {
		Stop1v1(client);
		return;
	}

	// Knife bookkeeping dies with the setup.
	ResetKnifeState();

	// No live match: cancel any setup / team selection in progress. Both
	// captains' setup menus (size/time/pick) and the setup admin's menu come
	// down with it - captured before the state below is cleared.
	int iaSetupMenuHolders[3];
	iaSetupMenuHolders[0] = g_iCTCaptain;
	iaSetupMenuHolders[1] = g_iTCaptain;
	iaSetupMenuHolders[2] = g_iMixSetupAdmin;
	for(int i = 0; i < sizeof(iaSetupMenuHolders); i++) {
		int c = iaSetupMenuHolders[i];
		if(c >= 1 && c <= MaxClients && IsClientInGame(c) && !IsFakeClient(c)) {
			CancelClientMenu(c);
		}
	}
	g_iModeMenuClient = -1;

	g_alPlayers[__TEAM_T].Clear();
	g_alPlayers[__TEAM_CT].Clear();

	g_iCTCaptain = -1;
	g_iTCaptain = -1;

	g_iMixSetupAdmin = -1;
	g_iMixSetupStage = MIX_STAGE_NONE;
	g_bVotedMix = false;
	g_bAwaitingCaptains = false;

	g_gameState = eGameState_None;
	g_fMixRoundTime = 0.0;
	g_IsTeamsLocked = false;

	CloseMixRosterPanels();
	MixPrintToChatAll("Mix setup cancelled by \x0F%N\x08.", client);
}

void OpenReplaceOldMenu(int client) {
	Menu menu = new Menu(MenuHandler_ReplaceOld);
	menu.SetTitle("[%s] Choose the picked player to replace:", g_sChatPrefix);

	// Captains only see (and may only replace) their own teammates; admins
	// see both teams.
	int iOnlyTeam = -1;
	if(!HasMixAdminAccess(client) && IsClientCaptain(client)) {
		iOnlyTeam = (g_iCTCaptain == client) ? __TEAM_CT : __TEAM_T;
	}

	char sID[16]; char sBuffer[MAX_NAME_LENGTH+16];

	Player_t player;
	for(int t = 0; t < PLAYER_TEAM_MAX; t++) {
		if(iOnlyTeam != -1 && t != iOnlyTeam) {
			continue;
		}
		for(int i = 0; i < g_alPlayers[t].Length; i++) {
			g_alPlayers[t].GetArray(i, player, sizeof(Player_t));

			int idx = player.clientIdx;
			if(idx < 1 || !IsClientInGame(idx) || IsClientCaptain(idx)) {
				continue;
			}

			IntToString(GetClientUserId(idx), sID, sizeof(sID));
			FormatEx(sBuffer, sizeof(sBuffer), "[%s] %N", (t == __TEAM_CT) ? "Team 2" : "Team 1", idx);
			menu.AddItem(sID, sBuffer);
		}
	}

	if(menu.ItemCount == 0) {
		menu.AddItem("", " :: No Picked Players", ITEMDRAW_DISABLED);
	}

	menu.ExitButton = true;
	menu.Display(client, MENU_TIME_FOREVER);
}

public int MenuHandler_ReplaceOld(Menu menu, MenuAction action, int param1, int param2) {
	switch (action) {
		case MenuAction_Select: {
			if(!HasMixMenuAccess(param1)) {
				MixPrintToChat(param1, "You do not have access to this menu.");
				return 0;
			}

			char sID[16];
			menu.GetItem(param2, sID, sizeof(sID));

			int target = GetClientOfUserId(StringToInt(sID));
			if(target < 1 || (!IsPlayerInTeam(target, CS_TEAM_CT) && !IsPlayerInTeam(target, CS_TEAM_T))) {
				MixPrintToChat(param1, "That player is no longer available.");
				OpenReplaceOldMenu(param1);
				return 0;
			}

			// Captains may only replace their own teammates.
			if(!HasMixAdminAccess(param1) && IsClientCaptain(param1)) {
				int iOwnTeam = (g_iCTCaptain == param1) ? CS_TEAM_CT : CS_TEAM_T;
				if(!IsPlayerInTeam(target, iOwnTeam)) {
					MixPrintToChat(param1, "You can only replace players on your own team.");
					OpenReplaceOldMenu(param1);
					return 0;
				}
			}

			g_iReplaceOldUserId[param1] = StringToInt(sID);
			OpenReplaceNewMenu(param1);
		}
		case MenuAction_End: {
			delete menu;
		}
	}
	return 0;
}

void OpenReplaceNewMenu(int client) {
	Menu menu = new Menu(MenuHandler_ReplaceNew);
	menu.SetTitle("[%s] Choose the replacement (unpicked players):", g_sChatPrefix);

	char sID[16]; char sBuffer[MAX_NAME_LENGTH+8];
	for(int i = 1; i <= MaxClients; i++) {
		if(!IsClientInGame(i) || IsFakeClient(i) || IsClientSourceTV(i) || IsClientCaptain(i)) {
			continue;
		}

		if(IsPlayerInTeam(i, CS_TEAM_CT) || IsPlayerInTeam(i, CS_TEAM_T)) {
			continue;
		}

		// Replacements must be spectators who haven't opted out via !nomix and
		// whose own roster spot isn't still open. (Players replaced out of
		// the mix ARE eligible again.)
		if(!g_bWantsToPlay[i] || HasPendingDcEntryClient(i) || GetClientTeam(i) != CS_TEAM_SPECTATOR) {
			continue;
		}

		IntToString(GetClientUserId(i), sID, sizeof(sID));
		FormatEx(sBuffer, sizeof(sBuffer), "%N", i);
		menu.AddItem(sID, sBuffer);
	}

	if(menu.ItemCount == 0) {
		menu.AddItem("", " :: No Spectators Available", ITEMDRAW_DISABLED);
	}

	menu.ExitButton = true;
	menu.Display(client, MENU_TIME_FOREVER);
}

public int MenuHandler_ReplaceNew(Menu menu, MenuAction action, int param1, int param2) {
	switch (action) {
		case MenuAction_Select: {
			if(!HasMixMenuAccess(param1)) {
				MixPrintToChat(param1, "You do not have access to this menu.");
				return 0;
			}

			char sID[16];
			menu.GetItem(param2, sID, sizeof(sID));

			int oldPlayer = GetClientOfUserId(g_iReplaceOldUserId[param1]);
			int newPlayer = GetClientOfUserId(StringToInt(sID));
			g_iReplaceOldUserId[param1] = 0;

			if(oldPlayer < 1 || newPlayer < 1) {
				MixPrintToChat(param1, "That player is no longer available.");
				OpenMixMenu(param1);
				return 0;
			}

			int iTeam = -1;
			if(IsPlayerInTeam(oldPlayer, CS_TEAM_CT)) {
				iTeam = CS_TEAM_CT;
			}
			else if(IsPlayerInTeam(oldPlayer, CS_TEAM_T)) {
				iTeam = CS_TEAM_T;
			}

			if(iTeam == -1 || IsClientCaptain(newPlayer) || IsPlayerInTeam(newPlayer, CS_TEAM_CT) || IsPlayerInTeam(newPlayer, CS_TEAM_T)
			|| !g_bWantsToPlay[newPlayer] || HasPendingDcEntryClient(newPlayer)
			|| GetClientTeam(newPlayer) != CS_TEAM_SPECTATOR) {
				MixPrintToChat(param1, "That replacement is no longer valid.");
				OpenMixMenu(param1);
				return 0;
			}

			PerformReplace(param1, oldPlayer, newPlayer, iTeam);
			OpenMixMenu(param1);
		}
		case MenuAction_End: {
			delete menu;
		}
	}
	return 0;
}

public void OnClientDisconnect(int client) {
	g_baMixMenuOpen[client] = false;

	if(g_IsMapChanging) {
		return;
	}

	RequestMixStatusRefresh(); // player count and possibly a roster changed
	
	// An add in flight dies with the captain holding it or with anyone it
	// already seated - both leave it unfinishable. Runs before the roster
	// bookkeeping below so a leaving added player never triggers a DC pause.
	if(g_bAddActive) {
		bool bAddInvolved = (client == g_iAddPicker);
		for(int i = 0; i < 2; i++) {
			if(GetClientOfUserId(g_iaAddedUserId[i]) == client) {
				g_iaAddedUserId[i] = 0; // leaving anyway - nothing to un-seat
				bAddInvolved = true;
			}
		}
		if(bAddInvolved) {
			CancelAddPlayers(-1, "a player involved left");
		}
	}

	// Self-replace bookkeeping: a leaver with an outstanding offer round
	// voids it; a leaving spectator who still held an offer counts as a No.
	if(g_baSelfReplaceActive[client]) {
		ResolveSelfReplace(client, SELFREP_VOID);
	}
	if(g_iaSelfOfferFrom[client] != 0) {
		int iSelfReq = GetClientOfUserId(g_iaSelfOfferFrom[client]);
		g_iaSelfOfferFrom[client] = 0;
		g_baSelfOfferMenuOpen[client] = false;
		if(iSelfReq >= 1) {
			DecrementSelfReplacePending(iSelfReq);
		}
	}

	if(client == g_MenuAccess) {
		g_MenuAccess = -1;
	}

	if(client == g_iModeMenuClient) {
		g_iModeMenuClient = -1;
	}

	if(client == g_MenuAccessTo) {
		g_MenuAccessTo = -1;
	}

	if(client == g_iMixSetupAdmin) {
		g_iMixSetupAdmin = -1;
		g_iMixSetupStage = MIX_STAGE_NONE;
		MixPrintToChatAll("Mix setup cancelled. (admin disconnected)");
	}

	// Must run before FindAndRemovePlayer below wipes their roster spot: a
	// mix player dropping mid-match auto-pauses the mix, offers their captain
	// a replacement, and is remembered by SteamID for reconnection.
	if(g_Init) {
		// Captains knife: nothing to replace or wait for in a 1v1 selection
		// round - the captain who stayed simply wins the first pick.
		if(g_iKnifeStage == KNIFE_CAPTAINS) {
			if(IsClientCaptain(client)) {
				int iKnifeWinnerTeam = (g_iCTCaptain == client) ? CS_TEAM_T : CS_TEAM_CT;
				MixPrintToChatAll("\x0F%N\x08 left during the captains' knife round - %s takes it by forfeit!", client, iKnifeWinnerTeam == CS_TEAM_T ? MIX_TEAM1_CHAT : MIX_TEAM2_CHAT);
				ConcludeKnifeRound(iKnifeWinnerTeam);
				if(!g_bBetweenRounds) {
					CS_TerminateRound(1.0, CSRoundEnd_Draw, false);
				}
			}
		}
		else if(IsPlayerInTeam(client, CS_TEAM_CT)) {
			HandleMixPlayerDisconnect(client, CS_TEAM_CT);
		}
		else if(IsPlayerInTeam(client, CS_TEAM_T)) {
			HandleMixPlayerDisconnect(client, CS_TEAM_T);
		}
	}

	// Note a picked leaver's team before the roster spot is wiped below.
	int iPickedLeaveTeam = 0;
	if(g_gameState == eGameState_PickingPlayers && !IsClientCaptain(client)) {
		if(IsPlayerInTeam(client, CS_TEAM_T)) {
			iPickedLeaveTeam = CS_TEAM_T;
		}
		else if(IsPlayerInTeam(client, CS_TEAM_CT)) {
			iPickedLeaveTeam = CS_TEAM_CT;
		}
	}

	if(FindAndRemovePlayer(client, CS_TEAM_T)) {
		PrintToConsoleAll("[%s] You have been removed from Team 1", g_sChatPrefix);
	}

	if(FindAndRemovePlayer(client, CS_TEAM_CT)) {
		PrintToConsoleAll("[%s] You have been removed from Team 2", g_sChatPrefix);
	}

	if(IsClientCaptain(client)) {
		int iCapTeam = (g_iCTCaptain == client) ? CS_TEAM_CT : CS_TEAM_T;
		PrintToConsoleAll("[%s] %N is no longer a captain!", g_sChatPrefix, client);
		RemoveTeamCaptain(client);

		// Live mix: captaincy moves to a teammate immediately and for good. The leaver returns as a
		// normal roster player, replaceable like anyone else, and never regains the flag.
		// GetMixTeamDecider picks the same teammate the disconnect menu opened for.
		if(g_Init) {
			int iNewCaptain = GetMixTeamDecider(iCapTeam, client);
			if(iNewCaptain != -1) {
				SetTeamCaptainForTeam(iCapTeam, iNewCaptain);
				MixPrintToChatAll("\x0F%N\x08 is now the %s captain. (previous captain disconnected)", iNewCaptain, iCapTeam == CS_TEAM_CT ? MIX_TEAM2_CHAT : MIX_TEAM1_CHAT);
			}
		}
	}

	if(g_Init) {
		CheckLoneTerrorist(client);
	}

	// Mid-pick leaver: picked ones trigger an immediate re-pick by their captain.
	if(g_gameState == eGameState_PickingPlayers) {
		int iCaptain = (iPickedLeaveTeam == CS_TEAM_CT) ? g_iCTCaptain : g_iTCaptain;
		if(iPickedLeaveTeam != 0 && iCaptain >= 1 && IsClientInGame(iCaptain) && !IsFakeClient(iCaptain)) {
			MixPrintToChatAll("\x0F%N\x08 disconnected from the %s team - \x0F%N\x08 picks a replacement!", client, iPickedLeaveTeam == CS_TEAM_CT ? MIX_TEAM2_CHAT : MIX_TEAM1_CHAT, iCaptain);
			g_iLastPickedTeam = GetOppositeTeam(iPickedLeaveTeam);
			OpenPlayersMenu(iCaptain, iPickedLeaveTeam);
			RefreshMixRosterPanels();
		}
		else {
			RefreshPickingPhaseMenus();
		}
	}
}

stock bool FindAndRemovePlayer(int client, int team) {
	int teamIndex = (team == CS_TEAM_T) ? __TEAM_T : __TEAM_CT;

	if(g_alPlayers[teamIndex] != null) {
		Player_t player;

		for(int i = 0; i < g_alPlayers[teamIndex].Length; i++) {
			g_alPlayers[teamIndex].GetArray(i, player, sizeof(Player_t));

			if (player.clientIdx == client) {
				g_alPlayers[teamIndex].Erase(i);
				PrintToConsoleAll("[%s] Removed %N from %s", g_sChatPrefix, player.clientIdx, teamIndex == __TEAM_T ? "Team 1" : "Team 2");
				return true;
			}
		}
	}
	return false;
}

// Auto-pause on disconnect: a roster player dropping mid-mix pauses the match and their captain
// gets a menu to seat a replacement or unpause short-handed. Doing neither waits - the leaver
// is seated straight back when they reconnect.

int FindDcEntryByAuth(const char[] sAuth) {
	if(g_alDcPlayers == null || sAuth[0] == '\0') {
		return -1;
	}

	DcPlayer_t dc;
	for(int i = 0; i < g_alDcPlayers.Length; i++) {
		g_alDcPlayers.GetArray(i, dc, sizeof(DcPlayer_t));
		if(StrEqual(dc.sAuth, sAuth)) {
			return i;
		}
	}
	return -1;
}

bool HasPendingDcEntries() {
	DcPlayer_t dc;
	for(int i = 0; i < g_alDcPlayers.Length; i++) {
		g_alDcPlayers.GetArray(i, dc, sizeof(DcPlayer_t));
		if(!dc.bReplaced) {
			return true;
		}
	}
	return false;
}

void HandleMixPlayerDisconnect(int client, int iRosterTeam) {
	// Bank their stats now (no win/loss - the mix hasn't concluded) and zero
	// the accumulators: if they reconnect they keep earning from zero, and
	// the DB total stays correct either way.
	FlushPlayerMixStats(client, 0, 0, true);

	char sAuth[32];
	if(!GetClientAuthCached(client, sAuth, sizeof(sAuth))) {
		// No auth (rare) - they can't be recognized on reconnect, but the mix
		// still pauses so the team isn't forced to play short-handed.
		sAuth[0] = '\0';
	}

	DcPlayer_t dc;
	strcopy(dc.sAuth, sizeof(dc.sAuth), sAuth);
	GetClientName(client, dc.sName, sizeof(dc.sName));
	dc.iRosterTeam = iRosterTeam;
	dc.bReplaced = false;
	// Grab these while the client still exists: once they are gone GeoIP has no
	// address to read and the auth id is unavailable.
	GetMixCountryFlag(client, dc.sFlag, sizeof(dc.sFlag));
	if(!GetClientAuthId(client, AuthId_SteamID64, dc.sAuth64, sizeof(dc.sAuth64))) {
		dc.sAuth64[0] = '\0';
	}
	// Disconnecting kills the player entity (player_death fires before this callback), so a death
	// within the last half second means they were ALIVE when they pulled the plug. Only an earlier
	// death this round counts as genuinely dead.
	dc.bDeadWhenLeft = g_baDeadThisRound[client] && (GetGameTime() - g_faLastDeathTime[client]) > 0.5;
	dc.iLeftRound = g_iRoundSerial;

	// Alive leavers get their exact spot and health back if they return
	// within the round.
	dc.bHasSpot = false;
	dc.iHealth = 0;
	if(!dc.bDeadWhenLeft && GetClientTeam(client) > CS_TEAM_SPECTATOR) {
		GetClientAbsOrigin(client, dc.faPos);
		GetClientEyeAngles(client, dc.faAng);
		dc.bHasSpot = true;

		// The disconnect kill already zeroed their live health - fall back to
		// the last health seen while they were playing.
		dc.iHealth = IsPlayerAlive(client) ? GetClientHealth(client) : g_iaLastKnownHealth[client];
		if(dc.iHealth <= 0) {
			dc.iHealth = 100;
		}
	}

	if(sAuth[0] != '\0') {
		int idx = FindDcEntryByAuth(sAuth);
		if(idx == -1) {
			g_alDcPlayers.PushArray(dc, sizeof(DcPlayer_t));
		}
		else {
			g_alDcPlayers.SetArray(idx, dc, sizeof(DcPlayer_t));
		}
	}

	AutoPauseMix();
	// Freeze the round state too: without this, the leaver's death ends the
	// round (team elimination) and the "resume where they left off" promise
	// is impossible - a new round would have started.
	SuspendWinConditions();

	// A running surrender vote can't sensibly continue with a voter missing -
	// cancel it without burning the team's cooldown.
	if(g_bSurrenderVoteActive) {
		MixPrintToChatAll("The surrender vote was cancelled - a player disconnected.");
		EndSurrenderVote(false);
	}

	// 1v1: no replacement pool and no automatic win, the opponent waits. The missing player forfeits
	// after hnsmix_dc_forfeit_time unless they return; captains may !extend. Unpausing is blocked
	// for the duration.
	if(g_iCurrentPlayerMode == 1) {
		// Someone is already being waited for - don't re-arm the clock for a
		// second leaver; their entry is recorded and they can still return.
		if(g_hDcWaitTimer != null) {
			MixPrintToChatAll("\x0F%s\x08 also left the %s team - still waiting on \x0F%s\x08 (\x0F%d:%02d\x08 left).", dc.sName, iRosterTeam == CS_TEAM_CT ? MIX_TEAM2_CHAT : MIX_TEAM1_CHAT, g_sDcWaitName, g_iDcWaitSecondsLeft / 60, g_iDcWaitSecondsLeft % 60);
			return;
		}

		g_iDcWaitSecondsLeft = cv_DcForfeitTime.IntValue;
		g_iDcWaitTeam = iRosterTeam;
		strcopy(g_sDcWaitAuth, sizeof(g_sDcWaitAuth), dc.sAuth);
		strcopy(g_sDcWaitName, sizeof(g_sDcWaitName), dc.sName);

		g_hDcWaitTimer = CreateTimer(1.0, Timer_DcWaitTick, _, TIMER_REPEAT | TIMER_FLAG_NO_MAPCHANGE);

		MixPrintToChatAll("\x0F%s\x08 left the %s team - the MIX is \x02auto-paused\x08. They have \x0F%d:%02d\x08 to reconnect or they forfeit. (\x0F!extend\x08 adds time)", dc.sName, iRosterTeam == CS_TEAM_CT ? MIX_TEAM2_CHAT : MIX_TEAM1_CHAT, g_iDcWaitSecondsLeft / 60, g_iDcWaitSecondsLeft % 60);

		int iOtherCaptain = (iRosterTeam == CS_TEAM_CT) ? g_iTCaptain : g_iCTCaptain;
		if(iOtherCaptain >= 1 && iOtherCaptain != client && IsClientInGame(iOtherCaptain) && !IsFakeClient(iOtherCaptain)) {
			OpenDcWaitMenu(iOtherCaptain);
		}
		return;
	}

	MixPrintToChatAll("\x0F%s\x08 left the %s team - the MIX is \x02auto-paused\x08. They get their spot back on reconnect.", dc.sName, iRosterTeam == CS_TEAM_CT ? MIX_TEAM2_CHAT : MIX_TEAM1_CHAT);

	// The replace menu goes to the short-handed team's captain - or, if the
	// leaver WAS that captain, to a teammate acting as captain.
	int iDecider = GetMixTeamDecider(iRosterTeam, client);
	if(iDecider != -1) {
		OpenDcReplaceMenu(iDecider, dc.sAuth);
	}
}

// The team's captain, or (captain gone/leaving) the first connected roster
// member - the acting captain for replace/forfeit decisions.
int GetMixTeamDecider(int iRosterTeam, int excludeClient = -1) {
	int iCaptain = (iRosterTeam == CS_TEAM_CT) ? g_iCTCaptain : g_iTCaptain;
	if(iCaptain >= 1 && iCaptain != excludeClient && IsClientInGame(iCaptain) && !IsFakeClient(iCaptain)) {
		return iCaptain;
	}

	int teamIndex = (iRosterTeam == CS_TEAM_CT) ? __TEAM_CT : __TEAM_T;
	Player_t player;
	for(int i = 0; i < g_alPlayers[teamIndex].Length; i++) {
		g_alPlayers[teamIndex].GetArray(i, player, sizeof(Player_t));
		int c = player.clientIdx;
		if(c >= 1 && c != excludeClient && IsClientInGame(c) && !IsFakeClient(c)) {
			return c;
		}
	}
	return -1;
}

// May this client make replace/forfeit decisions for a roster team? True for
// the team's captain and for its roster members (acting captain).
bool IsMixTeamDecider(int client, int iRosterTeam) {
	if(client == ((iRosterTeam == CS_TEAM_CT) ? g_iCTCaptain : g_iTCaptain)) {
		return true;
	}
	return IsPlayerInTeam(client, iRosterTeam);
}

// Pause with no human actor. Also cancels a pending resume countdown so the
// match can't go live short-handed mid-count.
void AutoPauseMix() {
	if(!g_Init) {
		return;
	}

	if(g_bMatchPaused) {
		if(g_iUnpauseCountdown > 0) {
			g_iUnpauseCountdown = 0;
			StopTimer(g_hPauseTimer);
			g_hPauseTimer = CreateTimer(1.0, Timer_PauseHold, _, TIMER_REPEAT | TIMER_FLAG_NO_MAPCHANGE);
			MixPrintToChatAll("The resume was cancelled - the match stays \x02paused\x08.");
			RefreshOpenMixMenus();
		}
		return;
	}

	g_bMatchPaused = true;
	g_iUnpauseCountdown = 0;
	g_IsTimerPaused = true;
	BankRoundStartCtFreeze();

	FreezePlayers(true);
	FreezeGrenades();
	FreezeInfernos();

	StopTimer(g_hPauseTimer);
	g_hPauseTimer = CreateTimer(1.0, Timer_PauseHold, _, TIMER_REPEAT | TIMER_FLAG_NO_MAPCHANGE);
	RefreshOpenMixMenus();
}

// The main disconnect menu: Unpause / Replace DCed Player / Forfeit. If the
// missing player already returned (entry gone or resolved), it degrades to a
// plain "Unpause Mix" so a stale menu never lies to the captain.
void OpenDcReplaceMenu(int captain, const char[] sAuth) {
	strcopy(g_saDcMenuAuth[captain], sizeof(g_saDcMenuAuth[]), sAuth);
	g_baDcMenuOpen[captain] = true;

	int idx = FindDcEntryByAuth(sAuth);
	DcPlayer_t dc;
	bool bPending = false;
	if(idx != -1) {
		g_alDcPlayers.GetArray(idx, dc, sizeof(DcPlayer_t));
		bPending = !dc.bReplaced;
	}

	Menu menu = new Menu(MenuHandler_DcReplace);

	if(!bPending) {
		menu.SetTitle("[%s] All players are present:", g_sChatPrefix);
		menu.AddItem("unpause", "Unpause Mix");
		menu.ExitButton = true;
		menu.Display(captain, MENU_TIME_FOREVER);
		return;
	}

	menu.SetTitle("[%s] %s (%s) left - replace them or wait:", g_sChatPrefix, dc.sName, dc.iRosterTeam == CS_TEAM_CT ? "Team 2" : "Team 1");

	menu.AddItem("unpause", "Unpause Mix (play short-handed)");
	menu.AddItem("replace", "Replace DCed Player");

	// Forfeiting is only offered to the diminished team's own captain or a
	// teammate acting as captain - never to the opposing team, which must not
	// be able to award itself the win.
	if(IsMixTeamDecider(captain, dc.iRosterTeam)) {
		menu.AddItem("forfeit", "Forfeit Match");
	}

	menu.ExitButton = true;
	menu.Display(captain, MENU_TIME_FOREVER);
}

// True if this spectator may fill a roster spot now. Players replaced out ARE eligible again,
// their lock lifting when a captain deliberately seats them; only players whose own spot is
// still open cannot fill someone else's.
bool IsEligibleReplacement(int client) {
	if(client < 1 || !IsClientInGame(client) || IsFakeClient(client) || IsClientSourceTV(client) || IsClientCaptain(client)) {
		return false;
	}
	if(IsPlayerInTeam(client, CS_TEAM_CT) || IsPlayerInTeam(client, CS_TEAM_T)) {
		return false;
	}
	if(!g_bWantsToPlay[client] || HasPendingDcEntryClient(client) || GetClientTeam(client) != CS_TEAM_SPECTATOR) {
		return false;
	}
	return true;
}

void OpenDcReplaceListMenu(int captain) {
	int idx = FindDcEntryByAuth(g_saDcMenuAuth[captain]);
	if(idx == -1) {
		OpenDcReplaceMenu(captain, g_saDcMenuAuth[captain]); // resolved meanwhile
		return;
	}

	DcPlayer_t dc;
	g_alDcPlayers.GetArray(idx, dc, sizeof(DcPlayer_t));
	if(dc.bReplaced) {
		OpenDcReplaceMenu(captain, g_saDcMenuAuth[captain]);
		return;
	}

	g_baDcMenuOpen[captain] = true;

	Menu menu = new Menu(MenuHandler_DcReplaceList);
	menu.SetTitle("[%s] Replace %s with:", g_sChatPrefix, dc.sName);

	char sID[16]; char sBuffer[MAX_NAME_LENGTH+8];
	for(int i = 1; i <= MaxClients; i++) {
		if(!IsEligibleReplacement(i)) {
			continue;
		}
		IntToString(GetClientUserId(i), sID, sizeof(sID));
		FormatEx(sBuffer, sizeof(sBuffer), "%N", i);
		menu.AddItem(sID, sBuffer);
	}

	if(menu.ItemCount == 0) {
		menu.AddItem("", " :: No Spectators Available", ITEMDRAW_DISABLED);
	}

	menu.ExitBackButton = true; // Back -> the main disconnect menu
	menu.Display(captain, MENU_TIME_FOREVER);
}

public int MenuHandler_DcReplace(Menu menu, MenuAction action, int param1, int param2) {
	switch(action) {
		case MenuAction_Select: {
			g_baDcMenuOpen[param1] = false;

			char sInfo[16];
			menu.GetItem(param2, sInfo, sizeof(sInfo));

			if(StrEqual(sInfo, "unpause")) {
				DoMatchUnpause(param1);
				return 0;
			}

			int idx = FindDcEntryByAuth(g_saDcMenuAuth[param1]);
			if(idx == -1) {
				MixPrintToChat(param1, "That player already returned - \x0F!unpause\x08 when ready.");
				return 0;
			}

			DcPlayer_t dc;
			g_alDcPlayers.GetArray(idx, dc, sizeof(DcPlayer_t));
			if(dc.bReplaced) {
				MixPrintToChat(param1, "They were already replaced.");
				return 0;
			}

			if(StrEqual(sInfo, "replace")) {
				OpenDcReplaceListMenu(param1);
				return 0;
			}

			// The diminished team's (acting) captain gives up: the other team wins.
			if(StrEqual(sInfo, "forfeit")) {
				if(!IsMixTeamDecider(param1, dc.iRosterTeam)) {
					MixPrintToChat(param1, "Only the short-handed team can forfeit.");
					return 0;
				}
				MixPrintToChatAll("\x0F%N\x08 surrendered on behalf of the %s team.", param1, dc.iRosterTeam == CS_TEAM_CT ? MIX_TEAM2_CHAT : MIX_TEAM1_CHAT);
				DeclareMixForfeitWin(GetOppositeTeam(dc.iRosterTeam), "forfeit");
				return 0;
			}
		}
		case MenuAction_Cancel: {
			if(param2 == MenuCancel_Exit) {
				g_baDcMenuOpen[param1] = false;
			}
		}
		case MenuAction_End: {
			delete menu;
		}
	}
	return 0;
}

public int MenuHandler_DcReplaceList(Menu menu, MenuAction action, int param1, int param2) {
	switch(action) {
		case MenuAction_Select: {
			g_baDcMenuOpen[param1] = false;

			char sInfo[16];
			menu.GetItem(param2, sInfo, sizeof(sInfo));

			int idx = FindDcEntryByAuth(g_saDcMenuAuth[param1]);
			if(idx == -1) {
				MixPrintToChat(param1, "That player already returned - \x0F!unpause\x08 when ready.");
				return 0;
			}

			DcPlayer_t dc;
			g_alDcPlayers.GetArray(idx, dc, sizeof(DcPlayer_t));
			if(dc.bReplaced) {
				MixPrintToChat(param1, "They were already replaced.");
				return 0;
			}

			int newPlayer = GetClientOfUserId(StringToInt(sInfo));
			if(newPlayer < 1 || !IsEligibleReplacement(newPlayer)) {
				MixPrintToChat(param1, "That replacement is no longer valid.");
				OpenDcReplaceListMenu(param1);
				return 0;
			}

			// The entry stays in the list flagged replaced: if the leaver
			// reconnects they're locked to spectator for the rest of the mix.
			dc.bReplaced = true;
			g_alDcPlayers.SetArray(idx, dc, sizeof(DcPlayer_t));

			char sOutTag[192], sInTag[192];
			BuildMixDiscordNameTag(dc.sFlag, dc.sAuth64, dc.sName, sOutTag, sizeof(sOutTag));
			BuildMixDiscordNameTagClient(newPlayer, sInTag, sizeof(sInTag));
			RecordMixSwap(sOutTag, sInTag);

			// A leaver still on the server gets locked to spectator right now
			// (a disconnected one gets locked on return).
			int iLeaver = FindClientByAuth(dc.sAuth);
			if(iLeaver != -1) {
				g_baReplacedSpectator[iLeaver] = true;
				MixPrintToChat(iLeaver, "A replacement took your spot - you're a spectator until this MIX ends.");
			}

			// The replacement sheds any leftover disconnect state of their
			// own (e.g. they were replaced out of this mix earlier and are
			// now deliberately being seated again).
			ClearDcStateFor(newPlayer);

			Player_t player;
			player.clientIdx = newPlayer;
			g_alPlayers[(dc.iRosterTeam == CS_TEAM_CT) ? __TEAM_CT : __TEAM_T].PushArray(player, sizeof(Player_t));

			// The replacement steps into the leaver's shoes for the rest of the round: dead if the leaver was
			// dead, otherwise alive at their exact spot with their remaining health. A new round means a
			// normal fresh seat instead.
			bool bSameRound = (dc.iLeftRound == g_iRoundSerial && !g_bBetweenRounds);

			if(dc.bDeadWhenLeft && bSameRound) {
				ChangeClientTeam(newPlayer, GetInGameTeamFor(dc.iRosterTeam)); // joins dead
				g_baDeadThisRound[newPlayer] = true;
			}
			else {
				MovePlayerToTeam(newPlayer, GetInGameTeamFor(dc.iRosterTeam));

				if(dc.iHealth > 0 && bSameRound) {
					g_iaPendingSeatHealth[newPlayer] = dc.iHealth;
					g_baPendingSeatSpot[newPlayer] = dc.bHasSpot;
					g_iaPendingSeatRound[newPlayer] = g_iRoundSerial;
					if(dc.bHasSpot) {
						for(int i = 0; i < 3; i++) {
							g_faPendingSeatPos[newPlayer][i] = dc.faPos[i];
							g_faPendingSeatAng[newPlayer][i] = dc.faAng[i];
						}
					}
					g_iaSeatRespawnTries[newPlayer] = 0;
					CreateTimer(0.2, Timer_FinishSeatRespawn, GetClientUserId(newPlayer), TIMER_REPEAT | TIMER_FLAG_NO_MAPCHANGE);
				}
			}

			MixPrintToChatAll("\x0F%N\x08 replaced \x0F%s\x08 with \x0F%N\x08 on the %s team.", param1, dc.sName, newPlayer, dc.iRosterTeam == CS_TEAM_CT ? MIX_TEAM2_CHAT : MIX_TEAM1_CHAT);

			// Everyone missing is accounted for - resume automatically.
			if(g_bMatchPaused && !HasPendingDcEntries()) {
				DoMatchUnpause(param1);
			}
		}
		case MenuAction_Cancel: {
			if(param2 == MenuCancel_ExitBack) {
				OpenDcReplaceMenu(param1, g_saDcMenuAuth[param1]);
			}
			else if(param2 == MenuCancel_Exit) {
				g_baDcMenuOpen[param1] = false;
			}
		}
		case MenuAction_End: {
			delete menu;
		}
	}
	return 0;
}

// A player deliberately seated back into the mix sheds leftover disconnect
// state: the replaced-spectator lock and any old entry of theirs.
void ClearDcStateFor(int client) {
	g_baReplacedSpectator[client] = false;

	char sAuth[32];
	if(GetClientAuthCached(client, sAuth, sizeof(sAuth))) {
		int idx = FindDcEntryByAuth(sAuth);
		if(idx != -1) {
			g_alDcPlayers.Erase(idx);
		}
	}
}

public Action Timer_ForceReplacedSpec(Handle timer, any userid) {
	int client = GetClientOfUserId(userid);
	if(client < 1 || !g_Init || !IsClientInGame(client) || !g_baReplacedSpectator[client]) {
		return Plugin_Stop;
	}

	if(GetClientTeam(client) > CS_TEAM_SPECTATOR) {
		g_baAuthorizedSpecMove[client] = true;
		ChangeClientTeam(client, CS_TEAM_SPECTATOR);
		MixPrintToChat(client, "You were replaced during this MIX - you can play again next MIX.");
	}
	return Plugin_Stop;
}

int FindClientByAuth(const char[] sAuth) {
	if(sAuth[0] == '\0') {
		return -1;
	}

	char sOther[32];
	for(int i = 1; i <= MaxClients; i++) {
		if(!IsClientInGame(i) || IsFakeClient(i)) {
			continue;
		}
		if(GetClientAuthCached(i, sOther, sizeof(sOther)) && StrEqual(sOther, sAuth)) {
			return i;
		}
	}
	return -1;
}

// True if this client has their own PENDING entry - they hold an open roster spot and cannot fill
// someone else's. Players already replaced out are NOT pending: a captain may seat them again.
bool HasPendingDcEntryClient(int client) {
	if(g_alDcPlayers == null || g_alDcPlayers.Length == 0) {
		return false;
	}

	char sAuth[32];
	if(!GetClientAuthCached(client, sAuth, sizeof(sAuth))) {
		return false;
	}

	int idx = FindDcEntryByAuth(sAuth);
	if(idx == -1) {
		return false;
	}

	DcPlayer_t dc;
	g_alDcPlayers.GetArray(idx, dc, sizeof(DcPlayer_t));
	return !dc.bReplaced;
}

// !add / !canceladd - see the g_bAddActive block for the flow.

int CountAddableSpecs() {
	int count = 0;
	for(int i = 1; i <= MaxClients; i++) {
		if(IsEligibleReplacement(i)) {
			count++;
		}
	}
	return count;
}

public Action Command_AddPlayers(int client, int args) {
	if(client < 1 || !IsClientInGame(client)) {
		return Plugin_Handled;
	}

	// Already running: the captain on the clock reopens their menu.
	if(g_bAddActive) {
		if(client == g_iAddPicker) {
			OpenAddMenu(client);
		}
		else if(g_iAddPicker >= 1 && IsClientInGame(g_iAddPicker)) {
			MixPrintToChat(client, "\x0F%N\x08 is already picking a player to add.", g_iAddPicker);
		}
		return Plugin_Handled;
	}

	if(!IsClientCaptain(client) && !HasMixAdminAccess(client)) {
		MixPrintToChat(client, "Only captains and admins can add players.");
		return Plugin_Handled;
	}

	// g_Init covers the picking phase (not live yet); knife rounds are
	// selection rounds with fixed rosters.
	if(!g_Init || g_iKnifeStage != KNIFE_NONE) {
		MixPrintToChat(client, "Players can only be added during a live MIX.");
		return Plugin_Handled;
	}

	if(g_hDcWaitTimer != null || HasPendingDcEntries()) {
		MixPrintToChat(client, "Someone is still missing from the MIX - settle that first.");
		return Plugin_Handled;
	}

	if(g_iCurrentPlayerMode >= MAX_PLAYERS_IN_1V1_PER_TEAM) {
		MixPrintToChat(client, "The MIX is already at the maximum of \x0F%dv%d\x08.", MAX_PLAYERS_IN_1V1_PER_TEAM, MAX_PLAYERS_IN_1V1_PER_TEAM);
		return Plugin_Handled;
	}

	int iSpecs = CountAddableSpecs();
	if(iSpecs < 2) {
		MixPrintToChat(client, "Not enough spectators to add - \x0F2\x08 are needed, \x0F%d\x08 available.", iSpecs);
		return Plugin_Handled;
	}

	if(GetMixTeamDecider(CS_TEAM_CT) == -1 || GetMixTeamDecider(CS_TEAM_T) == -1) {
		MixPrintToChat(client, "Both teams need a captain before players can be added.");
		return Plugin_Handled;
	}

	StartAddPlayers(client);
	return Plugin_Handled;
}

// !forceadd - admin-only and deliberately one-sided. Separate from !add on purpose: an admin who
// is also a captain must not unbalance the match with the normal grow command. This always asks
// which team, never auto-resumes, and only downgrades to casual if the rosters end up uneven.
public Action Command_ForceAdd(int client, int args) {
	if(client < 1 || !IsClientInGame(client)) {
		return Plugin_Handled;
	}

	if(!HasMixAdminAccess(client)) {
		MixPrintToChat(client, "Only admins can force-add players.");
		return Plugin_Handled;
	}

	if(g_bAddActive) {
		MixPrintToChat(client, "A normal \x0Fadd\x08 is already in progress - finish it or use \x0F!canceladd\x08 first.");
		return Plugin_Handled;
	}

	if(!g_Init || g_iKnifeStage != KNIFE_NONE) {
		MixPrintToChat(client, "Players can only be force-added during a live MIX.");
		return Plugin_Handled;
	}

	if(CountAddableSpecs() < 1) {
		MixPrintToChat(client, "No spectators are available to add.");
		return Plugin_Handled;
	}

	OpenForceAddTeamMenu(client);
	return Plugin_Handled;
}

void OpenForceAddTeamMenu(int client) {
	Menu menu = new Menu(MenuHandler_ForceAddTeam);
	menu.SetTitle("[%s] Force Add - which team?", g_sChatPrefix);

	char sTeam1Captain[MAX_NAME_LENGTH];
	char sTeam2Captain[MAX_NAME_LENGTH];
	if(g_iTCaptain > 0 && IsClientConnected(g_iTCaptain)) {
		GetClientName(g_iTCaptain, sTeam1Captain, sizeof(sTeam1Captain));
	} else {
		strcopy(sTeam1Captain, sizeof(sTeam1Captain), "No captain");
	}
	if(g_iCTCaptain > 0 && IsClientConnected(g_iCTCaptain)) {
		GetClientName(g_iCTCaptain, sTeam2Captain, sizeof(sTeam2Captain));
	} else {
		strcopy(sTeam2Captain, sizeof(sTeam2Captain), "No captain");
	}

	char sBuf[MAX_NAME_LENGTH + 24];
	FormatEx(sBuf, sizeof(sBuf), "Team 1 - %s (%d)", sTeam1Captain, g_alPlayers[__TEAM_T].Length);
	menu.AddItem("t", sBuf);
	FormatEx(sBuf, sizeof(sBuf), "Team 2 - %s (%d)", sTeam2Captain, g_alPlayers[__TEAM_CT].Length);
	menu.AddItem("ct", sBuf);

	menu.ExitButton = true;
	menu.Display(client, MENU_TIME_FOREVER);
}

public int MenuHandler_ForceAddTeam(Menu menu, MenuAction action, int param1, int param2) {
	switch(action) {
		case MenuAction_Select: {
			char sInfo[8];
			menu.GetItem(param2, sInfo, sizeof(sInfo));

			if(!HasMixAdminAccess(param1) || !g_Init) {
				return 0;
			}

			g_iForceAddTeam = StrEqual(sInfo, "ct") ? CS_TEAM_CT : CS_TEAM_T;
			OpenForceAddPlayerMenu(param1);
		}
		case MenuAction_End: {
			delete menu;
		}
	}
	return 0;
}

void OpenForceAddPlayerMenu(int client) {
	Menu menu = new Menu(MenuHandler_ForceAddPlayer);
	menu.SetTitle("[%s] Force Add - pick a spectator for %s:", g_sChatPrefix, g_iForceAddTeam == CS_TEAM_CT ? "Team 2" : "Team 1");

	char sID[16]; char sBuffer[MAX_NAME_LENGTH+8];
	for(int i = 1; i <= MaxClients; i++) {
		if(!IsEligibleReplacement(i)) {
			continue;
		}
		IntToString(GetClientUserId(i), sID, sizeof(sID));
		FormatEx(sBuffer, sizeof(sBuffer), "%N", i);
		menu.AddItem(sID, sBuffer);
	}

	if(menu.ItemCount == 0) {
		menu.AddItem("", " :: No Spectators Available", ITEMDRAW_DISABLED);
	}

	menu.ExitButton = true;
	menu.Display(client, MENU_TIME_FOREVER);
}

public int MenuHandler_ForceAddPlayer(Menu menu, MenuAction action, int param1, int param2) {
	switch(action) {
		case MenuAction_Select: {
			char sInfo[16];
			menu.GetItem(param2, sInfo, sizeof(sInfo));

			if(!HasMixAdminAccess(param1) || !g_Init) {
				return 0;
			}

			SeatForceAddedPlayer(param1, GetClientOfUserId(StringToInt(sInfo)));
		}
		case MenuAction_End: {
			delete menu;
		}
	}
	return 0;
}

void SeatForceAddedPlayer(int admin, int target) {
	if(target < 1 || !IsEligibleReplacement(target)) {
		MixPrintToChat(admin, "That player can't be added anymore.");
		OpenForceAddPlayerMenu(admin);
		return;
	}

	// Hold the match here and leave it held: the admin decides when play
	// resumes, via Unpause Match in the mix menu (or !unpause).
	if(!g_bMatchPaused) {
		AutoPauseMix();
	}

	ClearDcStateFor(target);
	SeatRosterPlayer(target, g_iForceAddTeam, true);

	MixPrintToChatAll("\x0F%N\x08 force-added \x0F%N\x08 to %s - they spawn next round.", admin, target, g_iForceAddTeam == CS_TEAM_CT ? MIX_TEAM2_CHAT : MIX_TEAM1_CHAT);

	int iT = g_alPlayers[__TEAM_T].Length;
	int iCt = g_alPlayers[__TEAM_CT].Length;

	// Team size follows the larger side so the roster panel and pick limits
	// stay sane on an uneven roster.
	g_iCurrentPlayerMode = (iT > iCt) ? iT : iCt;

	if(iT != iCt) {
		// Uneven rosters make the elo math meaningless, so a ranked mix is
		// downgraded here. A mix that was already casual just stays casual.
		if(!IsCasualMix()) {
			g_iMixCasualLock = 1;
			MixPrintToChatAll("Teams are now uneven (\x0F%dv%d\x08) - this match is no longer \x0Franked\x08 and counts as \x0Fcasual\x08: no elo or stats will be banked.", iT, iCt);
		}
		else {
			MixPrintToChatAll("Teams are now uneven (\x0F%dv%d\x08).", iT, iCt);
		}
	}
	else {
		MixPrintToChatAll("Teams are still even - the MIX is now \x0F%dv%d\x08 and stays \x0F%s\x08.", iT, iCt, IsCasualMix() ? "casual" : "ranked");
	}

	MixPrintToChat(admin, "The match stays \x02paused\x08 - use \x0FUnpause Match\x08 in \x0F!mixmenu\x08 when you're ready.");
	RefreshOpenMixMenus();
}

public Action Command_CancelAdd(int client, int args) {
	if(client < 1 || !IsClientInGame(client)) {
		return Plugin_Handled;
	}

	if(!g_bAddActive) {
		MixPrintToChat(client, "No players are being added right now.");
		return Plugin_Handled;
	}

	if(!IsClientCaptain(client) && !HasMixAdminAccess(client)) {
		MixPrintToChat(client, "Only captains and admins can cancel the add.");
		return Plugin_Handled;
	}

	CancelAddPlayers(client, "");
	return Plugin_Handled;
}

void StartAddPlayers(int client) {
	g_bAddActive = true;
	g_iAddStep = 0;
	g_iaAddedUserId[0] = 0;
	g_iaAddedUserId[1] = 0;

	bool bCtFirst = (GetRandomInt(0, 1) == 0); // coin flip for the first pick
	g_iaAddTeamOrder[0] = bCtFirst ? CS_TEAM_CT : CS_TEAM_T;
	g_iaAddTeamOrder[1] = bCtFirst ? CS_TEAM_T : CS_TEAM_CT;

	// An add that lands on an existing pause leaves it standing afterwards.
	g_bAddWasPaused = g_bMatchPaused;
	if(!g_bAddWasPaused) {
		AutoPauseMix();
	}

	MixPrintToChatAll("\x0F%N\x08 started an \x0Fadd\x08 - the match is \x02paused\x08 while both captains pick one spectator each. (\x0F!canceladd\x08 cancels)", client);
	AddPickStep();
}

// Hand the menu to the captain whose turn it is. No captain left on that side
// means the add can never finish, so it is cancelled.
void AddPickStep() {
	int iTeam = g_iaAddTeamOrder[g_iAddStep];
	int iPicker = GetMixTeamDecider(iTeam);
	if(iPicker == -1) {
		CancelAddPlayers(-1, "the picking captain is gone");
		return;
	}

	g_iAddPicker = iPicker;
	MixPrintToChatAll("\x0F%N\x08 is picking for %s - use the menu or type the player's name in chat.", iPicker, iTeam == CS_TEAM_CT ? MIX_TEAM2_CHAT : MIX_TEAM1_CHAT);
	OpenAddMenu(iPicker);
}

void OpenAddMenu(int client) {
	Menu menu = new Menu(MenuHandler_AddPlayers);
	menu.SetTitle("[%s] Add Players - pick a spectator for %s:", g_sChatPrefix, g_iaAddTeamOrder[g_iAddStep] == CS_TEAM_CT ? "Team 2" : "Team 1");

	char sID[16]; char sBuffer[MAX_NAME_LENGTH+8];
	for(int i = 1; i <= MaxClients; i++) {
		if(!IsEligibleReplacement(i)) {
			continue;
		}
		IntToString(GetClientUserId(i), sID, sizeof(sID));
		FormatEx(sBuffer, sizeof(sBuffer), "%N", i);
		menu.AddItem(sID, sBuffer);
	}

	if(menu.ItemCount == 0) {
		menu.AddItem("", " :: No Spectators Available", ITEMDRAW_DISABLED);
	}

	menu.AddItem("cancel", "Cancel Add");
	menu.ExitButton = true;
	menu.Display(client, MENU_TIME_FOREVER);
}

public int MenuHandler_AddPlayers(Menu menu, MenuAction action, int param1, int param2) {
	switch(action) {
		case MenuAction_Select: {
			char sInfo[16];
			menu.GetItem(param2, sInfo, sizeof(sInfo));

			if(!g_bAddActive || param1 != g_iAddPicker) {
				return 0; // stale menu
			}

			if(StrEqual(sInfo, "cancel")) {
				CancelAddPlayers(param1, "");
				return 0;
			}

			SeatAddedPlayer(param1, GetClientOfUserId(StringToInt(sInfo)));
		}
		case MenuAction_Cancel: {
			// Closing the menu must not strand the pause - they still pick.
			if(g_bAddActive && param1 == g_iAddPicker) {
				MixPrintToChat(param1, "Type the player's name in chat, \x0F!add\x08 to reopen the menu, or \x0F!canceladd\x08 to cancel.");
			}
		}
		case MenuAction_End: {
			delete menu;
		}
	}
	return 0;
}

// Seat one picked spectator on the picking captain's team. They join dead and
// spawn with everyone else next round.
void SeatAddedPlayer(int picker, int target) {
	if(target < 1 || !IsEligibleReplacement(target)) {
		MixPrintToChat(picker, "That player can't be added anymore.");
		OpenAddMenu(picker);
		return;
	}

	int iTeam = g_iaAddTeamOrder[g_iAddStep];

	ClearDcStateFor(target); // sheds an old replaced-spectator lock
	SeatRosterPlayer(target, iTeam, true);
	g_iaAddedUserId[g_iAddStep] = GetClientUserId(target);

	MixPrintToChatAll("\x0F%N\x08 added \x0F%N\x08 to %s - they spawn next round.", picker, target, iTeam == CS_TEAM_CT ? MIX_TEAM2_CHAT : MIX_TEAM1_CHAT);

	g_iAddPicker = -1;
	if(++g_iAddStep >= 2) {
		FinishAddPlayers(picker);
		return;
	}
	AddPickStep();
}

void FinishAddPlayers(int actor) {
	g_bAddActive = false;
	g_iAddPicker = -1;
	g_iCurrentPlayerMode++;

	MixPrintToChatAll("Both players are in - the MIX is now \x0F%dv%d\x08.", g_iCurrentPlayerMode, g_iCurrentPlayerMode);
	ResumeAfterAdd(actor);
}

// Undo an add in progress: anyone already seated goes back to spectator.
void CancelAddPlayers(int actor, const char[] sReason) {
	if(!g_bAddActive) {
		return;
	}

	g_bAddActive = false;
	int iPicker = g_iAddPicker;
	g_iAddPicker = -1;

	if(actor >= 1 && IsClientInGame(actor)) {
		MixPrintToChatAll("\x0F%N\x08 cancelled the add - nobody was added.", actor);
	}
	else {
		MixPrintToChatAll("The add was cancelled%s%s - nobody was added.", (sReason[0] != '\0') ? " - " : "", sReason);
	}

	for(int i = 0; i < 2; i++) {
		int c = GetClientOfUserId(g_iaAddedUserId[i]);
		g_iaAddedUserId[i] = 0;
		if(c < 1 || !IsClientInGame(c)) {
			continue;
		}
		FindAndRemovePlayer(c, CS_TEAM_T);
		FindAndRemovePlayer(c, CS_TEAM_CT);
		if(GetClientTeam(c) > CS_TEAM_SPECTATOR) {
			g_baAuthorizedSpecMove[c] = true;
			ChangeClientTeam(c, CS_TEAM_SPECTATOR);
		}
		MixPrintToChat(c, "The add was cancelled - you're back in spectator.");
	}

	// Drop the picker's menu; the handler ignores it now that the add is off.
	if(iPicker >= 1 && IsClientInGame(iPicker) && !IsFakeClient(iPicker)) {
		CancelClientMenu(iPicker);
	}

	ResumeAfterAdd(actor);
}

// Give back the pause the add took. An add that started on an already-paused
// match leaves that pause alone.
void ResumeAfterAdd(int actor) {
	if(g_bAddWasPaused || !g_bMatchPaused) {
		return;
	}

	int iUnpauser = (actor >= 1 && IsClientInGame(actor)) ? actor : GetMixTeamDecider(CS_TEAM_CT);
	if(iUnpauser == -1) {
		iUnpauser = GetMixTeamDecider(CS_TEAM_T);
	}
	if(iUnpauser != -1) {
		DoMatchUnpause(iUnpauser);
	}
}

// !surrender / !ff - a whole-team vote. Nobody leaves the roster through
// surrendering anymore; players who truly must go just leave the server
// (which runs the disconnect flow).

public Action Command_Surrender(int client, int args) {
	if(client < 1 || !IsClientInGame(client)) {
		return Plugin_Handled;
	}

	if(!g_Init) {
		MixPrintToChat(client, "There is no live MIX to surrender.");
		return Plugin_Handled;
	}

	// Knife rounds are selection rounds - they can't be surrendered into a
	// full match result.
	if(g_iKnifeStage != KNIFE_NONE) {
		MixPrintToChat(client, "You can't surrender during a knife round.");
		return Plugin_Handled;
	}

	int iRosterTeam = 0;
	if(IsPlayerInTeam(client, CS_TEAM_CT)) {
		iRosterTeam = CS_TEAM_CT;
	}
	else if(IsPlayerInTeam(client, CS_TEAM_T)) {
		iRosterTeam = CS_TEAM_T;
	}

	if(iRosterTeam == 0) {
		MixPrintToChat(client, "You are not part of the current MIX.");
		return Plugin_Handled;
	}

	// 1v1: your team is just you - the other player wins immediately.
	if(g_iCurrentPlayerMode == 1) {
		MixPrintToChatAll("\x0F%N\x08 has surrendered the 1v1.", client);
		DeclareMixForfeitWin(GetOppositeTeam(iRosterTeam), "surrender");
		return Plugin_Handled;
	}

	// A vote is already running: !ff from the voting team counts as a Yes;
	// the other team has no say.
	if(g_bSurrenderVoteActive) {
		if(iRosterTeam == g_iSurrenderVoteTeam) {
			RegisterSurrenderVote(client, true);
		}
		else {
			MixPrintToChat(client, "The other team is holding a surrender vote right now.");
		}
		return Plugin_Handled;
	}

	if(cv_SurrenderVoteLimit.IntValue <= 0) {
		MixPrintToChat(client, "Surrender voting is disabled.");
		return Plugin_Handled;
	}

	// Team cooldown after a failed vote.
	int iTeamIndex = (iRosterTeam == CS_TEAM_CT) ? __TEAM_CT : __TEAM_T;
	if(GetGameTime() < g_faSurrenderNextVote[iTeamIndex]) {
		MixPrintToChat(client, "Your team's next surrender vote unlocks in \x0F%d\x08 seconds.", RoundToCeil(g_faSurrenderNextVote[iTeamIndex] - GetGameTime()));
		return Plugin_Handled;
	}

	// Per-player start budget, tracked by auth so reconnecting doesn't reset it.
	char sAuth[32];
	if(GetClientAuthCached(client, sAuth, sizeof(sAuth))) {
		if(CountSurrenderVoteStarts(sAuth) >= cv_SurrenderVoteLimit.IntValue) {
			MixPrintToChat(client, "You have no surrender votes left this MIX.");
			return Plugin_Handled;
		}
		g_alSurrenderVoteStarts.PushString(sAuth);
	}

	StartSurrenderVote(client, iRosterTeam);
	return Plugin_Handled;
}

int CountSurrenderVoteStarts(const char[] sAuth) {
	int count = 0;
	char sBuffer[32];
	for(int i = 0; i < g_alSurrenderVoteStarts.Length; i++) {
		g_alSurrenderVoteStarts.GetString(i, sBuffer, sizeof(sBuffer));
		if(StrEqual(sBuffer, sAuth)) {
			count++;
		}
	}
	return count;
}

void StartSurrenderVote(int initiator, int iRosterTeam) {
	g_bSurrenderVoteActive = true;
	g_iSurrenderVoteTeam = iRosterTeam;

	for(int i = 1; i <= MaxClients; i++) {
		g_iaSurrenderVote[i] = 0;
	}
	g_iaSurrenderVote[initiator] = 1; // starting the vote is their Yes

	StopTimer(g_hSurrenderVoteTimer);
	g_hSurrenderVoteTimer = CreateTimer(cv_SurrenderVoteTime.FloatValue, Timer_SurrenderVoteTimeout, _, TIMER_FLAG_NO_MAPCHANGE);

	MixPrintToChatAll("\x0F%N\x08 started a \x02surrender vote\x08 for the %s team - it needs every teammate's Yes.", initiator, iRosterTeam == CS_TEAM_CT ? MIX_TEAM2_CHAT : MIX_TEAM1_CHAT);

	// Only the voting team gets the menu.
	int teamIndex = (iRosterTeam == CS_TEAM_CT) ? __TEAM_CT : __TEAM_T;
	Player_t player;
	for(int i = 0; i < g_alPlayers[teamIndex].Length; i++) {
		g_alPlayers[teamIndex].GetArray(i, player, sizeof(Player_t));
		int c = player.clientIdx;
		if(c < 1 || c == initiator || !IsClientInGame(c) || IsFakeClient(c)) {
			continue;
		}

		Menu menu = new Menu(MenuHandler_SurrenderVote);
		menu.SetTitle("[%s] Surrender the mix? (%N asked)", g_sChatPrefix, initiator);
		menu.AddItem("yes", "Yes - give the other team the win");
		menu.AddItem("no", "No - keep playing");
		menu.ExitButton = false;
		menu.Display(c, RoundToCeil(cv_SurrenderVoteTime.FloatValue));
	}

	// A team of one (everyone else disconnected) passes instantly.
	CheckSurrenderVoteComplete();
}

public int MenuHandler_SurrenderVote(Menu menu, MenuAction action, int param1, int param2) {
	switch(action) {
		case MenuAction_Select: {
			char sInfo[8];
			menu.GetItem(param2, sInfo, sizeof(sInfo));
			RegisterSurrenderVote(param1, StrEqual(sInfo, "yes"));
		}
		case MenuAction_End: {
			delete menu;
		}
	}
	return 0;
}

void RegisterSurrenderVote(int client, bool bYes) {
	if(!g_bSurrenderVoteActive || !IsPlayerInTeam(client, g_iSurrenderVoteTeam)) {
		return;
	}

	if(g_iaSurrenderVote[client] != 0) {
		MixPrintToChat(client, "You already voted.");
		return;
	}

	if(!bYes) {
		// Unanimity is required, so a single No ends it on the spot.
		MixPrintToChatAll("\x0F%N\x08 voted \x07No\x08 - the surrender vote failed.", client);
		EndSurrenderVote(true);
		return;
	}

	g_iaSurrenderVote[client] = 1;
	MixPrintToChatAll("\x0F%N\x08 voted \x04Yes\x08 to surrender. (%d/%d)", client, CountSurrenderYesVotes(), CountConnectedRosterPlayers(g_iSurrenderVoteTeam));
	CheckSurrenderVoteComplete();
}

int CountSurrenderYesVotes() {
	int teamIndex = (g_iSurrenderVoteTeam == CS_TEAM_CT) ? __TEAM_CT : __TEAM_T;
	int count = 0;
	Player_t player;
	for(int i = 0; i < g_alPlayers[teamIndex].Length; i++) {
		g_alPlayers[teamIndex].GetArray(i, player, sizeof(Player_t));
		if(player.clientIdx >= 1 && IsClientInGame(player.clientIdx) && g_iaSurrenderVote[player.clientIdx] == 1) {
			count++;
		}
	}
	return count;
}

int CountConnectedRosterPlayers(int iRosterTeam) {
	int teamIndex = (iRosterTeam == CS_TEAM_CT) ? __TEAM_CT : __TEAM_T;
	int count = 0;
	Player_t player;
	for(int i = 0; i < g_alPlayers[teamIndex].Length; i++) {
		g_alPlayers[teamIndex].GetArray(i, player, sizeof(Player_t));
		if(player.clientIdx >= 1 && IsClientInGame(player.clientIdx) && !IsFakeClient(player.clientIdx)) {
			count++;
		}
	}
	return count;
}

void CheckSurrenderVoteComplete() {
	if(!g_bSurrenderVoteActive) {
		return;
	}

	// Every connected roster member of the team must have voted Yes.
	int teamIndex = (g_iSurrenderVoteTeam == CS_TEAM_CT) ? __TEAM_CT : __TEAM_T;
	Player_t player;
	for(int i = 0; i < g_alPlayers[teamIndex].Length; i++) {
		g_alPlayers[teamIndex].GetArray(i, player, sizeof(Player_t));
		int c = player.clientIdx;
		if(c < 1 || !IsClientInGame(c) || IsFakeClient(c)) {
			continue;
		}
		if(g_iaSurrenderVote[c] != 1) {
			return; // someone still hasn't agreed
		}
	}

	int iLoserTeam = g_iSurrenderVoteTeam;
	EndSurrenderVote(false); // no cooldown - the mix is over anyway
	MixPrintToChatAll("The %s team voted unanimously to surrender!", iLoserTeam == CS_TEAM_CT ? MIX_TEAM2_CHAT : MIX_TEAM1_CHAT);
	DeclareMixForfeitWin(GetOppositeTeam(iLoserTeam), "surrender");
}

// bApplyCooldown: failed votes gate the team's next attempt.
void EndSurrenderVote(bool bApplyCooldown) {
	if(!g_bSurrenderVoteActive) {
		return;
	}

	if(bApplyCooldown) {
		int iTeamIndex = (g_iSurrenderVoteTeam == CS_TEAM_CT) ? __TEAM_CT : __TEAM_T;
		g_faSurrenderNextVote[iTeamIndex] = GetGameTime() + cv_SurrenderCooldown.FloatValue;
	}

	g_bSurrenderVoteActive = false;
	g_iSurrenderVoteTeam = 0;
	StopTimer(g_hSurrenderVoteTimer);
}

public Action Timer_SurrenderVoteTimeout(Handle timer) {
	// This timer is ending on its own - clear the handle before
	// EndSurrenderVote so StopTimer can't double-free it.
	g_hSurrenderVoteTimer = null;

	if(g_bSurrenderVoteActive) {
		MixPrintToChatAll("The surrender vote expired - not everyone agreed.");
		EndSurrenderVote(true);
	}
	return Plugin_Stop;
}

// Forfeit wins + the 1v1 disconnect wait

void DeclareMixForfeitWin(int iWinnerRosterTeam, const char[] sReason) {
	CancelDcWait();

	int teamIndex = (iWinnerRosterTeam == CS_TEAM_CT) ? __TEAM_CT : __TEAM_T;
	char sWinColorTag[16];
	GetMixTeamColorTag((teamIndex == __TEAM_T) ? 1 : 2, sWinColorTag, sizeof(sWinColorTag));
	ScoreboardPrintAll(true, "%t", "Mix Win Forfeit", sWinColorTag, (teamIndex == __TEAM_T) ? 1 : 2, g_iCurrentPlayerMode, g_iCurrentPlayerMode);
	EndMixWithWinner(teamIndex, sReason);
}

// Single end-of-match choke point: the timer win, forfeits and surrender votes all funnel here.
// At this moment the rosters, captains, g_bDidSwitchTeams and the auth cache are all still
// intact - Stop1v1 is what tears them down. Abandoned mixes with no winner skip this entirely.
void EndMixWithWinner(int iWinnerTeamIndex, const char[] sReason) {
	g_iLastWinningTeam = iWinnerTeamIndex;
	g_iPendingStatsWinner = iWinnerTeamIndex; // consumed by Stop1v1's stats flush (wins/losses)
	strcopy(g_sMixEndReason, sizeof(g_sMixEndReason), sReason); // read by the results embed

	// Match results land in the SM logs until the elo system consumes them.
	LogMessage("[MIX] %s won the %dv%d (%s).", (iWinnerTeamIndex == __TEAM_T) ? "Team 1" : "Team 2", g_iCurrentPlayerMode, g_iCurrentPlayerMode, sReason);

	// Rating changes are applied by ApplyMixElo (called from Stop1v1 with
	// this winner, before the stats flush) - !rank and the leaderboards pick
	// the new values up automatically.

	Stop1v1();
}

// Mix stats: MySQL persistence + the end-of-mix chat scoreboard.

void ConnectStatsDatabase() {
	if(SQL_CheckConfig("mix")) {
		Database.Connect(OnStatsDbConnected, "mix");
	}
	else {
		Database.Connect(OnStatsDbConnected, "default");
	}
}

public void OnStatsDbConnected(Database db, const char[] error, any data) {
	if(db == null) {
		LogError("[MIX] Stats database connection failed - stats will not be persisted: %s", error);
		return;
	}

	g_hStatsDb = db;

	char sDriver[16];
	g_hStatsDb.Driver.GetIdentifier(sDriver, sizeof(sDriver));
	g_bStatsDbSQLite = StrEqual(sDriver, "sqlite");
	if(g_bStatsDbSQLite) {
		strcopy(g_sSqlMax, sizeof(g_sSqlMax), "MAX");
		strcopy(g_sSqlNow, sizeof(g_sSqlNow), "strftime('%s','now')");
	}
	else {
		g_hStatsDb.SetCharset("utf8mb4");
	}

	char sQuery[1024];
	FormatEx(sQuery, sizeof(sQuery),
		"CREATE TABLE IF NOT EXISTS `%s_stats` (\
		`steamid` VARCHAR(32) NOT NULL, \
		`name` VARCHAR(64) NOT NULL DEFAULT '', \
		`survival_time` INT NOT NULL DEFAULT 0, \
		`t_rounds` INT NOT NULL DEFAULT 0, \
		`stabs_given` INT NOT NULL DEFAULT 0, \
		`stabs_taken` INT NOT NULL DEFAULT 0, \
		`fall_damage` INT NOT NULL DEFAULT 0, \
		`clutches` INT NOT NULL DEFAULT 0, \
		`wins` INT NOT NULL DEFAULT 0, \
		`losses` INT NOT NULL DEFAULT 0, \
		`elo` INT NOT NULL DEFAULT 1000, \
		`last_played` INT NOT NULL DEFAULT 0, \
		PRIMARY KEY (`steamid`))",
		g_sSqlPrefix);
	g_hStatsDb.Query(SqlCallback_Generic, sQuery);

	// Schema evolution for tables created before these columns existed; the
	// duplicate-column error on up-to-date tables is expected and ignored.
	// SQLite doesn't support AFTER (column order doesn't matter anyway).
	FormatEx(sQuery, sizeof(sQuery),
		"ALTER TABLE `%s_stats` ADD COLUMN `clutches` INT NOT NULL DEFAULT 0%s",
		g_sSqlPrefix, g_bStatsDbSQLite ? "" : " AFTER `fall_damage`");
	g_hStatsDb.Query(SqlCallback_Silent, sQuery);

	// T-rounds played: the denominator for the average-survival stat.
	FormatEx(sQuery, sizeof(sQuery),
		"ALTER TABLE `%s_stats` ADD COLUMN `t_rounds` INT NOT NULL DEFAULT 0%s",
		g_sSqlPrefix, g_bStatsDbSQLite ? "" : " AFTER `survival_time`");
	g_hStatsDb.Query(SqlCallback_Silent, sQuery);

	// Elo column for tables predating the rating system.
	FormatEx(sQuery, sizeof(sQuery),
		"ALTER TABLE `%s_stats` ADD COLUMN `elo` INT NOT NULL DEFAULT 1000%s",
		g_sSqlPrefix, g_bStatsDbSQLite ? "" : " AFTER `losses`");
	g_hStatsDb.Query(SqlCallback_Silent, sQuery);

	// SteamID64 for profile links in the Discord embeds. Stored rather than
	// derived: converting the Steam2 id here would need 64-bit maths that
	// SourcePawn's 32-bit cells cannot do. Backfilled as players play.
	FormatEx(sQuery, sizeof(sQuery),
		"ALTER TABLE `%s_stats` ADD COLUMN `steamid64` VARCHAR(20) NOT NULL DEFAULT ''%s",
		g_sSqlPrefix, g_bStatsDbSQLite ? "" : " AFTER `steamid`");
	g_hStatsDb.Query(SqlCallback_Silent, sQuery);

	LogMessage("[MIX] Stats database connected (table prefix: %s).", g_sSqlPrefix);

	// Late connect: players already on the server still need their ratings.
	for(int i = 1; i <= MaxClients; i++) {
		if(IsClientInGame(i) && !IsFakeClient(i)) {
			LoadClientElo(i);
		}
	}
}

// Pulls the client's rating into the cache; stays at the default until a row exists. The cache is
// what the mix-end math runs on. One UPDATE the first time a player connects after the column
// was added, then never again. Only a live client can give a SteamID64, so this is the moment.
void BackfillClientSteamId64(int client) {
	if(g_hStatsDb == null || IsFakeClient(client)) {
		return;
	}

	char sAuth[32], sAuth64[24];
	if(!GetClientAuthCached(client, sAuth, sizeof(sAuth))) {
		return;
	}
	if(!GetClientAuthId(client, AuthId_SteamID64, sAuth64, sizeof(sAuth64))) {
		return;
	}

	// UPDATE, never INSERT: a player who has never banked stats should not get
	// a stats row just for connecting.
	char sQuery[256];
	FormatEx(sQuery, sizeof(sQuery),
		"UPDATE `%s_stats` SET steamid64 = '%s' WHERE steamid = '%s' AND steamid64 = ''",
		g_sSqlPrefix, sAuth64, sAuth);
	g_hStatsDb.Query(SqlCallback_Generic, sQuery);
}

// No pre-reset here. The query is async, so blanking the cache first makes every reader see
// MIX_DEFAULT_ELO until the callback lands - and ApplyMixElo re-reads each player right before
// the embed is built, which is exactly how every player showed 1000 Elo. ResetClientState
// already seeds the default at connect.
void LoadClientElo(int client) {
	if(g_hStatsDb == null || IsFakeClient(client)) {
		return;
	}

	char sAuth[32];
	if(!GetClientAuthCached(client, sAuth, sizeof(sAuth))) {
		return;
	}

	BackfillClientSteamId64(client);

	// Rank uses the same tie-break as !rank so the tag and the profile agree.
	char sQuery[768];
	FormatEx(sQuery, sizeof(sQuery),
		"SELECT elo, \
		(SELECT COUNT(*) + 1 FROM `%s_stats` s2 WHERE s2.elo > s1.elo OR (s2.elo = s1.elo \
		AND (s2.wins * 1.0 / %s(s2.wins + s2.losses, 1)) > (s1.wins * 1.0 / %s(s1.wins + s1.losses, 1)))) \
		FROM `%s_stats` s1 WHERE steamid = '%s' LIMIT 1",
		g_sSqlPrefix, g_sSqlMax, g_sSqlMax, g_sSqlPrefix, sAuth);
	g_hStatsDb.Query(SqlCallback_ClientElo, sQuery, GetClientUserId(client));
}

public void SqlCallback_ClientElo(Database db, DBResultSet results, const char[] error, any userid) {
	int client = GetClientOfUserId(userid);
	if(client < 1 || results == null || !results.FetchRow()) {
		return;
	}
	g_iaElo[client] = results.FetchInt(0);
	g_iaEloRank[client] = results.FetchInt(1);
	RefreshEloTag(client);
}

public void OnEloTagCvarChanged(ConVar convar, const char[] oldValue, const char[] newValue) {
	RefreshAllEloTags();
}

void RefreshAllEloTags() {
	for(int i = 1; i <= MaxClients; i++) {
		if(IsClientInGame(i) && !IsFakeClient(i)) {
			RefreshEloTag(i);
		}
	}
}

// Push this client's rank/elo prefix into HexTags, which owns both the chat
// prefix and the scoreboard clan tag. Stored as a prefix (not a tag) so a
// HexTags reload or the player picking their own tag cannot drop it.
void RefreshEloTag(int client) {
	if(client < 1 || client > MaxClients || !IsClientInGame(client) || IsFakeClient(client)) {
		return;
	}
	if(GetFeatureStatus(FeatureType_Native, "HexTags_SetClientPrefix") != FeatureStatus_Available) {
		return; // HexTags not loaded - nothing to push into
	}

	char sChat[64];
	char sScore[64];
	if(cv_EloTag.BoolValue) {
		char sRank[16];
		Mix_GetRankString(g_iaEloRank[client], sRank, sizeof(sRank));

		char sElo[16];
		IntToString(g_iaElo[client], sElo, sizeof(sElo));

		cv_EloTagChat.GetString(sChat, sizeof(sChat));
		// HexTags understands {default}; accept the older alias from an
		// existing server cvar without printing it literally in chat.
		ReplaceString(sChat, sizeof(sChat), "{white}", "{default}", false);
		ReplaceString(sChat, sizeof(sChat), "{rank}", sRank);
		ReplaceString(sChat, sizeof(sChat), "{elo}", sElo);

		cv_EloTagScore.GetString(sScore, sizeof(sScore));
		ReplaceString(sScore, sizeof(sScore), "{rank}", sRank);
		ReplaceString(sScore, sizeof(sScore), "{elo}", sElo);
	}

	// Guard on both formats: changing only the scoreboard cvar must still push.
	char sSeen[132];
	FormatEx(sSeen, sizeof(sSeen), "%s\x01%s", sChat, sScore);
	if(StrEqual(sSeen, g_saEloTag[client])) {
		return; // unchanged - don't re-push on every elo recalculation
	}
	strcopy(g_saEloTag[client], sizeof(g_saEloTag[]), sSeen);

	HexTags_SetClientPrefix(client, ChatTag, sChat);
	HexTags_SetClientPrefix(client, ScoreTag, sScore);
}

public void SqlCallback_Silent(Database db, DBResultSet results, const char[] error, any data) {
	// Best-effort query - failures here are expected (e.g. column exists).
}

public void SqlCallback_Generic(Database db, DBResultSet results, const char[] error, any data) {
	if(results == null) {
		LogError("[MIX] Stats query failed: %s", error);
	}
}

// Casual size: the end-of-mix scoreboard still shows everything but nothing persists - no elo, no
// wins/losses, nothing banked toward !rank. The verdict locks at match start: !add can grow the
// team size mid-mix, but a mix that went live casual stays casual.
bool IsCasualMix() {
	if(g_iMixCasualLock != -1) {
		return g_iMixCasualLock == 1;
	}
	return g_iCurrentPlayerMode <= cv_EloCasualMaxSize.IntValue;
}

// Adds this player's accumulators, and optionally a win/loss, onto their cumulative row. Zeroes
// the stab/fall counters afterwards so nothing double-counts; survival time is only zeroed when
// asked, since Stop1v1's wrap-up still needs fTimeSurvived.
void FlushPlayerMixStats(int client, int iWin, int iLoss, bool bZeroSurvival) {
	// Inherited (self-replace takeover) amounts count for team totals and
	// contribution, but NOT toward this player's own banked stats - only
	// what they earned themselves persists.
	int iSurvival = RoundToFloor(fTimeSurvived[client] - g_faInhSurvival[client]);
	int iGiven = g_iaMixStabsGiven[client] - g_iaInhStabsGiven[client];
	int iTaken = g_iaMixStabsTaken[client] - g_iaInhStabsTaken[client];
	int iFallDmg = g_iaMixFallDamage[client] - g_iaInhFallDamage[client];
	int iClutches = g_iaMixClutches[client] - g_iaInhClutches[client];
	int iTRounds = g_iaMixTRounds[client] - g_iaInhTRounds[client];
	if(iSurvival < 0) { iSurvival = 0; }
	if(iGiven < 0) { iGiven = 0; }
	if(iTaken < 0) { iTaken = 0; }
	if(iFallDmg < 0) { iFallDmg = 0; }
	if(iClutches < 0) { iClutches = 0; }
	if(iTRounds < 0) { iTRounds = 0; }

	g_iaMixStabsGiven[client] = 0;
	g_iaMixStabsTaken[client] = 0;
	g_iaMixFallDamage[client] = 0;
	g_iaMixClutches[client] = 0;
	g_iaMixTRounds[client] = 0;
	g_iaInhStabsGiven[client] = 0;
	g_iaInhStabsTaken[client] = 0;
	g_iaInhFallDamage[client] = 0;
	g_iaInhClutches[client] = 0;
	g_iaInhTRounds[client] = 0;
	g_faInhSurvival[client] = 0.0;
	if(bZeroSurvival) {
		fTimeSurvived[client] = 0.0;
	}

	if(IsCasualMix()) {
		return; // display-only: zeroed above, nothing banks to !rank / !lb
	}

	if(iSurvival == 0 && iGiven == 0 && iTaken == 0 && iFallDmg == 0 && iClutches == 0 && iTRounds == 0 && iWin == 0 && iLoss == 0) {
		return; // nothing worth a row
	}

	if(g_hStatsDb == null) {
		return; // no database - stats were display-only this mix
	}

	char sAuth[32];
	if(!GetClientAuthCached(client, sAuth, sizeof(sAuth))) {
		return;
	}

	char sName[MAX_NAME_LENGTH];
	GetClientName(client, sName, sizeof(sName));
	char sNameEsc[MAX_NAME_LENGTH * 2 + 1];
	g_hStatsDb.Escape(sName, sNameEsc, sizeof(sNameEsc));

	// Backfills steamid64 for the Discord profile links. Only the live client
	// can supply it, so every mix a player finishes tops it up.
	char sAuth64[24];
	if(!GetClientAuthId(client, AuthId_SteamID64, sAuth64, sizeof(sAuth64))) {
		sAuth64[0] = '\0';
	}

	char sQuery[1024];
	if(g_bStatsDbSQLite) {
		// No ON DUPLICATE KEY in SQLite: ensure the row, then add onto it.
		// Same-connection threaded queries run in order, so this is safe.
		FormatEx(sQuery, sizeof(sQuery),
			"INSERT OR IGNORE INTO `%s_stats` (steamid, name) VALUES ('%s', '%s')",
			g_sSqlPrefix, sAuth, sNameEsc);
		g_hStatsDb.Query(SqlCallback_Generic, sQuery);

		FormatEx(sQuery, sizeof(sQuery),
			"UPDATE `%s_stats` SET name = '%s', steamid64 = '%s', \
			survival_time = survival_time + %d, t_rounds = t_rounds + %d, \
			stabs_given = stabs_given + %d, stabs_taken = stabs_taken + %d, \
			fall_damage = fall_damage + %d, clutches = clutches + %d, \
			wins = wins + %d, losses = losses + %d, last_played = %s \
			WHERE steamid = '%s'",
			g_sSqlPrefix, sNameEsc, sAuth64, iSurvival, iTRounds, iGiven, iTaken, iFallDmg, iClutches, iWin, iLoss, g_sSqlNow, sAuth);
		g_hStatsDb.Query(SqlCallback_Generic, sQuery);
		return;
	}

	FormatEx(sQuery, sizeof(sQuery),
		"INSERT INTO `%s_stats` (steamid, steamid64, name, survival_time, t_rounds, stabs_given, stabs_taken, fall_damage, clutches, wins, losses, last_played) \
		VALUES ('%s', '%s', '%s', %d, %d, %d, %d, %d, %d, %d, %d, UNIX_TIMESTAMP()) \
		ON DUPLICATE KEY UPDATE \
		name = VALUES(name), \
		steamid64 = VALUES(steamid64), \
		survival_time = survival_time + VALUES(survival_time), \
		t_rounds = t_rounds + VALUES(t_rounds), \
		stabs_given = stabs_given + VALUES(stabs_given), \
		stabs_taken = stabs_taken + VALUES(stabs_taken), \
		fall_damage = fall_damage + VALUES(fall_damage), \
		clutches = clutches + VALUES(clutches), \
		wins = wins + VALUES(wins), \
		losses = losses + VALUES(losses), \
		last_played = VALUES(last_played)",
		g_sSqlPrefix, sAuth, sAuth64, sNameEsc, iSurvival, iTRounds, iGiven, iTaken, iFallDmg, iClutches, iWin, iLoss);
	g_hStatsDb.Query(SqlCallback_Generic, sQuery);
}

// Persists every roster member's mix. iWinnerTeamIndex is a __TEAM_* index, -1 meaning no result:
// activity stats save, wins/losses untouched. bZeroSurvival also zeroes fTimeSurvived, which the
// emergency flushes use so no later pass can re-bank.
void FlushAllMixStats(int iWinnerTeamIndex, bool bZeroSurvival = false) {
	for(int teamIndex = 0; teamIndex < PLAYER_TEAM_MAX; teamIndex++) {
		Player_t player;
		for(int i = 0; i < g_alPlayers[teamIndex].Length; i++) {
			g_alPlayers[teamIndex].GetArray(i, player, sizeof(Player_t));
			int c = player.clientIdx;
			if(c < 1 || !IsClientInGame(c) || IsFakeClient(c)) {
				continue;
			}

			int iWin = 0, iLoss = 0;
			if(iWinnerTeamIndex != -1) {
				if(teamIndex == iWinnerTeamIndex) {
					iWin = 1;
				}
				else {
					iLoss = 1;
				}
			}
			FlushPlayerMixStats(c, iWin, iLoss, bZeroSurvival);
		}
	}
}

// Elo engine. Zero-sum: the expected-result curve prices the pot from team-average ratings,
// winners split +pot and losers -pot exactly, and contribution C = 0.70 stabs + 0.25 survival
// + 0.05 clutches only moves points between teammates.

float fClampF(float fVal, float fMin, float fMax) {
	if(fVal < fMin) {
		return fMin;
	}
	if(fVal > fMax) {
		return fMax;
	}
	return fVal;
}

// Rating writes are self-contained INSERT..ON DUPLICATE, so they work
// whether or not the player has a stats row yet, in any order.
void QueueEloWrite(const char[] sAuth, const char[] sName, int iDelta) {
	if(g_hStatsDb == null || sAuth[0] == '\0' || iDelta == 0) {
		return;
	}

	char sNameEsc[MAX_NAME_LENGTH * 2 + 1];
	g_hStatsDb.Escape(sName, sNameEsc, sizeof(sNameEsc));

	int iNewIfInsert = MIX_DEFAULT_ELO + iDelta;
	if(iNewIfInsert < ELO_FLOOR) {
		iNewIfInsert = ELO_FLOOR;
	}

	char sQuery[512];
	if(g_bStatsDbSQLite) {
		// Ensure the row (elo defaults to 1000), then apply the floored delta.
		FormatEx(sQuery, sizeof(sQuery),
			"INSERT OR IGNORE INTO `%s_stats` (steamid, name) VALUES ('%s', '%s')",
			g_sSqlPrefix, sAuth, sNameEsc);
		g_hStatsDb.Query(SqlCallback_Generic, sQuery);

		FormatEx(sQuery, sizeof(sQuery),
			"UPDATE `%s_stats` SET elo = MAX(%d, elo + %d), last_played = %s WHERE steamid = '%s'",
			g_sSqlPrefix, ELO_FLOOR, iDelta, g_sSqlNow, sAuth);
		g_hStatsDb.Query(SqlCallback_Generic, sQuery);
		return;
	}

	FormatEx(sQuery, sizeof(sQuery),
		"INSERT INTO `%s_stats` (steamid, name, elo, last_played) VALUES ('%s', '%s', %d, UNIX_TIMESTAMP()) \
		ON DUPLICATE KEY UPDATE elo = GREATEST(%d, elo + %d), last_played = VALUES(last_played)",
		g_sSqlPrefix, sAuth, sNameEsc, iNewIfInsert, ELO_FLOOR, iDelta);
	g_hStatsDb.Query(SqlCallback_Generic, sQuery);
}

// Flat penalty for an ONLINE player (self-replace): cache + DB + notice.
void ApplyOnlineEloPenalty(int client, int iPenalty, const char[] sReason) {
	g_iaElo[client] -= iPenalty;
	if(g_iaElo[client] < ELO_FLOOR) {
		g_iaElo[client] = ELO_FLOOR;
	}

	char sAuth[32], sName[MAX_NAME_LENGTH];
	if(GetClientAuthCached(client, sAuth, sizeof(sAuth))) {
		GetClientName(client, sName, sizeof(sName));
		QueueEloWrite(sAuth, sName, -iPenalty);
	}

	MixPrintToChat(client, "Elo: \x02-%d\x08 (%s) - now \x0F%d\x08.", iPenalty, sReason, g_iaElo[client]);
	LogMessage("[MIX] %L elo -%d (%s), now %d.", client, iPenalty, sReason, g_iaElo[client]);
	LoadClientElo(client); // refresh rank + tag from the DB
}

// Self-replace stat takeover: the incoming player carries the leaver's current-mix stats so team
// totals stay whole, but the inherited amounts are excluded when banking - only what they earn
// AFTER the swap counts toward their own !rank.
void TransferMixStats(int iFrom, int iTo) {
	g_faInhSurvival[iTo] += fTimeSurvived[iFrom];
	fTimeSurvived[iTo] += fTimeSurvived[iFrom];
	g_iaInhStabsGiven[iTo] += g_iaMixStabsGiven[iFrom];
	g_iaMixStabsGiven[iTo] += g_iaMixStabsGiven[iFrom];
	g_iaInhStabsTaken[iTo] += g_iaMixStabsTaken[iFrom];
	g_iaMixStabsTaken[iTo] += g_iaMixStabsTaken[iFrom];
	g_iaInhFallDamage[iTo] += g_iaMixFallDamage[iFrom];
	g_iaMixFallDamage[iTo] += g_iaMixFallDamage[iFrom];
	g_iaInhClutches[iTo] += g_iaMixClutches[iFrom];
	g_iaMixClutches[iTo] += g_iaMixClutches[iFrom];
	g_iaInhTRounds[iTo] += g_iaMixTRounds[iFrom];
	g_iaMixTRounds[iTo] += g_iaMixTRounds[iFrom];

	// The leaver hands everything over (a chained takeover passes inherited
	// amounts along too, since the full accumulator moved into iTo's inherited).
	fTimeSurvived[iFrom] = 0.0;
	g_iaMixStabsGiven[iFrom] = 0;
	g_iaMixStabsTaken[iFrom] = 0;
	g_iaMixFallDamage[iFrom] = 0;
	g_iaMixClutches[iFrom] = 0;
	g_iaMixTRounds[iFrom] = 0;
	g_faInhSurvival[iFrom] = 0.0;
	g_iaInhStabsGiven[iFrom] = 0;
	g_iaInhStabsTaken[iFrom] = 0;
	g_iaInhFallDamage[iFrom] = 0;
	g_iaInhClutches[iFrom] = 0;
	g_iaInhTRounds[iFrom] = 0;
}

// The mix ended with a result: rate every seated roster player, then charge
// the abandon penalty to everyone who left and never got their spot back.
// Runs BEFORE FlushAllMixStats so the per-mix accumulators are still intact.
void ApplyMixElo(int iWinnerTeamIndex) {
	if(iWinnerTeamIndex == -1 || g_hStatsDb == null) {
		return; // aborted mix: no result, no ratings, no abandon charges
	}

	// Casual sizes: nothing persists - no elo swings, no abandon charges (and
	// FlushPlayerMixStats skips the stat/win-loss banking on its own).
	if(IsCasualMix()) {
		MixPrintToChatAll("Casual MIX size (\x0F%dv%d\x08) - no elo or stat changes.", g_iCurrentPlayerMode, g_iCurrentPlayerMode);
		return;
	}

	// Team averages from the cached ratings + team totals for the shares.
	float faAvgElo[PLAYER_TEAM_MAX];
	float faTotalSurv[PLAYER_TEAM_MAX];
	int iaTotalStabs[PLAYER_TEAM_MAX];
	int iaTotalClutches[PLAYER_TEAM_MAX];
	int iaCount[PLAYER_TEAM_MAX];

	Player_t player;
	for(int teamIndex = 0; teamIndex < PLAYER_TEAM_MAX; teamIndex++) {
		int iSum = 0;
		for(int i = 0; i < g_alPlayers[teamIndex].Length; i++) {
			g_alPlayers[teamIndex].GetArray(i, player, sizeof(Player_t));
			int c = player.clientIdx;
			if(c < 1 || !IsClientInGame(c) || IsFakeClient(c)) {
				continue;
			}
			iSum += g_iaElo[c];
			faTotalSurv[teamIndex] += fTimeSurvived[c];
			iaTotalStabs[teamIndex] += g_iaMixStabsGiven[c];
			iaTotalClutches[teamIndex] += g_iaMixClutches[c];
			iaCount[teamIndex]++;
		}
		faAvgElo[teamIndex] = (iaCount[teamIndex] > 0) ? float(iSum) / float(iaCount[teamIndex]) : float(MIX_DEFAULT_ELO);
	}

	if(iaCount[__TEAM_T] > 0 && iaCount[__TEAM_CT] > 0) {
		int iLoserTeam = (iWinnerTeamIndex == __TEAM_T) ? __TEAM_CT : __TEAM_T;

		// Zero-sum pot from the average-elo gap: equal teams give 15/player, favourites win less and lose
		// more. Winners split exactly +pot, losers exactly -pot, so the economy never inflates. Sized by
		// the SMALLER live roster so a short-handed side is not over-charged.
		float fExpWinner = 1.0 / (1.0 + Pow(10.0, (faAvgElo[iLoserTeam] - faAvgElo[iWinnerTeamIndex]) / cv_EloCurve.FloatValue));
		float fBaseMag = ELO_K * (1.0 - fExpWinner);
		int nSmall = (iaCount[iWinnerTeamIndex] < iaCount[iLoserTeam]) ? iaCount[iWinnerTeamIndex] : iaCount[iLoserTeam];
		int iPot = RoundToNearest(fBaseMag * float(nSmall));

		ApplyMixEloTeam(iWinnerTeamIndex, true, iPot, faTotalSurv[iWinnerTeamIndex], iaTotalStabs[iWinnerTeamIndex], iaTotalClutches[iWinnerTeamIndex]);
		ApplyMixEloTeam(iLoserTeam, false, iPot, faTotalSurv[iLoserTeam], iaTotalStabs[iLoserTeam], iaTotalClutches[iLoserTeam]);
	}

	// Abandon penalties: every DC entry still on file at mix end is someone
	// who left and never reclaimed their spot (replaced or not).
	if(!cv_AbandonPenalty.BoolValue) {
		return; // abandoning costs nothing on this server
	}

	DcPlayer_t dc;
	for(int i = 0; i < g_alDcPlayers.Length; i++) {
		g_alDcPlayers.GetArray(i, dc, sizeof(DcPlayer_t));
		QueueEloWrite(dc.sAuth, dc.sName, -ELO_ABANDON_PENALTY);
		LogMessage("[MIX] %s (%s) abandoned the mix: elo -%d.", dc.sName, dc.sAuth, ELO_ABANDON_PENALTY);

		// If they're back on the server (e.g. locked to spectator after being
		// replaced), keep their cache in step and tell them.
		int iOnline = FindClientByAuth(dc.sAuth);
		if(iOnline != -1) {
			g_iaElo[iOnline] -= ELO_ABANDON_PENALTY;
			if(g_iaElo[iOnline] < ELO_FLOOR) {
				g_iaElo[iOnline] = ELO_FLOOR;
			}
			MixPrintToChat(iOnline, "Elo: \x02-%d\x08 (abandoned the MIX) - now \x0F%d\x08.", ELO_ABANDON_PENALTY, g_iaElo[iOnline]);
		}
	}
}

// Splits the zero-sum pot across one team. Everyone starts from the even share; contribution
// (70% stabs, 25% survival, 5% clutches via rho) moves points BETWEEN teammates - carries take
// from passengers on a win, anchors shield contributors on a loss - so the team total always
// equals the pot. Largest-remainder rounding keeps it exact in integers, then a swap pass
// enforces the per-player 0..ELO_MAX_DELTA bound without changing the total.
// Contribution is a share of TEAM totals, so zero totals give a fair share - which is why
// clutches stay a light bonus. rho 1.0 = exactly average teammate. Shared with the results
// embed, which orders each team by this: two copies of the weighting would eventually disagree.
float MixContributionRho(int client, float fTotalSurv, int iTotalStabs, int iTotalClutches, int iSeated) {
	if(iSeated < 1) {
		return 1.0;
	}
	float fShareT = (fTotalSurv > 0.0) ? fTimeSurvived[client] / fTotalSurv : 1.0 / float(iSeated);
	float fShareS = (iTotalStabs > 0) ? float(g_iaMixStabsGiven[client]) / float(iTotalStabs) : 1.0 / float(iSeated);
	float fShareC = (iTotalClutches > 0) ? float(g_iaMixClutches[client]) / float(iTotalClutches) : 1.0 / float(iSeated);
	return (0.25 * fShareT + 0.70 * fShareS + 0.05 * fShareC) * float(iSeated);
}

void ApplyMixEloTeam(int teamIndex, bool bWinner, int iPot, float fTotalSurv, int iTotalStabs, int iTotalClutches) {
	if(iPot < 0) {
		return;
	}

	int iaClient[MAXPLAYERS + 1];
	float faPts[MAXPLAYERS + 1];
	float faRho[MAXPLAYERS + 1];
	int n = 0;
	float fPtsSum = 0.0;

	// Roster size for the fair-share fallbacks (matches iaCount upstream).
	int iSeated = 0;
	Player_t player;
	for(int i = 0; i < g_alPlayers[teamIndex].Length; i++) {
		g_alPlayers[teamIndex].GetArray(i, player, sizeof(Player_t));
		int c = player.clientIdx;
		if(c >= 1 && IsClientInGame(c) && !IsFakeClient(c)) {
			iSeated++;
		}
	}
	if(iSeated < 1) {
		return;
	}

	for(int i = 0; i < g_alPlayers[teamIndex].Length; i++) {
		g_alPlayers[teamIndex].GetArray(i, player, sizeof(Player_t));
		int c = player.clientIdx;
		if(c < 1 || !IsClientInGame(c) || IsFakeClient(c)) {
			continue;
		}

		float fRho = MixContributionRho(c, fTotalSurv, iTotalStabs, iTotalClutches, iSeated);

		// Winners: more rho = more points. Losers: more rho = fewer points
		// (points below become a SMALLER share of the team's loss).
		float fPts;
		if(bWinner) {
			fPts = cv_EloContribAvg.FloatValue + cv_EloContribSlope.FloatValue * (fRho - 1.0);
		}
		else {
			fPts = cv_EloContribAvg.FloatValue - cv_EloContribSlope.FloatValue * (fRho - 1.0);
		}
		fPts = fClampF(fPts, 0.0, cv_EloContribMax.FloatValue);

		iaClient[n] = c;
		faRho[n] = fRho;
		faPts[n] = fPts;
		fPtsSum += fPts;
		n++;
	}

	if(n < 1) {
		return;
	}

	// Even pot share + mean-centered contribution spread: the raw amounts sum
	// to the pot exactly, whatever the points came out as.
	float fMeanPts = fPtsSum / float(n);
	float fShare = float(iPot) / float(n);

	int iaDelta[MAXPLAYERS + 1];
	float faRem[MAXPLAYERS + 1];
	int iAllocated = 0;
	for(int i = 0; i < n; i++) {
		float fRaw = fShare + (faPts[i] - fMeanPts);
		iaDelta[i] = RoundToFloor(fRaw);
		faRem[i] = fRaw - float(iaDelta[i]);
		iAllocated += iaDelta[i];
	}

	// Largest-remainder rounding: the leftover pot points go to the biggest
	// fractional remainders, so the integer total hits the pot exactly.
	for(int iLeft = iPot - iAllocated; iLeft > 0; iLeft--) {
		int iBest = 0;
		for(int i = 1; i < n; i++) {
			if(faRem[i] > faRem[iBest]) {
				iBest = i;
			}
		}
		iaDelta[iBest]++;
		faRem[iBest] = -1.0;
	}

	// Bound every delta to 0..ELO_MAX_DELTA by shifting single points between
	// the extremes - the team total never changes. Always terminates: the pot
	// fits (0 <= pot <= n * ELO_MAX_DELTA).
	for(;;) {
		int iHi = 0, iLo = 0;
		for(int i = 1; i < n; i++) {
			if(iaDelta[i] > iaDelta[iHi]) { iHi = i; }
			if(iaDelta[i] < iaDelta[iLo]) { iLo = i; }
		}
		if(iaDelta[iHi] > ELO_MAX_DELTA && iaDelta[iLo] < ELO_MAX_DELTA) {
			iaDelta[iHi]--;
			iaDelta[iLo]++;
			continue;
		}
		if(iaDelta[iLo] < 0 && iaDelta[iHi] > 0) {
			iaDelta[iLo]++;
			iaDelta[iHi]--;
			continue;
		}
		break;
	}

	// Apply with the team's sign; the DB write floors at ELO_FLOOR.
	for(int i = 0; i < n; i++) {
		int c = iaClient[i];
		int iDelta = bWinner ? iaDelta[i] : -iaDelta[i];

		g_iaElo[c] += iDelta;
		if(g_iaElo[c] < ELO_FLOOR) {
			g_iaElo[c] = ELO_FLOOR;
		}

		char sAuth[32], sName[MAX_NAME_LENGTH];
		if(GetClientAuthCached(c, sAuth, sizeof(sAuth))) {
			GetClientName(c, sName, sizeof(sName));
			QueueEloWrite(sAuth, sName, iDelta);
		}

		MixPrintToChat(c, "Elo: %s%s%d\x08 - now \x0F%d\x08.", iDelta >= 0 ? "\x04+" : "\x02", iDelta >= 0 ? "" : "", iDelta, g_iaElo[c]);
		LogMessage("[MIX] %L elo %+d (%s, contribution %.2f), now %d.", c, iDelta, bWinner ? "win" : "loss", faRho[i], g_iaElo[c]);

		// Re-read rank from the DB: this mix moved people past each other, so a
		// local recompute would disagree with !rank.
		LoadClientElo(c);
	}
}

// Clutches: +1 for every roster player who played T this round and survived to the end. Counted
// once per round, at round end, BEFORE the side flag toggles. The minimum-duration guard keeps
// artifacts out - the mp_restartgame at match start fires a round_end nobody played.
void CountRoundClutches() {
	if(!g_Init || g_iRoundSerial == g_iLastClutchRound) {
		return;
	}
	if(GetGameTime() - g_fRoundStartedAt < 30.0) {
		return;
	}
	g_iLastClutchRound = g_iRoundSerial;

	// The roster playing the T side this round (flag not yet toggled).
	int teamIndex = g_bDidSwitchTeams ? __TEAM_CT : __TEAM_T;

	Player_t player;
	for(int i = 0; i < g_alPlayers[teamIndex].Length; i++) {
		g_alPlayers[teamIndex].GetArray(i, player, sizeof(Player_t));
		int c = player.clientIdx;
		if(c < 1 || !IsClientInGame(c) || IsFakeClient(c)) {
			continue;
		}
		if(g_baDeadThisRound[c]) {
			continue; // died this round - no clutch
		}
		if(GetClientTeam(c) < CS_TEAM_T) {
			continue; // benched in spectator - didn't play the round out
		}
		g_iaMixClutches[c]++;
	}
}

// Rounds-played tally, the denominator of average survival: +1 for every seated roster player on
// T this round, survived or not. Only rounds that STARTED while the mix was live count, so the
// pre-mix restart never inflates it.
void CountRoundTRounds() {
	if(!g_Init || !g_bMixRoundWasLive) {
		return;
	}

	// The roster playing the T side this round (flag not yet toggled).
	int teamIndex = g_bDidSwitchTeams ? __TEAM_CT : __TEAM_T;

	Player_t player;
	for(int i = 0; i < g_alPlayers[teamIndex].Length; i++) {
		g_alPlayers[teamIndex].GetArray(i, player, sizeof(Player_t));
		int c = player.clientIdx;
		if(c < 1 || !IsClientInGame(c) || IsFakeClient(c)) {
			continue;
		}
		if(GetClientTeam(c) < CS_TEAM_T) {
			continue; // benched in spectator - didn't play this round
		}
		g_iaMixTRounds[c]++;
	}
}

// Discord end-of-mix results embed. Built in Discord's raw embed schema
// (thumbnail/footer/fields objects) and posted straight to the webhook.

void SendMixDiscordResults(int iWinnerTeamIndex) {
	if(iWinnerTeamIndex == -1) {
		return; // aborted mix
	}

	char sUrl[256];
	cv_DiscordWebhook.GetString(sUrl, sizeof(sUrl));
	if(!sUrl[0]) {
		return; // feature off
	}

	// sMap stays the real name for the thumbnail URL; sShortMap is the display
	// form, trimmed the same way the status card trims it.
	char sMap[64], sShortMap[64];
	GetCurrentMap(sMap, sizeof(sMap));
	GetStatusMapName(sMap, sShortMap, sizeof(sShortMap));

	JSONObject hEmbed = new JSONObject();

	char sBuf[512];
	char sPrefix[64];
	cv_DiscordPrefix.GetString(sPrefix, sizeof(sPrefix));
	FormatEx(sBuf, sizeof(sBuf), "🔶 %s MIX (%dv%d) - Final Results", sPrefix, g_iCurrentPlayerMode, g_iCurrentPlayerMode);
	hEmbed.SetString("title", sBuf);
	hEmbed.SetInt("color", 15105570); // orange

	char sHost[128];
	FindConVar("hostname").GetString(sHost, sizeof(sHost));
	int iMatchSecs = RoundToNearest(GetEngineTime() - g_fMixMatchStart);
	// Went live ranked but is being banked as casual: an !add / !forceadd left
	// the teams uneven. Say it outright, or the absent ELO reads as a bug.
	char sDowngrade[160];
	sDowngrade[0] = '\0';
	if(g_bMixWentLiveRanked && IsCasualMix()) {
		strcopy(sDowngrade, sizeof(sDowngrade),
			"\n*Ranked → Casual - due to teams becoming uneven from !add.*");
	}

	FormatEx(sBuf, sizeof(sBuf),
		"*Duration: **%d secs***\n*Match duration: **%d mins and %d secs***\n*Map:* `%s`\n*Server: **%s***%s",
		RoundToNearest(g_fMixConfiguredTime), iMatchSecs / 60, iMatchSecs % 60, sShortMap, sHost, sDowngrade);
	hEmbed.SetString("description", sBuf);

	// Map picture in the top-right corner (embed thumbnail).
	char sThumb[256];
	cv_DiscordMapImage.GetString(sThumb, sizeof(sThumb));
	if(sThumb[0]) {
		ReplaceString(sThumb, sizeof(sThumb), "{MAP}", sMap);
		JSONObject hThumbObj = new JSONObject();
		hThumbObj.SetString("url", sThumb);
		hEmbed.Set("thumbnail", hThumbObj);
		delete hThumbObj;
	}

	// Two inline fields = the side-by-side team columns.
	JSONArray hFields = new JSONArray();
	AddMixDiscordTeamField(hFields, __TEAM_T, 1, iWinnerTeamIndex);
	AddMixDiscordTeamField(hFields, __TEAM_CT, 2, iWinnerTeamIndex);
	AddMixDiscordSpectatorField(hFields);
	AddMixDiscordDcField(hFields);
	hEmbed.Set("fields", hFields);
	delete hFields;

	FormatTime(sBuf, sizeof(sBuf), "Date: %Y-%m-%d | Time: %H:%M:%S (%Z)");
	JSONObject hFooter = new JSONObject();
	hFooter.SetString("text", sBuf);
	hEmbed.Set("footer", hFooter);
	delete hFooter;

	PostDiscordEmbed(sUrl, hEmbed); // takes hEmbed
}

// One team column: "Team N - 🏆 WON (time left)" with team elo and a block
// per player (flag, profile-linked name, elo, survival, stabs, fall dmg, DCs).
void AddMixDiscordTeamField(JSONArray hFields, int teamIndex, int iTeamNumber, int iWinnerTeamIndex) {
	bool bWinner = (teamIndex == iWinnerTeamIndex);
	int iTimeLeft = RoundToNearest(g_TeamTimer[teamIndex]);
	if(iTimeLeft < 0) {
		iTimeLeft = 0;
	}

	// time is the ordinary ending and needs no label. Anything else means the match did not run its
	// clock out, which reads as a forfeit either way, so surrenders are labelled the same. Marked on
	// the LOSING side, since that is the team it says something about.
	char sHow[24];
	sHow[0] = '\0';
	if(!bWinner && g_sMixEndReason[0] && !StrEqual(g_sMixEndReason, "time", false)) {
		strcopy(sHow, sizeof(sHow), " - FORFEITED");
	}

	char sName[64];
	FormatEx(sName, sizeof(sName), "Team %d - %s%s (%ds)", iTeamNumber, bWinner ? "🏆 WON" : "❌ LOST", sHow, iTimeLeft);

	int iCaptain = (teamIndex == __TEAM_CT) ? g_iCTCaptain : g_iTCaptain;
	bool bCaptainValid = (iCaptain >= 1 && IsClientInGame(iCaptain) && !IsFakeClient(iCaptain));

	// Collect the roster once, with the team totals the contribution share needs.
	int iaClients[MAXPLAYERS + 1];
	float faRho[MAXPLAYERS + 1];
	int n = 0;
	int iTeamElo = 0;
	float fTotalSurv = 0.0;
	int iTotalStabs = 0, iTotalClutches = 0;

	Player_t player;
	for(int i = 0; i < g_alPlayers[teamIndex].Length; i++) {
		g_alPlayers[teamIndex].GetArray(i, player, sizeof(Player_t));
		int c = player.clientIdx;
		if(c >= 1 && IsClientInGame(c) && !IsFakeClient(c)) {
			iTeamElo += g_iaElo[c];
			fTotalSurv += fTimeSurvived[c];
			iTotalStabs += g_iaMixStabsGiven[c];
			iTotalClutches += g_iaMixClutches[c];
			iaClients[n++] = c;
		}
	}

	// A captain who somehow is not on the roster array would otherwise vanish
	// from the listing entirely once the separate captain line is gone.
	if(bCaptainValid) {
		bool bFound = false;
		for(int i = 0; i < n; i++) {
			if(iaClients[i] == iCaptain) {
				bFound = true;
				break;
			}
		}
		if(!bFound) {
			iaClients[n++] = iCaptain;
		}
	}

	for(int i = 0; i < n; i++) {
		faRho[i] = MixContributionRho(iaClients[i], fTotalSurv, iTotalStabs, iTotalClutches, n);
	}

	// Insertion sort, highest contribution first. n is at most the team size.
	for(int i = 1; i < n; i++) {
		int iClient = iaClients[i];
		float fRho = faRho[i];
		int j = i - 1;
		while(j >= 0 && faRho[j] < fRho) {
			iaClients[j + 1] = iaClients[j];
			faRho[j + 1] = faRho[j];
			j--;
		}
		iaClients[j + 1] = iClient;
		faRho[j + 1] = fRho;
	}

	// 1024 is Discord's field-value limit; overflow just truncates the tail.
	// Casual mixes carry no elo, so none is shown.
	char sValue[1024];
	if(IsCasualMix()) {
		strcopy(sValue, sizeof(sValue), "*Casual MIX - no ELO at stake*\n");
	}
	else {
		FormatEx(sValue, sizeof(sValue), "*Team ELO: **%d***\n", iTeamElo);
	}

	// Contribution order, not captain-first. The captain keeps the "C:" marker
	// wherever they land.
	for(int i = 0; i < n; i++) {
		AppendMixDiscordPlayerLines(sValue, sizeof(sValue), iaClients[i],
			bCaptainValid && iaClients[i] == iCaptain);
	}

	AddEmbedField(hFields, sName, sValue, true);
}

// ---- Shared Discord plumbing --------------------------------------------
// ripext JSON handles are ordinary SM handles: Set/Push do NOT take ownership,
// so every handle created here is deleted here.

bool DiscordReady() {
	return (GetFeatureStatus(FeatureType_Native, "HTTPRequest.HTTPRequest") == FeatureStatus_Available);
}

// Wraps one embed in a webhook payload. Caller still owns hEmbed.
JSONObject BuildDiscordPayload(JSONObject hEmbed) {
	JSONArray hEmbeds = new JSONArray();
	hEmbeds.Push(hEmbed);

	JSONObject hPayload = new JSONObject();
	hPayload.Set("embeds", hEmbeds);

	char sBotName[64];
	cv_DiscordName.GetString(sBotName, sizeof(sBotName));
	if(sBotName[0]) {
		hPayload.SetString("username", sBotName);
	}

	delete hEmbeds;
	return hPayload;
}

// Fire-and-forget post for embeds that are never edited (the results embed).
void PostDiscordEmbed(const char[] sUrl, JSONObject hEmbed) {
	if(!DiscordReady()) {
		LogError("[MIX] REST in Pawn is not loaded - the Discord embed was not sent.");
		delete hEmbed;
		return;
	}

	JSONObject hPayload = BuildDiscordPayload(hEmbed);
	HTTPRequest hRequest = new HTTPRequest(sUrl);
	hRequest.Post(hPayload, OnDiscordPostDone);

	delete hPayload;
	delete hEmbed;
}

public void OnDiscordPostDone(HTTPResponse response, any value, const char[] sError) {
	if(sError[0] != '\0') {
		LogError("[MIX] Discord post failed: %s", sError);
		return;
	}
	int iStatus = view_as<int>(response.Status);
	if(iStatus < 200 || iStatus > 299) {
		LogError("[MIX] Discord rejected an embed (HTTP %d).", iStatus);
	}
}

// Delete a webhook message we previously posted. Fire and forget: if it is
// already gone the 404 is exactly the outcome we wanted anyway.
void DeleteDiscordMessage(const char[] sUrl, const char[] sMessageId) {
	if(!DiscordReady() || !sUrl[0] || !sMessageId[0]) {
		return;
	}

	char sTarget[640];
	FormatEx(sTarget, sizeof(sTarget), "%s/messages/%s", sUrl, sMessageId);

	HTTPRequest hRequest = new HTTPRequest(sTarget);
	hRequest.Delete(OnDiscordDeleteDone);
}

public void OnDiscordDeleteDone(HTTPResponse response, any value, const char[] sError) {
	// Nothing to do either way - the id has already been forgotten by the
	// caller, so a failure here only leaves a stale card behind, not a bug.
}

// Discord truncates a field value past this, and a cut landing inside a
// [name](url) renders the raw markdown instead of clipping cleanly.
#define MIX_EMBED_FIELD_MAX 1024

// Appends a whole entry or nothing at all. Returns false when it would not fit,
// so callers can stop adding rows rather than emit a half-written one.
bool AppendEmbedEntry(char[] sBuf, int iMaxLen, const char[] sEntry) {
	int iCap = (iMaxLen < MIX_EMBED_FIELD_MAX) ? iMaxLen : MIX_EMBED_FIELD_MAX;
	if(strlen(sBuf) + strlen(sEntry) >= iCap - 1) {
		return false;
	}
	StrCat(sBuf, iMaxLen, sEntry);
	return true;
}

// Adds one field to an embed's field array.
void AddEmbedField(JSONArray hFields, const char[] sName, const char[] sValue, bool bInline) {
	JSONObject hField = new JSONObject();
	hField.SetString("name", sName);
	hField.SetString("value", sValue);
	hField.SetBool("inline", bInline);
	hFields.Push(hField);
	delete hField;
}

// ---- Live server-status embed -------------------------------------------
// One message edited in place forever: server identity, population, and while a mix runs its
// size, phase and rosters. Explicitly NOT the end-of-mix results, which is a separate embed.

void AddStatusField(JSONArray hFields, const char[] sName, const char[] sValue, bool bInline) {
	AddEmbedField(hFields, sName, sValue, bInline);
}

// Roster team index whose players are currently on iCsTeam, or -1. Read from
// the live sides rather than g_bDidSwitchTeams so a knife-round swap can't
// desync the labels from reality.
int GetRosterIndexOnSide(int iCsTeam) {
	Player_t player;
	for(int t = 0; t < PLAYER_TEAM_MAX; t++) {
		if(g_alPlayers[t] == null) {
			continue;
		}
		for(int i = 0; i < g_alPlayers[t].Length; i++) {
			g_alPlayers[t].GetArray(i, player, sizeof(Player_t));
			int c = player.clientIdx;
			if(c >= 1 && IsClientInGame(c) && GetClientTeam(c) == iCsTeam) {
				return t;
			}
		}
	}
	return -1;
}

// Compact connection age for the live status roster: 57s, 13m, or 2h.
void FormatStatusConnectionAge(int client, char[] sOut, int iMaxLen) {
	int iSeconds = RoundToFloor(GetClientTime(client));
	if(iSeconds < 60) {
		FormatEx(sOut, iMaxLen, "%ds", iSeconds);
	}
	else if(iSeconds < 3600) {
		FormatEx(sOut, iMaxLen, "%dm", iSeconds / 60);
	}
	else {
		FormatEx(sOut, iMaxLen, "%dh", iSeconds / 3600);
	}
}

// STEAM_X:Y:Z -> 64-bit community id, as a string.
// SteamID64 = 76561197960265728 + Z*2 + Y, which does not fit in a 32-bit cell. Split the
// constant as A*10^9 + B and carry by hand: B + accountId would overflow, so measure the room
// below 10^9 first. Every intermediate stays inside int32. Done here rather than in SQL because
// the two dialects need different string functions and a silent NULL yields an unlinked name.
bool Mix_SteamID2To64(const char[] sSteam2, char[] sOut, int iMaxLen) {
	sOut[0] = '\0';

	// Expect STEAM_x:Y:Z - anything else (BOT, UNKNOWN, blank) has no profile.
	if(StrContains(sSteam2, "STEAM_", false) != 0) {
		return false;
	}

	char sParts[4][24];
	if(ExplodeString(sSteam2, ":", sParts, sizeof(sParts), sizeof(sParts[])) != 3) {
		return false;
	}

	int iY = StringToInt(sParts[1]);
	int iZ = StringToInt(sParts[2]);
	if(iZ <= 0 || iY < 0 || iY > 1) {
		return false;
	}

	// Explicit bound rather than relying on the multiply wrapping negative:
	// anything above this would overflow iZ * 2 and is far beyond any real
	// account id anyway.
	if(iZ > 1073741823) {
		return false;
	}

	int iAccount = iZ * 2 + iY;

	int iHigh = 76561197;
	int iLow = 960265728;
	int iRoom = 1000000000 - iLow;

	if(iAccount < iRoom) {
		iLow += iAccount;
	}
	else {
		int iRemainder = iAccount - iRoom;
		iHigh += 1 + (iRemainder / 1000000000);
		iLow = iRemainder % 1000000000;
	}

	FormatEx(sOut, iMaxLen, "%d%09d", iHigh, iLow);
	return true;
}

// Appends one linked live player to a Discord status-team roster.
// Returns false when the field is full, so the caller can report the overflow
// instead of silently showing fewer people than its header claims.
bool AppendStatusRosterPlayer(int client, char[] sOut, int iMaxLen) {
	char sFlag[12];
	GetMixCountryFlag(client, sFlag, sizeof(sFlag));

	char sName[MAX_NAME_LENGTH];
	GetClientName(client, sName, sizeof(sName));
	TruncateMixName(sName, cv_DiscordNameMax.IntValue);
	SanitizeMixDiscordName(sName, sizeof(sName));

	char sProfile[192], sAuth64[24];
	if(GetClientAuthId(client, AuthId_SteamID64, sAuth64, sizeof(sAuth64))) {
		FormatEx(sProfile, sizeof(sProfile), "[%s](https://steamcommunity.com/profiles/%s)", sName, sAuth64);
	}
	else {
		strcopy(sProfile, sizeof(sProfile), sName);
	}

	char sAge[12];
	FormatStatusConnectionAge(client, sAge, sizeof(sAge));

	char sEntry[256];
	FormatEx(sEntry, sizeof(sEntry), "%s%s%s `%s`\n", sFlag, sFlag[0] ? " " : "", sProfile, sAge);
	return AppendEmbedEntry(sOut, iMaxLen, sEntry);
}

// Everyone sitting out, whether or not a mix is running. Driven off the live team rather than the
// roster, so it covers spectators during a mix, replaced players locked to spec, and idlers
// alike. CS_TEAM_NONE counts too: that is where a client sits before it picks.
int BuildStatusSpectators(char[] sOut, int iMaxLen) {
	sOut[0] = '\0';

	int iCount = 0, iShown = 0;
	for(int c = 1; c <= MaxClients; c++) {
		if(!IsClientInGame(c) || IsFakeClient(c) || IsClientSourceTV(c)) {
			continue;
		}
		if(GetClientTeam(c) > CS_TEAM_SPECTATOR) {
			continue;
		}
		iCount++;
		if(AppendStatusRosterPlayer(c, sOut, iMaxLen)) {
			iShown++;
		}
	}

	AppendStatusOverflowNote(sOut, iMaxLen, iCount - iShown);
	if(!sOut[0]) {
		strcopy(sOut, iMaxLen, "*empty*");
	}
	return iCount;
}

// The header reports the true headcount, so a clipped list has to say so.
void AppendStatusOverflowNote(char[] sOut, int iMaxLen, int iHidden) {
	if(iHidden <= 0) {
		return;
	}
	char sMore[48];
	FormatEx(sMore, sizeof(sMore), "*...and %d more*\n", iHidden);
	StrCat(sOut, iMaxLen, sMore);
}

// "flag Name 4m" per line. During a mix it retains the picked roster; when
// idle it instead shows every human currently on the requested live side.
int BuildStatusRoster(int iCsTeam, char[] sOut, int iMaxLen) {
	sOut[0] = '\0';

	int iCount = 0, iShown = 0;
	if(MixStatusHasMix()) {
		Player_t player;
		for(int t = 0; t < PLAYER_TEAM_MAX; t++) {
			if(g_alPlayers[t] == null) {
				continue;
			}
			for(int i = 0; i < g_alPlayers[t].Length; i++) {
				g_alPlayers[t].GetArray(i, player, sizeof(Player_t));
				int c = player.clientIdx;
				if(c < 1 || !IsClientInGame(c) || IsFakeClient(c) || GetClientTeam(c) != iCsTeam) {
					continue;
				}
				iCount++;
				if(AppendStatusRosterPlayer(c, sOut, iMaxLen)) {
					iShown++;
				}
			}
		}
	}
	else {
		for(int c = 1; c <= MaxClients; c++) {
			if(!IsClientInGame(c) || IsFakeClient(c) || GetClientTeam(c) != iCsTeam) {
				continue;
			}
			iCount++;
			if(AppendStatusRosterPlayer(c, sOut, iMaxLen)) {
				iShown++;
			}
		}
	}

	AppendStatusOverflowNote(sOut, iMaxLen, iCount - iShown);
	if(!sOut[0]) {
		strcopy(sOut, iMaxLen, "*empty*");
	}
	return iCount;
}

// "flag Country" for the status embed. The cvar is an override; left empty it
// GeoIPs the server's own address, so a normal install needs no configuration.
bool FormatCountryFlag(const char[] sCode, char[] sOut, int iMaxLen) {
	if(sCode[0] < 'A' || sCode[0] > 'Z' || sCode[1] < 'A' || sCode[1] > 'Z') {
		sOut[0] = '\0';
		return false;
	}
	FormatEx(sOut, iMaxLen, "\xF0\x9F\x87%c\xF0\x9F\x87%c", 0xA6 + (sCode[0] - 'A'), 0xA6 + (sCode[1] - 'A'));
	return true;
}

// Converts an optional "GB United Kingdom" override into "flag United Kingdom".
void NormalizeServerLocation(char[] sLocation, int iMaxLen) {
	if(!(sLocation[0] >= 'A' && sLocation[0] <= 'Z'
		&& sLocation[1] >= 'A' && sLocation[1] <= 'Z' && sLocation[2] == ' ')) {
		return;
	}

	char sCode[3];
	sCode[0] = sLocation[0];
	sCode[1] = sLocation[1];
	sCode[2] = '\0';

	char sFlag[12];
	if(!FormatCountryFlag(sCode, sFlag, sizeof(sFlag))) {
		return;
	}

	char sCountry[96];
	strcopy(sCountry, sizeof(sCountry), sLocation[3]);
	FormatEx(sLocation, iMaxLen, "%s %s", sFlag, sCountry);
}

void GetServerLocation(char[] sOut, int iMaxLen) {
	cv_StatusLocation.GetString(sOut, iMaxLen);
	if(sOut[0]) {
		NormalizeServerLocation(sOut, iMaxLen);
		return;
	}

	int iIp = FindConVar("hostip").IntValue;
	if(iIp == 0) {
		return; // no public address bound - hide the field
	}

	char sIp[32];
	FormatEx(sIp, sizeof(sIp), "%d.%d.%d.%d",
		(iIp >> 24) & 0xFF, (iIp >> 16) & 0xFF, (iIp >> 8) & 0xFF, iIp & 0xFF);

	char sCode[3], sCountry[64];
	if(!GeoipCode2(sIp, sCode) || !GeoipCountry(sIp, sCountry, sizeof(sCountry))) {
		return; // LAN/private address, or no GeoIP data
	}

	char sFlag[12];
	if(!FormatCountryFlag(sCode, sFlag, sizeof(sFlag))) {
		strcopy(sOut, iMaxLen, sCountry);
		return;
	}
	if(sCountry[0] == sCode[0] && sCountry[1] == sCode[1] && sCountry[2] == ' ') {
		strcopy(sCountry, sizeof(sCountry), sCountry[3]);
	}
	FormatEx(sOut, iMaxLen, "%s %s", sFlag, sCountry);
}

// Human-readable phase of whatever the mix is doing right now.
void GetMixStatusPhase(char[] sOut, int iMaxLen) {
	if(g_iKnifeStage != KNIFE_NONE) {
		strcopy(sOut, iMaxLen, "Knife round");
		return;
	}
	if(g_Init) {
		if(g_bMatchPaused) {
			strcopy(sOut, iMaxLen, "Paused");
			return;
		}
		// <t:UNIX:R> renders as "14 minutes ago" and ticks in every viewer's
		// client. Formatting the elapsed time here instead would change the
		// embed body every single second, which is what forced the old poll.
		int iStartedUnix = GetTime() - RoundToNearest(GetEngineTime() - g_fMixMatchStart);
		FormatEx(sOut, iMaxLen, "Playing since <t:%d:R>", iStartedUnix);
		return;
	}
	switch(g_gameState) {
		case eGameState_PickingPlayers:     { strcopy(sOut, iMaxLen, "Picking players"); }
		case eGameState_DonePickingPlayers: { strcopy(sOut, iMaxLen, "Ready to start"); }
		default:                            { strcopy(sOut, iMaxLen, "Setting up"); }
	}
}

bool MixStatusHasMix() {
	return (g_Init || g_gameState != eGameState_None || g_iCTCaptain != -1 || g_iTCaptain != -1);
}

// Manual only. MaxClients reports the slots the ENGINE allocated and sv_visiblemaxplayers is -1
// here, so nothing on the box declares the real limit. It only exists as intent, so a plain
// cvar it is. The map time limit is normally disabled, so GetMapTimeLeft() stays at zero and the
// game-rules round clock is the timer players actually see.
int GetStatusRoundTimeLeft() {
	// The gamerules entity does not exist during map load or right after a
	// plugin reload, and reading a prop off it then raises a native error that
	// aborts the whole status refresh. Fall back to the configured round time.
	if(FindEntityByClassname(-1, "cs_gamerules") == -1) {
		return RoundToCeil(cv_RoundTime.FloatValue * 60.0);
	}

	// Between rounds the finished round's clock has already expired, so the live
	// calculation below yields 0 and the card sits on "Timeleft: 0s" until the
	// next round starts. Report what the next round will begin with instead.
	if(g_bBetweenRounds) {
		return RoundToCeil(cv_RoundTime.FloatValue * 60.0);
	}

	int iRoundSeconds = GameRules_GetProp("m_iRoundTime");
	float fRoundStartedAt = GameRules_GetPropFloat("m_fRoundStartTime");
	if(iRoundSeconds > 0 && fRoundStartedAt > 0.0) {
		int iTimeLeft = RoundToCeil(fRoundStartedAt + float(iRoundSeconds) - GetGameTime());
		return (iTimeLeft > 0) ? iTimeLeft : 0;
	}

	return RoundToCeil(cv_RoundTime.FloatValue * 60.0);
}

// Keep the status card compact without changing the actual map name used by
// the server, nomination, or image URL.
void GetStatusMapName(const char[] sMap, char[] sOut, int iMaxLen) {
	strcopy(sOut, iMaxLen, sMap);
	// Everything from "_mook" onward is server-side naming, including the
	// revision suffix: mix_croydonpark_mook_v2 reads as mix_croydonpark.
	int iCut = StrContains(sOut, "_mook", false);
	if(iCut > 0) {
		sOut[iCut] = '\0';
	}
}

void RefreshMixStatusEmbed(bool bForce) {
	char sUrl[512];
	cv_StatusWebhook.GetString(sUrl, sizeof(sUrl));
	if(!sUrl[0]) {
		return;
	}

	char sMap[64], sStatusMap[64];
	GetCurrentMap(sMap, sizeof(sMap));
	GetStatusMapName(sMap, sStatusMap, sizeof(sStatusMap));

	char sHost[128];
	FindConVar("hostname").GetString(sHost, sizeof(sHost));

	char sIp[64];
	cv_StatusIp.GetString(sIp, sizeof(sIp));
	if(!sIp[0]) {
		int iIp = FindConVar("hostip").IntValue;
		FormatEx(sIp, sizeof(sIp), "%d.%d.%d.%d:%d",
			(iIp >> 24) & 0xFF, (iIp >> 16) & 0xFF, (iIp >> 8) & 0xFF, iIp & 0xFF,
			FindConVar("hostport").IntValue);
	}

	int iTimeLeft = GetStatusRoundTimeLeft();

	int iPlayers = 0;
	for(int i = 1; i <= MaxClients; i++) {
		if(IsClientInGame(i) && !IsFakeClient(i)) {
			iPlayers++;
		}
	}

	// The comparison body doubles as the change guard, so everything that can change must be
	// represented in it - and it must not truncate, or two different states compare equal and an
	// update is skipped. Sized to match g_sStatusLastBody.
	char sBody[6144]; // must match g_sStatusLastBody
	// Gamemode is part of the signature: switching HNS<->OVA, or FJ going on or
	// off, changes the embed color and nothing else, so without them the edit
	// would be skipped as "nothing a viewer would notice".
	FormatEx(sBody, sizeof(sBody), "%s|%s|%s|%d|%d|%d|%d|", sHost, sStatusMap, sIp, iPlayers, iTimeLeft, MixOvaActive() ? 1 : 0, MixFJActive() ? 1 : 0);

	JSONArray hFields = new JSONArray();
	char sBuf[512];

	// Discord refuses custom protocols in masked links, so a bare steam://connect can never be a JOIN
	// button. Steam's own linkfilter used to stand in, but Steam now flags that wrapper as malicious
	// and shows a Link Blocked interstitial. A redirect you control is the only reliable answer, so
	// the base URL is a convar. Empty simply drops the JOIN link and leaves the address, which always works.
	char sJoinBase[192], sJoinLink[320], sIpDisplay[384];
	cv_StatusJoinUrl.GetString(sJoinBase, sizeof(sJoinBase));
	TrimString(sJoinBase);
	sJoinLink[0] = '\0';

	// No link to attach: a code span gets Discord's one-click copy button, and with nothing beside the
	// address there is room for it. The http branch below replaces this with a hyperlink, which is
	// already clickable and does not want the padding.
	FormatEx(sIpDisplay, sizeof(sIpDisplay), "`%s`", sIp);

	if(sJoinBase[0]) {
		char sJoinUrl[256];
		strcopy(sJoinUrl, sizeof(sJoinUrl), sJoinBase);
		if(StrContains(sJoinUrl, "{IP}", false) != -1) {
			ReplaceString(sJoinUrl, sizeof(sJoinUrl), "{IP}", sIp, false);
		}
		else {
			Format(sJoinUrl, sizeof(sJoinUrl), "%s%s", sJoinUrl, sIp);
		}

		// Discord only makes http(s) clickable in a masked link. Anything else renders as literal
		// [JOIN](steam://...) text, so it goes in a code span instead: not a button, but one click to
		// copy and it works when pasted.
		if(strncmp(sJoinBase, "http://", 7, false) != 0 && strncmp(sJoinBase, "https://", 8, false) != 0) {
			// Non-http cannot be a button, so it becomes copyable text on its
			// own line rather than silently vanishing.
			FormatEx(sJoinLink, sizeof(sJoinLink), "\n**Connect:** `%s`", sJoinUrl);

			if(!g_bJoinUrlWarned) {
				g_bJoinUrlWarned = true;
				LogMessage("[MIX] hnsmix_status_join_url is not http(s), so Discord cannot make it a JOIN button. Showing it as copyable text instead.");
			}
		}
		else {
			// The address IS the button. A separate JOIN word alongside it was
			// a second target for the same action, and it was the thing pushing
			// the line into a wrap at a third of the embed width.
			FormatEx(sIpDisplay, sizeof(sIpDisplay), "[%s](%s)", sIp, sJoinUrl);
		}
	}

	char sRoundTime[24];
	FormatMixDuration(iTimeLeft, sRoundTime, sizeof(sRoundTime));

	char sLocation[96];
	GetServerLocation(sLocation, sizeof(sLocation));
	if(!sLocation[0]) {
		strcopy(sLocation, sizeof(sLocation), "Unknown");
	}
	Format(sBody, sizeof(sBody), "%s%s|", sBody, sLocation);

	// Discord puts a field name above its value, so to get labels and values on one line use two
	// compact inline fields with the labels inside their values. Same two-column layout as the
	// reference card, including JOIN beside the address.
	char sStatusLeft[512], sStatusRight[512];
	FormatEx(sStatusLeft, sizeof(sStatusLeft), "**Map:** `%s`\n**Players:** `%d/%d`\n**Timeleft:** `%s`",
		sStatusMap, iPlayers, cv_StatusMaxPlayers.IntValue, sRoundTime);
	// Next map, shortened the same way as the current one. Empty until a vote or
	// nomination decides it, so fall back rather than showing a blank line.
	char sNextMap[64], sNextStatusMap[64];
	if(GetNextMap(sNextMap, sizeof(sNextMap)) && sNextMap[0]) {
		GetStatusMapName(sNextMap, sNextStatusMap, sizeof(sNextStatusMap));
	}
	else {
		strcopy(sNextStatusMap, sizeof(sNextStatusMap), "not set");
	}
	Format(sBody, sizeof(sBody), "%s%s|", sBody, sNextStatusMap);

	// Label lives inside the value so the address renders on ONE line as IP: host:port JOIN. A field
	// name would push it onto its own line. The address is deliberately NOT in a code span: these
	// are inline fields at a third of the embed width, and the padding wrapped JOIN onto its own line.
	FormatEx(sStatusRight, sizeof(sStatusRight), "**IP:** %s%s\n**Next Map:** `%s`\n**Location:** %s",
		sIpDisplay, sJoinLink, sNextStatusMap, sLocation);
	// Both field names are zero-width: every label already sits in the value,
	// so a name would only add a redundant header line ("Server" over "Map:").
	AddStatusField(hFields, "\xE2\x80\x8B", sStatusLeft, true);
	AddStatusField(hFields, "\xE2\x80\x8B", sStatusRight, true);
	// Discord packs THREE inline fields per row; two would leave a slot free
	// and pull Terrorists up into it. A zero-width third closes the row.
	AddStatusField(hFields, "\xE2\x80\x8B", "\xE2\x80\x8B", true);

	// Idle color tracks whichever mode owns the server: red for FJ, else purple
	// for OVA or blue for HNS. FJ is checked first because it runs on top of
	// whichever of the two is configured. A live mix overrides all three below.
	int iColor = MIX_STATUS_COLOR_HNS;
	if(MixFJActive())
		iColor = MIX_STATUS_COLOR_FJ;
	else if(MixOvaActive())
		iColor = MIX_STATUS_COLOR_OVA;
	if(MixStatusHasMix()) {
		char sPhase[64];
		GetMixStatusPhase(sPhase, sizeof(sPhase));

		FormatEx(sBuf, sizeof(sBuf), "`%dv%d` \xC2\xB7 `%ds`",
			g_iCurrentPlayerMode, g_iCurrentPlayerMode, RoundToNearest(g_fMixConfiguredTime));
		AddStatusField(hFields, IsCasualMix() ? "MIX (casual)" : "MIX (ranked)", sBuf, true);
		AddStatusField(hFields, "Status", sPhase, true);
		AddStatusField(hFields, "\xE2\x80\x8B", "\xE2\x80\x8B", true); // close the row

		Format(sBody, sizeof(sBody), "%s%dv%d|%s|", sBody, g_iCurrentPlayerMode, g_iCurrentPlayerMode, sPhase);

		iColor = g_Init ? 3066993 : 15844367; // green live, gold setting up
	}

	// The server status always includes the live teams, even while no mix is
	// being set up. During a mix the titles also carry the remaining hide time.
	// Discord limits each field value to 1024 characters.
	char sT[1024], sCt[1024];
	int iTCount = BuildStatusRoster(CS_TEAM_T, sT, sizeof(sT));
	int iCtCount = BuildStatusRoster(CS_TEAM_CT, sCt, sizeof(sCt));

	// First bracket is always the headcount, matching Spectators. The second
	// only appears once a mix is live and is the remaining hide time.
	char sTName[64], sCtName[64];
	FormatEx(sTName, sizeof(sTName), "Terrorists (%d)", iTCount);
	FormatEx(sCtName, sizeof(sCtName), "Counter-Terrorists (%d)", iCtCount);
	if(g_Init) {
		int iRosterT = GetRosterIndexOnSide(CS_TEAM_T);
		int iRosterCt = GetRosterIndexOnSide(CS_TEAM_CT);
		// "s" suffix keeps the second bracket readable as TIME next to the
		// headcount in the first.
		if(iRosterT != -1) {
			FormatEx(sTName, sizeof(sTName), "Terrorists (%d) (%ds)", iTCount, RoundToNearest(g_TeamTimer[iRosterT]));
		}
		if(iRosterCt != -1) {
			FormatEx(sCtName, sizeof(sCtName), "Counter-Terrorists (%d) (%ds)", iCtCount, RoundToNearest(g_TeamTimer[iRosterCt]));
		}
	}

	char sSpec[1024];
	int iSpecCount = BuildStatusSpectators(sSpec, sizeof(sSpec));

	char sSpecName[32];
	FormatEx(sSpecName, sizeof(sSpecName), "Spectators (%d)", iSpecCount);

	// Three inline fields = exactly one full Discord row, so no spacer needed
	// here (unlike the two-field rows above).
	AddStatusField(hFields, sTName, sT, true);
	AddStatusField(hFields, sCtName, sCt, true);
	AddStatusField(hFields, sSpecName, sSpec, true);
	Format(sBody, sizeof(sBody), "%s%s|%s|%s|%s|%s|%s|", sBody, sTName, sT, sCtName, sCt, sSpecName, sSpec);

	// Legend for the embed's left sidebar color, in the left column of its own row. Static, so
	// deliberately NOT part of the change signature. Ordered gamemode first, then mix state. The
	// squares are UTF-8 byte escapes so the compiler never has to guess this file's encoding.
	AddStatusField(hFields, "\xE2\x9D\x97 __Color Codes__ \xE2\x9D\x97",
		"\xF0\x9F\x9F\xAA - OVA active\n"
		... "\xF0\x9F\x9F\xA6 - HNS active\n"
		... "\xF0\x9F\x9F\xA5 - FJ active\n"
		... "\xF0\x9F\x9F\xA9 - MIX active\n"
		... "\xF0\x9F\x9F\xA8 - MIX being setup", true);
	AddStatusField(hFields, "\xE2\x80\x8B", "\xE2\x80\x8B", true);
	AddStatusField(hFields, "\xE2\x80\x8B", "\xE2\x80\x8B", true);

	// Nothing a viewer would notice has changed - skip the API call.
	if(!bForce && StrEqual(sBody, g_sStatusLastBody)) {
		delete hFields; // owns the field objects appended with _new
		return;
	}
	strcopy(g_sStatusLastBody, sizeof(g_sStatusLastBody), sBody);

	JSONObject hEmbed = new JSONObject();
	hEmbed.SetString("title", sHost);
	hEmbed.SetInt("color", iColor);
	hEmbed.Set("fields", hFields);
	delete hFields;

	char sImage[256];
	cv_StatusImage.GetString(sImage, sizeof(sImage));
	if(sImage[0]) {
		ReplaceString(sImage, sizeof(sImage), "{MAP}", sMap);
		JSONObject hImg = new JSONObject();
		hImg.SetString("url", sImage);
		hEmbed.Set("image", hImg);
		delete hImg;
	}

	FormatTime(sBuf, sizeof(sBuf), "Updated: %Y-%m-%d | Time: %H:%M:%S (%Z)");
	JSONObject hFooter = new JSONObject();
	hFooter.SetString("text", sBuf);
	hEmbed.Set("footer", hFooter);
	delete hFooter;

	SendOrEditMixStatus(sUrl, hEmbed); // takes hEmbed
}

void SendOrEditMixStatus(const char[] sUrl, JSONObject hEmbed) {
	if(!DiscordReady()) {
		delete hEmbed;
		return;
	}

	JSONObject hData = BuildDiscordPayload(hEmbed);

	bool bEditing = (g_sStatusMessageId[0] != '\0');
	char sTarget[640];
	if(bEditing) {
		FormatEx(sTarget, sizeof(sTarget), "%s/messages/%s", sUrl, g_sStatusMessageId);
	}
	else {
		FormatEx(sTarget, sizeof(sTarget), "%s?wait=true", sUrl);
	}

	HTTPRequest hRequest = new HTTPRequest(sTarget);
	if(bEditing) {
		hRequest.Patch(hData, OnMixStatusHttpDone, 1);
	}
	else {
		hRequest.Post(hData, OnMixStatusHttpDone, 0);
	}
	delete hData;
	delete hEmbed;
}

public void OnMixStatusHttpDone(HTTPResponse response, any bWasEditing, const char[] sError) {
	if(sError[0] != '\0') {
		return; // transient; the next tick retries
	}

	int iStatus = view_as<int>(response.Status);
	if(bWasEditing && (iStatus == 404 || iStatus == 400)) {
		g_sStatusMessageId[0] = '\0';
		g_sStatusLastBody[0] = '\0';
		SaveMixStatusMessageId();
		return;
	}
	if(iStatus < 200 || iStatus > 299 || bWasEditing) {
		return;
	}

	JSONObject hBody = view_as<JSONObject>(response.Data);
	if(hBody != null && hBody.GetString("id", g_sStatusMessageId, sizeof(g_sStatusMessageId))) {
		SaveMixStatusMessageId();
	}
}

void SaveMixStatusMessageId() {
	char sPath[PLATFORM_MAX_PATH];
	BuildPath(Path_SM, sPath, sizeof(sPath), "data/hnsmix_status_message.txt");
	File hFile = OpenFile(sPath, "w");
	if(hFile == null) {
		return;
	}
	hFile.WriteLine("%s", g_sStatusMessageId);
	delete hFile;
}

void LoadMixStatusMessageId() {
	g_sStatusMessageId[0] = '\0';
	char sPath[PLATFORM_MAX_PATH];
	BuildPath(Path_SM, sPath, sizeof(sPath), "data/hnsmix_status_message.txt");
	if(!FileExists(sPath)) {
		return;
	}
	File hFile = OpenFile(sPath, "r");
	if(hFile == null) {
		return;
	}
	if(hFile.ReadLine(g_sStatusMessageId, sizeof(g_sStatusMessageId))) {
		TrimString(g_sStatusMessageId);
	}
	delete hFile;
}

// !mixstatus [new] - redraw the status card now, skipping the change guard. Passing "new" also
// drops the stored message id, so the next send posts a fresh message. That is the way out when
// the old one got deleted or sits in a channel you no longer want.
public Action Command_MixStatusDiscord(int client, int args) {
	char sUrl[512];
	cv_StatusWebhook.GetString(sUrl, sizeof(sUrl));
	if(!sUrl[0]) {
		ReplyToCommand(client, "[%s] No status webhook configured - set hnsmix_status_webhook.", g_sChatPrefix);
		return Plugin_Handled;
	}

	if(!DiscordReady()) {
		ReplyToCommand(client, "[%s] The REST in Pawn extension is not loaded.", g_sChatPrefix);
		return Plugin_Handled;
	}

	char sArg[16];
	sArg[0] = '\0';
	if(args >= 1) {
		GetCmdArg(1, sArg, sizeof(sArg));
		TrimString(sArg);
	}

	bool bNew = StrEqual(sArg, "new", false);
	if(bNew) {
		// Delete the old card rather than orphaning it: forgetting the id alone
		// would leave a dead, never-again-updated embed in the channel.
		DeleteDiscordMessage(sUrl, g_sStatusMessageId);
		g_sStatusMessageId[0] = '\0';
		SaveMixStatusMessageId();
	}

	// Clearing the cached body as well, so the guard cannot suppress this even
	// if the rendered card is byte-identical to what is already up.
	g_sStatusLastBody[0] = '\0';
	RefreshMixStatusEmbed(true);

	ReplyToCommand(client, "[%s] Server status %s.", g_sChatPrefix, bNew ? "reposted as a new message" : "refreshed");
	return Plugin_Handled;
}

// Event-driven. Anything that changes what the card shows calls this; the
// refresh itself is coalesced into one call a couple of seconds later, so a
// map change seating twelve players costs one edit instead of twelve.
void RequestMixStatusRefresh() {
	char sUrl[512];
	cv_StatusWebhook.GetString(sUrl, sizeof(sUrl));
	if(!sUrl[0]) {
		return;
	}
	if(g_hStatusDebounce != null) {
		return; // one already pending - it will pick up this change too
	}
	g_hStatusDebounce = CreateTimer(2.0, Timer_MixStatusDebounce);
}

public Action Timer_MixStatusDebounce(Handle timer) {
	g_hStatusDebounce = null;
	RefreshMixStatusEmbed(false);
	return Plugin_Stop;
}

// Safety net only. Every real change already pushes an update, so this repairs a missed edit and
// moves the round clock along. The no-op guard means an idle or empty server never touches the
// API here, however often it ticks.
public Action Timer_MixStatus(Handle timer) {
	RefreshMixStatusEmbed(false);
	return Plugin_Continue;
}

void RestartMixStatusTimer() {
	// No NO_MAPCHANGE flag: the timer survives map changes, so the handle stays
	// valid and this delete cannot race the engine freeing it.
	delete g_hStatusTimer;
	float fInterval = cv_StatusInterval.FloatValue;
	char sUrl[512];
	cv_StatusWebhook.GetString(sUrl, sizeof(sUrl));
	if(!sUrl[0] || fInterval <= 0.0) {
		return;
	}
	g_hStatusTimer = CreateTimer(fInterval, Timer_MixStatus, _, TIMER_REPEAT);
}

public void OnStatusCvarChanged(ConVar convar, const char[] oldValue, const char[] newValue) {
	RestartMixStatusTimer();
}

// !mixtopdiscord - post or refresh a leaderboard embed, using cv_LbEntries rather than another
// knob. Posting a category is what CREATES its embed; the post-mix timer only maintains existing
// ones. client 0 is the automatic refresh: silent and honors the no-op guard.
public Action Command_MixLbDiscord(int client, int args) {
	char sUrl[512];
	GetMixLbWebhook(sUrl, sizeof(sUrl));
	if(!sUrl[0]) {
		if(client > 0) {
			ReplyToCommand(client, "[%s] No Discord webhook is configured.", g_sChatPrefix);
		}
		return Plugin_Handled;
	}

	if(g_hStatsDb == null) {
		if(client > 0) {
			ReplyToCommand(client, "[%s] The stats database is not connected.", g_sChatPrefix);
		}
		return Plugin_Handled;
	}

	// No client check here: the server console is client 0, and gating on
	// client > 0 made every rcon/console invocation fall through to the usage
	// listing. args == 0 is what identifies the automatic refresh.
	char sArg[24];
	sArg[0] = '\0';
	if(args >= 1) {
		GetCmdArg(1, sArg, sizeof(sArg));
		TrimString(sArg);
	}

	// Bare command lists what is available and what is already live, rather
	// than silently posting one category.
	if(!sArg[0]) {
		ReplyToCommand(client, "[%s] Usage: sm_mixtopdiscord <category|all>", g_sChatPrefix);
		ReplyToCommand(client, "[%s] Posting a category creates its embed; after that it auto-updates after every ranked mix.", g_sChatPrefix);
		ReplyToCommand(client, "[%s] Delete the message in Discord to stop that category updating.", g_sChatPrefix);

		char sLabel[32], sKey[16];
		for(int cat = MIX_LB_ELO; cat <= MIX_LB_CLUTCHES; cat++) {
			MixLbCategoryLabel(cat, sLabel, sizeof(sLabel));
			MixLbCategoryKeyword(cat, sKey, sizeof(sKey));
			ReplyToCommand(client, "  %-10s - %-16s [%s]", sKey, sLabel,
				(g_saLbMessageId[cat][0] != '\0') ? "live, auto-updating" : "not posted");
		}
		ReplyToCommand(client, "  %-10s - %s", "all", "post/refresh every category");
		ReplyToCommand(client, "[%s] Add 'new' (e.g. sm_mixtopdiscord elo new) to delete the old embed and repost it.", g_sChatPrefix);
		return Plugin_Handled;
	}

	// Optional 2nd arg "new": delete the existing embed for that category and
	// post a fresh one, instead of editing it in place.
	char sMode[16];
	sMode[0] = '\0';
	if(args >= 2) {
		GetCmdArg(2, sMode, sizeof(sMode));
		TrimString(sMode);
	}
	bool bNew = StrEqual(sMode, "new", false);

	if(StrEqual(sArg, "all", false)) {
		for(int cat = MIX_LB_ELO; cat <= MIX_LB_CLUTCHES; cat++) {
			if(bNew) {
				ResetMixLbMessage(sUrl, cat);
			}
			QueueMixLbDiscord(client, cat, true, bNew);
		}
		return Plugin_Handled;
	}

	int iCategory = MixLbCategoryFromName(sArg);
	if(iCategory == 0) {
		ReplyToCommand(client, "[%s] Usage: sm_mixtopdiscord <elo|winloss|survival|stabs|falldmg|clutches|all> [new]", g_sChatPrefix);
		return Plugin_Handled;
	}

	if(bNew) {
		ResetMixLbMessage(sUrl, iCategory);
	}
	QueueMixLbDiscord(client, iCategory, true, bNew);
	return Plugin_Handled;
}

// Delete one category's standing embed and forget it, so the next send creates
// a fresh message rather than editing the old one.
void ResetMixLbMessage(const char[] sUrl, int iCategory) {
	if(iCategory < MIX_LB_ELO || iCategory > MIX_LB_CLUTCHES) {
		return;
	}
	DeleteDiscordMessage(sUrl, g_saLbMessageId[iCategory]);
	g_saLbMessageId[iCategory][0] = '\0';
	g_saLbLastBody[iCategory][0] = '\0';
	SaveMixLbMessageIds();
}

// The keyword sm_mixtopdiscord accepts for each category.
void MixLbCategoryKeyword(int iCategory, char[] sBuf, int iMaxLen) {
	switch(iCategory) {
		case MIX_LB_ELO:      { strcopy(sBuf, iMaxLen, "elo"); }
		case MIX_LB_WL:       { strcopy(sBuf, iMaxLen, "winloss"); }
		case MIX_LB_SURVIVAL: { strcopy(sBuf, iMaxLen, "survival"); }
		case MIX_LB_STABS:    { strcopy(sBuf, iMaxLen, "stabs"); }
		case MIX_LB_FALLDMG:  { strcopy(sBuf, iMaxLen, "falldmg"); }
		case MIX_LB_CLUTCHES: { strcopy(sBuf, iMaxLen, "clutches"); }
		default:              { strcopy(sBuf, iMaxLen, "?"); }
	}
}

// Unknown names resolve to 0. "" no longer maps to elo: the bare command lists
// the categories instead of posting one.
int MixLbCategoryFromName(const char[] sName) {
	if(StrEqual(sName, "elo", false))                                                 { return MIX_LB_ELO; }
	if(StrEqual(sName, "winloss", false) || StrEqual(sName, "wl", false))             { return MIX_LB_WL; }
	if(StrEqual(sName, "survival", false) || StrEqual(sName, "time", false))          { return MIX_LB_SURVIVAL; }
	if(StrEqual(sName, "stabs", false))                                               { return MIX_LB_STABS; }
	if(StrEqual(sName, "falldmg", false) || StrEqual(sName, "fall", false))           { return MIX_LB_FALLDMG; }
	if(StrEqual(sName, "clutches", false) || StrEqual(sName, "clutch", false))        { return MIX_LB_CLUTCHES; }
	return 0;
}

// One accent color per category so the embeds are distinguishable at a glance
// when they are posted together.
int MixLbCategoryColor(int iCategory) {
	switch(iCategory) {
		case MIX_LB_ELO:      { return 15844367; } // gold
		case MIX_LB_WL:       { return 3066993;  } // green
		case MIX_LB_SURVIVAL: { return 3447003;  } // blue
		case MIX_LB_STABS:    { return 15158332; } // red
		case MIX_LB_FALLDMG:  { return 15105570; } // orange
		case MIX_LB_CLUTCHES: { return 10181046; } // purple
	}
	return 9807270; // gray
}

void FormatMixDuration(int iSeconds, char[] sBuf, int iMaxLen) {
	int h = iSeconds / 3600;
	int m = (iSeconds % 3600) / 60;
	int s = iSeconds % 60;
	if(h > 0) {
		FormatEx(sBuf, iMaxLen, "%dh %dm", h, m);
	}
	else if(m > 0) {
		FormatEx(sBuf, iMaxLen, "%dm %ds", m, s);
	}
	else {
		FormatEx(sBuf, iMaxLen, "%ds", s);
	}
}

void MixLbCategoryLabel(int iCategory, char[] sBuf, int iMaxLen) {
	switch(iCategory) {
		case MIX_LB_ELO:      { strcopy(sBuf, iMaxLen, "ELO"); }
		case MIX_LB_WL:       { strcopy(sBuf, iMaxLen, "Win/Loss Ratio"); }
		case MIX_LB_SURVIVAL: { strcopy(sBuf, iMaxLen, "Survival Time"); }
		case MIX_LB_STABS:    { strcopy(sBuf, iMaxLen, "Stabs"); }
		case MIX_LB_FALLDMG:  { strcopy(sBuf, iMaxLen, "Fall Damage"); }
		case MIX_LB_CLUTCHES: { strcopy(sBuf, iMaxLen, "Clutches"); }
		default:              { strcopy(sBuf, iMaxLen, "Unknown"); }
	}
}

// Same ordering as the matching !mixtop page, so the embeds and the in-game
// menu never disagree. The SQL expression supplies a SteamID64 from the
// existing Steam2 ID for historic rows that predate the steamid64 column.
void QueueMixLbDiscord(int client, int iCategory, bool bManual = false, bool bReposted = false) {
	int iLimit = cv_LbEntries.IntValue;
	char sQuery[640];
	char sProfileIdSql[256];
	if(g_bStatsDbSQLite) {
		strcopy(sProfileIdSql, sizeof(sProfileIdSql), "COALESCE(NULLIF(steamid64, ''), steamid)");
	} else {
		strcopy(sProfileIdSql, sizeof(sProfileIdSql), "COALESCE(NULLIF(steamid64, ''), steamid)");
	}

	switch(iCategory) {
		// Column 6 is an extra stat slot; only Elo uses it (survival time as a
		// third detail line). Every other category selects 0 so the callback can
		// read a fixed column layout.
		case MIX_LB_ELO: {
			FormatEx(sQuery, sizeof(sQuery),
				"SELECT name, elo, wins, losses, stabs_given, %s, survival_time FROM `%s_stats` \
				ORDER BY elo DESC, (wins * 1.0 / %s(wins + losses, 1)) DESC, wins DESC LIMIT %d",
				sProfileIdSql, g_sSqlPrefix, g_sSqlMax, iLimit);
		}
		case MIX_LB_WL: {
			int iMinGames = cv_LbMinGames.IntValue;
			if(iMinGames < 1) {
				iMinGames = 1;
			}
			FormatEx(sQuery, sizeof(sQuery),
				"SELECT name, wins, losses, 0, 0, %s, 0 FROM `%s_stats` WHERE (wins + losses) >= %d \
				ORDER BY (wins * 1.0 / (wins + losses)) DESC, wins DESC LIMIT %d",
				sProfileIdSql, g_sSqlPrefix, iMinGames, iLimit);
		}
		case MIX_LB_SURVIVAL: {
			FormatEx(sQuery, sizeof(sQuery),
				"SELECT name, survival_time, t_rounds, 0, 0, %s, 0 FROM `%s_stats` WHERE survival_time > 0 \
				ORDER BY survival_time DESC LIMIT %d",
				sProfileIdSql, g_sSqlPrefix, iLimit);
		}
		case MIX_LB_STABS: {
			FormatEx(sQuery, sizeof(sQuery),
				"SELECT name, stabs_given, stabs_taken, 0, 0, %s, 0 FROM `%s_stats` WHERE (stabs_given + stabs_taken) > 0 \
				ORDER BY stabs_given DESC, stabs_taken DESC LIMIT %d",
				sProfileIdSql, g_sSqlPrefix, iLimit);
		}
		case MIX_LB_FALLDMG: {
			FormatEx(sQuery, sizeof(sQuery),
				"SELECT name, fall_damage, 0, 0, 0, %s, 0 FROM `%s_stats` WHERE fall_damage > 0 \
				ORDER BY fall_damage DESC LIMIT %d",
				sProfileIdSql, g_sSqlPrefix, iLimit);
		}
		case MIX_LB_CLUTCHES: {
			FormatEx(sQuery, sizeof(sQuery),
				"SELECT name, clutches, 0, 0, 0, %s, 0 FROM `%s_stats` WHERE clutches > 0 \
				ORDER BY clutches DESC LIMIT %d",
				sProfileIdSql, g_sSqlPrefix, iLimit);
		}
		default: {
			return;
		}
	}

	// userid bits 0-19, category bits 20-23, then explicit flags. The flags
	// cannot be inferred from the userid: the server console is client 0, the
	// same value the automatic refresh uses, so "manual" has to be carried.
	int iData = ((client > 0) ? GetClientUserId(client) : 0)
		| (iCategory << 20)
		| (bManual ? (1 << 24) : 0)
		| (bReposted ? (1 << 25) : 0);
	g_hStatsDb.Query(SqlCallback_MixLbDiscord, sQuery, iData);
}

// Automatic refresh after a ranked mix. Only categories that ALREADY have an embed are touched -
// the auto path never creates one. Posting is an explicit admin act, after which it maintains
// itself. Deleting the message in Discord is how you turn a category off: the 404 self-heal
// clears its id and nothing recreates it.
void RefreshLiveMixLbEmbeds() {
	for(int cat = MIX_LB_ELO; cat <= MIX_LB_CLUTCHES; cat++) {
		if(g_saLbMessageId[cat][0] == '\0') {
			continue; // nothing posted for this category - nothing to update
		}
		QueueMixLbDiscord(0, cat);
	}
}

public Action Timer_RefreshMixLbEmbed(Handle timer) {
	RefreshLiveMixLbEmbeds();
	return Plugin_Stop;
}

void GetMixLbWebhook(char[] sUrl, int iMaxLen) {
	cv_DiscordLbWebhook.GetString(sUrl, iMaxLen);
	if(!sUrl[0]) {
		cv_DiscordWebhook.GetString(sUrl, iMaxLen);
	}
}

// Replies to whoever asked: a player in chat, the server console otherwise.
// The SQL callback is async, so ReplyToCommand's stored reply source is gone
// by now and the target has to be resolved explicitly.
void MixLbReply(int client, bool bManual, const char[] sFormat, any ...) {
	if(!bManual) {
		return;
	}
	char sMsg[256];
	VFormat(sMsg, sizeof(sMsg), sFormat, 4);
	if(client > 0) {
		MixPrintToChat(client, "%s", sMsg);
	}
	else {
		PrintToServer("[%s] %s", g_sChatPrefix, sMsg);
	}
}

public void SqlCallback_MixLbDiscord(Database db, DBResultSet results, const char[] error, any data) {
	int iCategory = (data >> 20) & 0xF;
	int userid = data & 0xFFFFF;
	bool bManual = ((data & (1 << 24)) != 0);
	bool bReposted = ((data & (1 << 25)) != 0);
	int client = (userid != 0) ? GetClientOfUserId(userid) : 0;

	char sLabel[32];
	MixLbCategoryLabel(iCategory, sLabel, sizeof(sLabel));

	if(results == null) {
		LogError("[MIX] Discord leaderboard query failed: %s", error);
		MixLbReply(client, bManual, "The %s leaderboard query FAILED - nothing was posted.", sLabel);
		return;
	}

	char sUrl[512];
	GetMixLbWebhook(sUrl, sizeof(sUrl));
	if(!sUrl[0]) {
		return; // cvar cleared while the query was in flight
	}

	// Two side-by-side columns like the results embed, five rows each, with the
	// stat line under the name instead of crammed onto it. sBody stays the
	// change-guard signature; the columns are what actually get rendered.
	char sBody[3072];
	char sColA[1024], sColB[1024];
	sBody[0] = '\0';
	sColA[0] = '\0';
	sColB[0] = '\0';

	int iRow = 0;
	char sName[MAX_NAME_LENGTH];
	while(results.FetchRow()) {
		results.FetchString(0, sName, sizeof(sName));
		int iA = results.FetchInt(1);
		int iB = results.FetchInt(2);
		int iC = results.FetchInt(3);
		int iD = results.FetchInt(4);
		int iExtra = results.FetchInt(6); // Elo only: total survival time

		// Column 5 is the stored steamid64 when we have one, otherwise the row's
		// Steam2 id. Converting is only the fallback for rows belonging to
		// players who have not connected since the column was added.
		char sProfileId[32], sAuth64[24];
		results.FetchString(5, sProfileId, sizeof(sProfileId));
		if(StrContains(sProfileId, "STEAM_", false) == 0) {
			if(!Mix_SteamID2To64(sProfileId, sAuth64, sizeof(sAuth64))) {
				sAuth64[0] = '\0';
			}
		}
		else {
			strcopy(sAuth64, sizeof(sAuth64), sProfileId);
		}

		TruncateMixName(sName, cv_DiscordNameMax.IntValue);
		SanitizeMixDiscordName(sName, sizeof(sName));
		iRow++;

		// No %-2d padding: it put a visible blank inside the code span (`#1 `).
		char sPos[12];
		FormatEx(sPos, sizeof(sPos), "`#%d`", iRow);

		// Only a malformed/BOT steamid leaves a name unlinked now.
		char sProfile[192];
		if(sAuth64[0] != '\0') {
			FormatEx(sProfile, sizeof(sProfile), "[**%s**](https://steamcommunity.com/profiles/%s)", sName, sAuth64);
		}
		else {
			FormatEx(sProfile, sizeof(sProfile), "**%s**", sName);
		}

		// Same shape as the results embed: a headline on the name's line, then
		// bullet detail lines beneath it. sDetail2 is left empty for categories
		// that only carry one number.
		char sHead[64], sDetail1[64], sDetail2[64], sDetail3[64];
		sHead[0] = '\0';
		sDetail1[0] = '\0';
		sDetail2[0] = '\0';
		sDetail3[0] = '\0';

		switch(iCategory) {
			case MIX_LB_ELO: {
				FormatEx(sHead, sizeof(sHead), "**%d** ELO", iA);
				FormatEx(sDetail1, sizeof(sDetail1), "%dW · %dL · %d games", iB, iC, iB + iC);
				FormatEx(sDetail2, sizeof(sDetail2), "%d stabs", iD);
				if(iExtra > 0) {
					char sAlive[32];
					FormatMixDuration(iExtra, sAlive, sizeof(sAlive));
					FormatEx(sDetail3, sizeof(sDetail3), "%s s/t", sAlive);
				}
			}
			case MIX_LB_WL: {
				int iGames = iA + iB;
				float fRatio = (iGames > 0) ? (float(iA) * 100.0 / float(iGames)) : 0.0;
				FormatEx(sHead, sizeof(sHead), "**%.1f%%** ratio", fRatio);
				FormatEx(sDetail1, sizeof(sDetail1), "%dW · %dL", iA, iB);
				FormatEx(sDetail2, sizeof(sDetail2), "%d games", iGames);
			}
			case MIX_LB_SURVIVAL: {
				// iA = total seconds survived, iB = T rounds played.
				char sTime[32];
				FormatMixDuration(iA, sTime, sizeof(sTime));
				FormatEx(sHead, sizeof(sHead), "**%s** s/t", sTime);
				if(iB > 0) {
					FormatEx(sDetail1, sizeof(sDetail1), "%.1fs average", float(iA) / float(iB));
					FormatEx(sDetail2, sizeof(sDetail2), "%d T rounds", iB);
				}
			}
			case MIX_LB_STABS: {
				FormatEx(sHead, sizeof(sHead), "**%d** stabs given", iA);
				FormatEx(sDetail1, sizeof(sDetail1), "%d taken", iB);
			}
			case MIX_LB_FALLDMG: {
				FormatEx(sHead, sizeof(sHead), "**%d** fall damage", iA);
			}
			case MIX_LB_CLUTCHES: {
				FormatEx(sHead, sizeof(sHead), "**%d** clutches", iA);
			}
		}

		// Headline sits beside the name; only the details become bullets.
		// Literal bullet, NOT "- " or "* ": those are markdown list syntax and
		// Discord indents them away from the text.
		char sStat[192];
		sStat[0] = '\0';
		if(sDetail1[0] != '\0') {
			FormatEx(sStat, sizeof(sStat), "\xE2\x80\xA2 %s", sDetail1);
		}
		if(sDetail2[0] != '\0') {
			if(sStat[0] != '\0') {
				Format(sStat, sizeof(sStat), "%s\n", sStat);
			}
			Format(sStat, sizeof(sStat), "%s\xE2\x80\xA2 %s", sStat, sDetail2);
		}
		if(sDetail3[0] != '\0') {
			if(sStat[0] != '\0') {
				Format(sStat, sizeof(sStat), "%s\n", sStat);
			}
			Format(sStat, sizeof(sStat), "%s\xE2\x80\xA2 %s", sStat, sDetail3);
		}

		// "`#1` name - 1215 Elo" then bullet details. Categories with no detail
		// lines (fall damage, clutches) render as a single line, no trailing gap.
		char sEntry[512];
		if(sStat[0] != '\0') {
			FormatEx(sEntry, sizeof(sEntry), "%s %s - %s\n%s\n\n", sPos, sProfile, sHead, sStat);
		}
		else {
			FormatEx(sEntry, sizeof(sEntry), "%s %s - %s\n\n", sPos, sProfile, sHead);
		}

		int iHalf = (cv_LbEntries.IntValue + 1) / 2;
		if(iRow <= iHalf) {
			AppendEmbedEntry(sColA, sizeof(sColA), sEntry);
		}
		else {
			AppendEmbedEntry(sColB, sizeof(sColB), sEntry);
		}
		Format(sBody, sizeof(sBody), "%s%s|%s|%s|%s\n", sBody, sPos, sProfile, sHead, sStat);
	}

	if(iRow == 0) {
		MixLbReply(client, bManual, "No ranked players for the %s leaderboard yet - nothing was posted.", sLabel);
		return;
	}

	// Change-driven: an automatic refresh whose table is byte-identical to what
	// this category already shows on Discord is not worth an API call. A manual
	// !mixtopdiscord always goes through, so an admin can force it.
	if(!bManual && StrEqual(sBody, g_saLbLastBody[iCategory])) {
		return;
	}

	JSONObject hEmbed = new JSONObject();

	char sBuf[256];
	char sPrefix[64];
	cv_DiscordPrefix.GetString(sPrefix, sizeof(sPrefix));
	FormatEx(sBuf, sizeof(sBuf), "🏆 %s MIX - Top %d by %s", sPrefix, iRow, sLabel);
	hEmbed.SetString("title", sBuf);
	hEmbed.SetInt("color", MixLbCategoryColor(iCategory));

	// Two inline fields = side-by-side columns, matching the results embed.
	// Named rather than zero-width: Discord draws a header line per field
	// either way, so an empty name is just a blank line of wasted height.
	int iSplit = (cv_LbEntries.IntValue + 1) / 2;
	char sColAName[32], sColBName[32];
	FormatEx(sColAName, sizeof(sColAName), "Ranks 1-%d", (iRow < iSplit) ? iRow : iSplit);
	FormatEx(sColBName, sizeof(sColBName), "Ranks %d-%d", iSplit + 1, iRow);

	JSONArray hFields = new JSONArray();
	AddEmbedField(hFields, sColAName, sColA, true);
	if(sColB[0] != '\0') {
		AddEmbedField(hFields, sColBName, sColB, true);
	}
	hEmbed.Set("fields", hFields);
	delete hFields;

	FormatTime(sBuf, sizeof(sBuf), "Updated: %Y-%m-%d | Time: %H:%M:%S (%Z)");

	JSONObject hFooter = new JSONObject();
	hFooter.SetString("text", sBuf);
	hEmbed.Set("footer", hFooter);
	delete hFooter;

	strcopy(g_saLbLastBody[iCategory], sizeof(g_saLbLastBody[]), sBody);
	SendOrEditMixLbEmbed(sUrl, hEmbed, iCategory); // takes hEmbed

	MixLbReply(client, bManual, "%s leaderboard (top %d) %s.",
		sLabel, iRow, bReposted ? "reposted as a new message" : "posted successfully");
}

// POST once, PATCH forever after. A stale id (message deleted, webhook pointed
// at a new channel) comes back 404/400 and falls through to a fresh POST, so
// this self-heals without anyone clearing the id file.
void SendOrEditMixLbEmbed(const char[] sUrl, JSONObject hEmbed, int iCategory) {
	if(!DiscordReady()) {
		LogError("[MIX] The REST in Pawn extension is not loaded - the Discord leaderboard cannot be posted.");
		delete hEmbed;
		return;
	}

	JSONObject hData = BuildDiscordPayload(hEmbed);

	// Does this category already have an embed up there? Edit it if so, create
	// it if not. That is the whole state machine.
	bool bEditing = (g_saLbMessageId[iCategory][0] != '\0');

	char sTarget[640];
	if(bEditing) {
		FormatEx(sTarget, sizeof(sTarget), "%s/messages/%s", sUrl, g_saLbMessageId[iCategory]);
	}
	else {
		// ?wait=true makes Discord return the created message object, which is
		// the only way to learn the id needed for later edits.
		FormatEx(sTarget, sizeof(sTarget), "%s?wait=true", sUrl);
	}

	// The callback needs to know which category answered and whether it was an
	// edit; the HTTP API carries one cell.
	int iCtx = (iCategory << 4) | (bEditing ? 1 : 0);

	HTTPRequest hRequest = new HTTPRequest(sTarget);
	if(bEditing) {
		hRequest.Patch(hData, OnMixLbHttpDone, iCtx);
	}
	else {
		hRequest.Post(hData, OnMixLbHttpDone, iCtx);
	}
	delete hData;
	delete hEmbed;
}

// ctx: category in bits 4+, "was an edit" in bit 0.
public void OnMixLbHttpDone(HTTPResponse response, any ctx, const char[] sError) {
	int iCategory = ctx >> 4;
	bool bWasEditing = ((ctx & 1) != 0);

	if(iCategory < MIX_LB_ELO || iCategory > MIX_LB_CLUTCHES) {
		return;
	}

	if(sError[0] != '\0') {
		LogError("[MIX] Discord leaderboard request failed: %s", sError);
		return;
	}

	int iStatus = view_as<int>(response.Status);

	// An edit against a message that no longer exists: forget the id so the
	// next update creates a fresh one instead of failing forever.
	if(bWasEditing && (iStatus == 404 || iStatus == 400)) {
		LogMessage("[MIX] Discord leaderboard message for category %d is gone (HTTP %d) - it will be reposted on the next update.", iCategory, iStatus);
		g_saLbMessageId[iCategory][0] = '\0';
		g_saLbLastBody[iCategory][0] = '\0';
		SaveMixLbMessageIds();
		return;
	}

	if(iStatus < 200 || iStatus > 299) {
		LogError("[MIX] Discord rejected the leaderboard %s for category %d (HTTP %d).", bWasEditing ? "edit" : "post", iCategory, iStatus);
		return;
	}

	if(bWasEditing) {
		return; // nothing to learn from an edit
	}

	// Only the creating POST carries the message id.
	JSONObject hBody = view_as<JSONObject>(response.Data);
	if(hBody == null || !hBody.GetString("id", g_saLbMessageId[iCategory], sizeof(g_saLbMessageId[]))) {
		g_saLbMessageId[iCategory][0] = '\0';
		LogError("[MIX] The Discord webhook response carried no message id; category %d will repost rather than edit.", iCategory);
		return;
	}
	SaveMixLbMessageIds();
}

// Survives map changes and restarts; without it every map would orphan the
// previous embeds and post a fresh set. One "<category> <messageid>" per line.
void SaveMixLbMessageIds() {
	char sPath[PLATFORM_MAX_PATH];
	BuildPath(Path_SM, sPath, sizeof(sPath), "data/hnsmix_lb_message.txt");

	File hFile = OpenFile(sPath, "w");
	if(hFile == null) {
		return;
	}
	for(int cat = MIX_LB_ELO; cat <= MIX_LB_CLUTCHES; cat++) {
		if(g_saLbMessageId[cat][0] != '\0') {
			hFile.WriteLine("%d %s", cat, g_saLbMessageId[cat]);
		}
	}
	delete hFile;
}

void LoadMixLbMessageIds() {
	for(int cat = 0; cat <= MIX_LB_CLUTCHES; cat++) {
		g_saLbMessageId[cat][0] = '\0';
	}

	char sPath[PLATFORM_MAX_PATH];
	BuildPath(Path_SM, sPath, sizeof(sPath), "data/hnsmix_lb_message.txt");
	if(!FileExists(sPath)) {
		return;
	}

	File hFile = OpenFile(sPath, "r");
	if(hFile == null) {
		return;
	}

	char sLine[64];
	while(hFile.ReadLine(sLine, sizeof(sLine))) {
		TrimString(sLine);
		if(!sLine[0]) {
			continue;
		}
		char sParts[2][40];
		if(ExplodeString(sLine, " ", sParts, sizeof(sParts), sizeof(sParts[])) != 2) {
			continue;
		}
		int cat = StringToInt(sParts[0]);
		if(cat >= MIX_LB_ELO && cat <= MIX_LB_CLUTCHES) {
			strcopy(g_saLbMessageId[cat], sizeof(g_saLbMessageId[]), sParts[1]);
		}
	}
	delete hFile;
}

// Neutralize the markdown a player name can carry into an embed. Brackets would
// break links, and *_~` would italicise/strike the rest of the row.
void SanitizeMixDiscordName(char[] sName, int iMaxLen) {
	ReplaceString(sName, iMaxLen, "[", "(");
	ReplaceString(sName, iMaxLen, "]", ")");
	ReplaceString(sName, iMaxLen, "*", "");
	ReplaceString(sName, iMaxLen, "_", "");
	ReplaceString(sName, iMaxLen, "~", "");
	ReplaceString(sName, iMaxLen, "`", "");
	ReplaceString(sName, iMaxLen, ">", "");
}

// Everyone who watched the mix without being on either roster. Not inline, so
// it renders as a full-width row underneath the two team columns. Skipped
// entirely when nobody was spectating.
void AddMixDiscordSpectatorField(JSONArray hFields) {
	char sValue[1024];
	int iCount = 0;

	for(int c = 1; c <= MaxClients; c++) {
		if(!IsClientInGame(c) || IsFakeClient(c) || IsClientSourceTV(c)) {
			continue;
		}
		// Roster membership, not team: a mix player who was replaced or died
		// into spectator still belongs to their team's column.
		if(IsClientOnMixRoster(c) || c == g_iCTCaptain || c == g_iTCaptain) {
			continue;
		}
		if(GetClientTeam(c) > CS_TEAM_SPECTATOR) {
			continue;
		}

		char sFlag[12];
		GetMixCountryFlag(c, sFlag, sizeof(sFlag));

		char sPName[MAX_NAME_LENGTH];
		GetClientName(c, sPName, sizeof(sPName));
		TruncateMixName(sPName, cv_DiscordNameMax.IntValue);
		ReplaceString(sPName, sizeof(sPName), "[", "(");
		ReplaceString(sPName, sizeof(sPName), "]", ")");

		char sProfile[192], sAuth64[24];
		if(GetClientAuthId(c, AuthId_SteamID64, sAuth64, sizeof(sAuth64))) {
			FormatEx(sProfile, sizeof(sProfile), "[%s](https://steamcommunity.com/profiles/%s)", sPName, sAuth64);
		}
		else {
			strcopy(sProfile, sizeof(sProfile), sPName);
		}

		char sEntry[256];
		FormatEx(sEntry, sizeof(sEntry), "%s%s%s%s", iCount > 0 ? ", " : "", sFlag, sFlag[0] ? " " : "", sProfile);
		if(!AppendEmbedEntry(sValue, sizeof(sValue), sEntry)) {
			break; // out of room - better to drop the tail than half a link
		}
		iCount++;
	}

	if(iCount == 0) {
		return;
	}

	char sName[64];
	FormatEx(sName, sizeof(sName), "Spectators (%d)", iCount);
	AddEmbedField(hFields, sName, sValue, false);
}

// Flag + profile-linked bold name, the same presentation the roster columns
// use. Takes stored strings so it works for someone who has already left.
void BuildMixDiscordNameTag(const char[] sFlag, const char[] sAuth64, const char[] sName, char[] sOut, int iMaxLen) {
	char sClean[MAX_NAME_LENGTH];
	strcopy(sClean, sizeof(sClean), sName);
	TruncateMixName(sClean, cv_DiscordNameMax.IntValue);
	SanitizeMixDiscordName(sClean, sizeof(sClean));
	if(!sClean[0]) {
		strcopy(sClean, sizeof(sClean), "a replacement");
	}

	if(sAuth64[0]) {
		FormatEx(sOut, iMaxLen, "%s%s**[%s](https://steamcommunity.com/profiles/%s)**",
			sFlag, sFlag[0] ? " " : "", sClean, sAuth64);
	}
	else {
		FormatEx(sOut, iMaxLen, "%s%s**%s**", sFlag, sFlag[0] ? " " : "", sClean);
	}
}

// Same tag for someone who is still connected.
void BuildMixDiscordNameTagClient(int client, char[] sOut, int iMaxLen) {
	char sFlag[12], sAuth64[24], sName[MAX_NAME_LENGTH];
	GetMixCountryFlag(client, sFlag, sizeof(sFlag));
	if(!GetClientAuthId(client, AuthId_SteamID64, sAuth64, sizeof(sAuth64))) {
		sAuth64[0] = '\0';
	}
	GetClientName(client, sName, sizeof(sName));
	BuildMixDiscordNameTag(sFlag, sAuth64, sName, sOut, iMaxLen);
}

// Stores one finished "leaver → replacement" row. Built at swap time because
// the leaver's flag and profile id are not recoverable once they are gone.
void RecordMixSwap(const char[] sOutTag, const char[] sInTag) {
	if(g_alMixSwaps == null) {
		return;
	}
	char sRow[320];
	FormatEx(sRow, sizeof(sRow), "%s → %s", sOutTag, sInTag);
	g_alMixSwaps.PushString(sRow);
}

// Roster churn worth reporting at the end: who handed their spot over (from
// either path), and who left without ever being replaced. Two full-width rows,
// each skipped when empty.
void AddMixDiscordDcField(JSONArray hFields) {
	// " | " between swaps: each row already contains an arrow, so a comma would
	// not read as a boundary between two pairs.
	char sSwapped[1024];
	int iSwapped = 0;
	if(g_alMixSwaps != null) {
		char sRow[320], sEntry[352];
		for(int i = 0; i < g_alMixSwaps.Length; i++) {
			g_alMixSwaps.GetString(i, sRow, sizeof(sRow));
			FormatEx(sEntry, sizeof(sEntry), "%s%s", iSwapped > 0 ? " | " : "", sRow);
			if(!AppendEmbedEntry(sSwapped, sizeof(sSwapped), sEntry)) {
				break; // out of room - drop the tail rather than half a link
			}
			iSwapped++;
		}
	}

	char sGone[1024];
	int iGone = 0;
	if(g_alDcPlayers != null) {
		DcPlayer_t dc;
		for(int i = 0; i < g_alDcPlayers.Length; i++) {
			g_alDcPlayers.GetArray(i, dc, sizeof(DcPlayer_t));
			if(dc.bReplaced) {
				continue; // already named in the swap row
			}

			char sTag[192], sEntry[224];
			BuildMixDiscordNameTag(dc.sFlag, dc.sAuth64, dc.sName, sTag, sizeof(sTag));
			FormatEx(sEntry, sizeof(sEntry), "%s%s", iGone > 0 ? ", " : "", sTag);
			if(!AppendEmbedEntry(sGone, sizeof(sGone), sEntry)) {
				break;
			}
			iGone++;
		}
	}

	char sDcName[64];
	if(iSwapped > 0) {
		FormatEx(sDcName, sizeof(sDcName), "Replaced (%d)", iSwapped);
		AddEmbedField(hFields, sDcName, sSwapped, false);
	}
	if(iGone > 0) {
		FormatEx(sDcName, sizeof(sDcName), "DCed (%d)", iGone);
		AddEmbedField(hFields, sDcName, sGone, false);
	}
}

// True if this client sits on either mix roster.
bool IsClientOnMixRoster(int client) {
	Player_t player;
	for(int t = 0; t < PLAYER_TEAM_MAX; t++) {
		if(g_alPlayers[t] == null) {
			continue;
		}
		for(int i = 0; i < g_alPlayers[t].Length; i++) {
			g_alPlayers[t].GetArray(i, player, sizeof(Player_t));
			if(player.clientIdx == client) {
				return true;
			}
		}
	}
	return false;
}

void AppendMixDiscordPlayerLines(char[] sValue, int iMaxLen, int client, bool bCaptain = false) {
	char sFlag[12];
	GetMixCountryFlag(client, sFlag, sizeof(sFlag));

	char sPName[MAX_NAME_LENGTH];
	GetClientName(client, sPName, sizeof(sPName));
	TruncateMixName(sPName, cv_DiscordNameMax.IntValue);
	// Brackets would break the markdown link around the name.
	ReplaceString(sPName, sizeof(sPName), "[", "(");
	ReplaceString(sPName, sizeof(sPName), "]", ")");

	// Blue clickable name -> steam profile, like the DU modules do it.
	char sProfile[192], sAuth64[24];
	if(GetClientAuthId(client, AuthId_SteamID64, sAuth64, sizeof(sAuth64))) {
		FormatEx(sProfile, sizeof(sProfile), "[%s](https://steamcommunity.com/profiles/%s)", sPName, sAuth64);
	}
	else {
		strcopy(sProfile, sizeof(sProfile), sPName);
	}

	char sDcs[24];
	int iDcs = CountMixDcEntries(client);
	if(iDcs > 0) {
		FormatEx(sDcs, sizeof(sDcs), " · DCs %d", iDcs);
	}

	// No per-player elo on casual mixes.
	char sElo[24];
	sElo[0] = '\0';
	if(!IsCasualMix()) {
		FormatEx(sElo, sizeof(sElo), " - %d ELO", g_iaElo[client]);
	}

	// Clutches ride along on the fall-damage line and only when there were any -
	// a permanent "0 c" would cost a slot in every player block for nothing.
	char sClutch[16];
	sClutch[0] = '\0';
	if(g_iaMixClutches[client] > 0) {
		FormatEx(sClutch, sizeof(sClutch), " · %d c", g_iaMixClutches[client]);
	}

	char sEntry[512];
	FormatEx(sEntry, sizeof(sEntry), "%s%s%s**%s**%s\n· %d s/t · %d stabs\n· %d fdmg%s%s\n",
		sFlag, sFlag[0] ? " " : "", bCaptain ? "C: " : "", sProfile, sElo,
		RoundToFloor(fTimeSurvived[client]), g_iaMixStabsGiven[client],
		g_iaMixFallDamage[client], sClutch, sDcs);
	AppendEmbedEntry(sValue, iMaxLen, sEntry);
}

// Country flag emoji (regional-indicator pair) from the client's IP; empty
// when GeoIP has no answer.
void GetMixCountryFlag(int client, char[] sFlag, int iMaxLen) {
	sFlag[0] = '\0';

	char sIp[32], sCode[3];
	if(!GetClientIP(client, sIp, sizeof(sIp)) || !GeoipCode2(sIp, sCode)) {
		return;
	}
	if(sCode[0] < 'A' || sCode[0] > 'Z' || sCode[1] < 'A' || sCode[1] > 'Z') {
		return;
	}
	// 'A'..'Z' -> U+1F1E6..U+1F1FF (UTF-8: F0 9F 87 A6..BF).
	FormatEx(sFlag, iMaxLen, "\xF0\x9F\x87%c\xF0\x9F\x87%c", 0xA6 + (sCode[0] - 'A'), 0xA6 + (sCode[1] - 'A'));
}

// How many times this player disconnected during the mix (DC entries are
// per-leave and stay on file until Stop1v1 clears them - after this runs).
int CountMixDcEntries(int client) {
	if(g_alDcPlayers == null) {
		return 0;
	}
	char sAuth[32];
	if(!GetClientAuthCached(client, sAuth, sizeof(sAuth))) {
		return 0;
	}

	int iCount = 0;
	DcPlayer_t dc;
	for(int i = 0; i < g_alDcPlayers.Length; i++) {
		g_alDcPlayers.GetArray(i, dc, sizeof(DcPlayer_t));
		if(StrEqual(dc.sAuth, sAuth)) {
			iCount++;
		}
	}
	return iCount;
}

// Leaderboards (!mixtop) and ranked status (!mixrank), reading the cumulative stats table. The elo
// column already exists with everyone at 1000, every display reads it, and ranks are computed
// live from it, so the elo system only has to UPDATE the column at mix end.

// (MIX_LB_* live with the elo constants near the top of the file: the Discord
// leaderboard globals are declared up there and need them.)
// (MIX_DEFAULT_ELO lives with the elo constants near the top of the file.)

static const char g_saMixLbTitles[][] = {
	"", "Rank/ELO", "Win/Loss Ratio", "Survival Time", "Stabs Given/Taken", "Fall Damage", "Clutches"
};

// Rank = 1 + the number of players ahead on the Rank/Elo leaderboard.
// The key is (elo, then win/loss ratio) - the same order !mixtop lists -
// so only players
void Mix_GetRankString(int iRankPos, char[] sBuffer, int iMaxLen) {
	if(iRankPos > 0) {
		FormatEx(sBuffer, iMaxLen, "#%d", iRankPos);
	}
	else {
		strcopy(sBuffer, iMaxLen, "NA");
	}
}

// One shared cooldown for both DB-reading commands. Paging uses a shorter
// gate so flipping through pages doesn't crawl.
bool CheckLbCooldown(int client, float fSeconds = 3.0) {
	if(GetGameTime() < g_faNextLbQuery[client]) {
		MixPrintToChat(client, "Please wait a moment before requesting more stats.");
		return false;
	}
	g_faNextLbQuery[client] = GetGameTime() + fSeconds;
	return true;
}

// Chat rows wrap with very long names, so displayed names clamp to 15 characters, backing over a
// split UTF-8 sequence so no broken byte is printed. iMax defaults to the chat width; Discord's
// narrow columns pass a smaller cap, because a name that wraps pushes the rest of ITS column
// down and desynchronises the two halves.
void TruncateMixName(char[] sName, int iMax = 15) {
	if(strlen(sName) <= iMax) {
		return;
	}
	while(iMax > 0 && (sName[iMax] & 0xC0) == 0x80) {
		iMax--;
	}
	sName[iMax] = '\0';
}

// Staggered chat output for the leaderboard: first batch prints immediately,
// a repeating timer drains the rest so no line is lost to same-frame drops.
#define LB_CHAT_BATCH 4       // lines per frame - more risks silent drops
#define LB_CHAT_INTERVAL 0.15
#define LB_CHAT_LINE_LEN 256

void LbChatQueueLine(int client, bool bPrefix, const char[] format, any ...) {
	char sMsg[LB_CHAT_LINE_LEN];
	SetGlobalTransTarget(client);
	VFormat(sMsg, sizeof(sMsg), format, 4);
	FormatMixChatColors(sMsg, sizeof(sMsg));

	// Leading space: CS:GO swallows a color code that is the very first byte
	// of a chat message.
	char sLine[LB_CHAT_LINE_LEN];
	if(bPrefix) {
		FormatEx(sLine, sizeof(sLine), " \x01[\x07%s\x01]\x08 %s", g_sChatPrefix, sMsg);
	}
	else {
		FormatEx(sLine, sizeof(sLine), " %s", sMsg);
	}

	if(g_alLbChatQueue[client] == null) {
		g_alLbChatQueue[client] = new ArrayList(ByteCountToCells(LB_CHAT_LINE_LEN));
	}
	g_alLbChatQueue[client].PushString(sLine);
}

// Prints up to LB_CHAT_BATCH queued lines; deletes the queue once empty.
void LbChatDrainBatch(int client) {
	ArrayList alQueue = g_alLbChatQueue[client];
	if(alQueue == null) {
		return;
	}

	char sLine[LB_CHAT_LINE_LEN];
	int iCount = (alQueue.Length < LB_CHAT_BATCH) ? alQueue.Length : LB_CHAT_BATCH;
	for(int i = 0; i < iCount; i++) {
		alQueue.GetString(0, sLine, sizeof(sLine));
		alQueue.Erase(0);
		PrintToChat(client, "%s", sLine);
	}

	if(alQueue.Length == 0) {
		delete g_alLbChatQueue[client]; // delete() nulls the slot
	}
}

void LbChatFlushQueue(int client) {
	if(g_haLbChatTimer[client] != null) {
		return; // a drain is already running - it picks the new lines up too
	}
	LbChatDrainBatch(client);
	if(g_alLbChatQueue[client] != null) {
		g_haLbChatTimer[client] = CreateTimer(LB_CHAT_INTERVAL, Timer_LbChatDrain, GetClientUserId(client), TIMER_REPEAT | TIMER_FLAG_NO_MAPCHANGE);
	}
}

public Action Timer_LbChatDrain(Handle timer, any userid) {
	int client = GetClientOfUserId(userid);
	if(client < 1 || !IsClientInGame(client)) {
		return Plugin_Stop; // slot may be reused already - touch nothing
	}

	LbChatDrainBatch(client);
	if(g_alLbChatQueue[client] == null) {
		g_haLbChatTimer[client] = null;
		return Plugin_Stop;
	}
	return Plugin_Continue;
}

public Action Command_MixLeaderboard(int client, int args) {
	if(client == 0) {
		ReplyToCommand(client, "[%s] This command must be used in-game.", g_sChatPrefix);
		return Plugin_Handled;
	}

	if(g_hStatsDb == null) {
		MixPrintToChat(client, "The stats database is not connected.");
		return Plugin_Handled;
	}

	char sTitle[64];
	FormatEx(sTitle, sizeof(sTitle), "[%s] Leaderboard System", g_sChatPrefix);

	Panel panel = new Panel();
	panel.SetTitle(sTitle);
	panel.DrawItem("Rank/Elo");       // 1
	panel.DrawItem("Win/Loss Ratio"); // 2
	panel.DrawItem("Survival Time");  // 3
	panel.DrawItem("Stabs");          // 4
	panel.DrawItem("Fall Damage");    // 5
	panel.DrawItem("Clutches");       // 6
	panel.DrawText(" ");              // slot 7 reserved for a future category
	panel.DrawText(" ");              // slot 8 empty by design
	panel.CurrentKey = 9;
	panel.DrawItem("Exit");           // 9
	panel.Send(client, PanelHandler_MixLb, MENU_TIME_FOREVER);
	delete panel;

	return Plugin_Handled;
}

public int PanelHandler_MixLb(Menu menu, MenuAction action, int param1, int param2) {
	if(action == MenuAction_Select && param2 >= MIX_LB_ELO && param2 <= MIX_LB_CLUTCHES) {
		// One user action, gated once -> the chat board AND the scrollable
		// stats menu (both skip their own gate so the pair isn't blocked).
		if(!CheckLbCooldown(param1, 1.0)) {
			return 0;
		}
		RunMixLbQuery(param1, param2, 0, false);
		OpenMixLbMenu(param1, param2);
	}
	return 0;
}

void RunMixLbQuery(int client, int iCategory, int iPage = 0, bool bCheckCooldown = true) {
	if(g_hStatsDb == null) {
		MixPrintToChat(client, "The stats database is not connected.");
		return;
	}

	if(bCheckCooldown && !CheckLbCooldown(client, 1.0)) {
		return;
	}

	int iLimit = cv_LbEntries.IntValue;
	int iOffset = iPage * iLimit;
	char sQuery[512];

	switch(iCategory) {
		case MIX_LB_ELO: {
			// The * 1.0 forces float division (SQLite divides ints as ints).
			FormatEx(sQuery, sizeof(sQuery),
				"SELECT name, elo, wins, losses, stabs_given FROM `%s_stats` \
				ORDER BY elo DESC, (wins * 1.0 / %s(wins + losses, 1)) DESC, wins DESC LIMIT %d OFFSET %d",
				g_sSqlPrefix, g_sSqlMax, iLimit, iOffset);
		}
		case MIX_LB_WL: {
			// The minimum-games gate also guards the ratio against
			// division by zero (0-game rows never qualify).
			int iMinGames = cv_LbMinGames.IntValue;
			if(iMinGames < 1) {
				iMinGames = 1;
			}
			FormatEx(sQuery, sizeof(sQuery),
				"SELECT name, wins, losses FROM `%s_stats` WHERE (wins + losses) >= %d \
				ORDER BY (wins * 1.0 / (wins + losses)) DESC, wins DESC LIMIT %d OFFSET %d",
				g_sSqlPrefix, iMinGames, iLimit, iOffset);
		}
		case MIX_LB_SURVIVAL: {
			FormatEx(sQuery, sizeof(sQuery),
				"SELECT name, survival_time, t_rounds FROM `%s_stats` WHERE survival_time > 0 \
				ORDER BY survival_time DESC LIMIT %d OFFSET %d",
				g_sSqlPrefix, iLimit, iOffset);
		}
		case MIX_LB_STABS: {
			FormatEx(sQuery, sizeof(sQuery),
				"SELECT name, stabs_given, stabs_taken FROM `%s_stats` WHERE (stabs_given + stabs_taken) > 0 \
				ORDER BY stabs_given DESC, stabs_taken DESC LIMIT %d OFFSET %d",
				g_sSqlPrefix, iLimit, iOffset);
		}
		case MIX_LB_FALLDMG: {
			FormatEx(sQuery, sizeof(sQuery),
				"SELECT name, fall_damage FROM `%s_stats` WHERE fall_damage > 0 \
				ORDER BY fall_damage DESC LIMIT %d OFFSET %d",
				g_sSqlPrefix, iLimit, iOffset);
		}
		case MIX_LB_CLUTCHES: {
			FormatEx(sQuery, sizeof(sQuery),
				"SELECT name, clutches FROM `%s_stats` WHERE clutches > 0 \
				ORDER BY clutches DESC LIMIT %d OFFSET %d",
				g_sSqlPrefix, iLimit, iOffset);
		}
		default: {
			return;
		}
	}

	// Paging session: "next"/"back" (chat or command) act on this for the
	// next two minutes.
	g_iaLbCategory[client] = iCategory;
	g_iaLbPage[client] = iPage;
	g_faLbSessionEnd[client] = GetGameTime() + 120.0;

	// Packed callback data: userid in bits 0-19 (userids stay far below a
	// million), category in 20-22, page in 23-26 - clear of the sign bit.
	g_hStatsDb.Query(SqlCallback_MixLb, sQuery,
		(GetClientUserId(client) & 0xFFFFF) | (iCategory << 20) | (iPage << 23));
}

// Shared by !next / !back and the bare chat words.
void MixLbTurnPage(int client, int iDir) {
	if(g_faLbSessionEnd[client] < GetGameTime()) {
		MixPrintToChat(client, "Open a leaderboard first - \x10!mixtop\x08.");
		return;
	}

	int iPage = g_iaLbPage[client] + iDir;
	if(iPage < 0) {
		MixPrintToChat(client, "You're already on the first page.");
		return;
	}
	if(iPage * cv_LbEntries.IntValue >= 100) {
		MixPrintToChat(client, "The leaderboard only lists the top \x10100\x08.");
		return;
	}

	RunMixLbQuery(client, g_iaLbCategory[client], iPage);
}

public Action Command_MixLbNext(int client, int args) {
	if(client >= 1) {
		MixLbTurnPage(client, 1);
	}
	return Plugin_Handled;
}

public Action Command_MixLbBack(int client, int args) {
	if(client >= 1) {
		MixLbTurnPage(client, -1);
	}
	return Plugin_Handled;
}

// Bare chat words, swallowed (never shown in chat): "votemix" starts a mix
// vote; "next"/"back" page the last viewed leaderboard (only while a
// recently viewed board is active - otherwise they pass through as chat).
public Action ChatListener_MixWords(int client, const char[] command, int argc) {
	if(client < 1) {
		return Plugin_Continue;
	}

	char sMsg[32];
	GetCmdArgString(sMsg, sizeof(sMsg));
	StripQuotes(sMsg);
	TrimString(sMsg);

	// Pending self-replace offer: a bare yes/no in chat answers it
	// (case-insensitive) and never shows in chat.
	if(g_iaSelfOfferFrom[client] != 0) {
		if(StrEqual(sMsg, "yes", false)) {
			HandleSelfReplaceAnswer(client, true);
			return Plugin_Handled;
		}
		if(StrEqual(sMsg, "no", false)) {
			HandleSelfReplaceAnswer(client, false);
			return Plugin_Handled;
		}
	}

	if(StrEqual(sMsg, "votemix", false)) {
		Command_VoteMix(client, 0);
		return Plugin_Handled;
	}

	if(g_faLbSessionEnd[client] < GetGameTime()) {
		return Plugin_Continue;
	}

	if(StrEqual(sMsg, "next", false) || StrEqual(sMsg, "next page", false)) {
		MixLbTurnPage(client, 1);
		return Plugin_Handled;
	}
	if(StrEqual(sMsg, "back", false) || StrEqual(sMsg, "back page", false) || StrEqual(sMsg, "prev", false)) {
		MixLbTurnPage(client, -1);
		return Plugin_Handled;
	}
	return Plugin_Continue;
}

public void SqlCallback_MixLb(Database db, DBResultSet results, const char[] error, any data) {
	int client = GetClientOfUserId(data & 0xFFFFF);
	int iCategory = (data >> 20) & 0x7;
	int iPage = (data >> 23) & 0xF;

	if(client < 1 || !IsClientInGame(client) || iCategory < MIX_LB_ELO || iCategory > MIX_LB_CLUTCHES) {
		return;
	}

	if(results == null) {
		LogError("[MIX] Leaderboard query failed: %s", error);
		MixPrintToChat(client, "The leaderboard is unavailable right now.");
		return;
	}

	int iSize = cv_LbEntries.IntValue;
	int iOffset = iPage * iSize;

	if(!results.RowCount) {
		if(iPage > 0) {
			// Ran off the end: stay on the page they were actually viewing.
			g_iaLbPage[client] = iPage - 1;
			MixPrintToChat(client, "No more entries.");
		}
		else {
			ScoreboardPrintOne(client, true, "%t", "Mix LB Header", g_saMixLbTitles[iCategory]);
			ScoreboardPrintOne(client, false, "%t", "Mix LB Empty");
		}
		return;
	}

	char sTitle[64];
	if(iPage > 0) {
		FormatEx(sTitle, sizeof(sTitle), "%s - Page %d", g_saMixLbTitles[iCategory], iPage + 1);
	}
	else {
		strcopy(sTitle, sizeof(sTitle), g_saMixLbTitles[iCategory]);
	}
	LbChatQueueLine(client, true, "%t", "Mix LB Header", sTitle);

	char sName[MAX_NAME_LENGTH];
	int iRow = 0;
	int iRank = 0;
	// Competition ranking, matching !rank: rows tied on the ORDER BY keys
	// share a rank, the next distinct row jumps to its list position
	// (#1, #1, #3, ...). iPrevKeyA/B carry the previous row's sort keys.
	int iPrevKeyA = 0;
	int iPrevKeyB = 0;
	int iPrevKeyC = 0;

	while(results.FetchRow()) {
		results.FetchString(0, sName, sizeof(sName));
		TruncateMixName(sName);
		iRow++;

		switch(iCategory) {
			case MIX_LB_ELO: {
				int iElo = results.FetchInt(1);
				int iWins = results.FetchInt(2);
				int iLosses = results.FetchInt(3);
				int iStabs = results.FetchInt(4);
				int iGames = iWins + iLosses;
				// Rank key = (elo, W/L ratio) - matches !rank. Ratio equality
				// via cross-multiplication, with a 1-game floor so 0-game
				// rows compare as 0%.
				int iEffGames = (iGames > 0) ? iGames : 1;
				if(iRow == 1 || iElo != iPrevKeyA || iWins * iPrevKeyC != iPrevKeyB * iEffGames) {
					iRank = iOffset + iRow;
				}
				iPrevKeyA = iElo;
				iPrevKeyB = iWins;
				iPrevKeyC = iEffGames;
				LbChatQueueLine(client, false, "%t", "Mix LB Row Elo", iRank, sName, iElo, iGames, iWins, iStabs);
			}
			case MIX_LB_WL: {
				int iWins = results.FetchInt(1);
				int iLosses = results.FetchInt(2);
				int iGames = iWins + iLosses;
				// Sort keys are (win rate, wins); rates compared by
				// cross-multiplication (games >= 1 on this board).
				if(iRow == 1 || iWins != iPrevKeyA || iWins * iPrevKeyB != iPrevKeyA * iGames) {
					iRank = iOffset + iRow;
				}
				iPrevKeyA = iWins;
				iPrevKeyB = iGames;
				char sRatio[16];
				FormatEx(sRatio, sizeof(sRatio), "%.1f%%", iGames > 0 ? (float(iWins) / float(iGames)) * 100.0 : 0.0);
				LbChatQueueLine(client, false, "%t", "Mix LB Row WL", iRank, sName, iGames, iWins, iLosses, sRatio);
			}
			case MIX_LB_SURVIVAL: {
				int iSecs = results.FetchInt(1);
				int iTRounds = results.FetchInt(2);
				if(iRow == 1 || iSecs != iPrevKeyA) {
					iRank = iOffset + iRow;
				}
				iPrevKeyA = iSecs;
				char sTotal[24];
				FormatEx(sTotal, sizeof(sTotal), "%ds", iSecs);
				// Rows banked before the t_rounds column existed have no
				// denominator - their average shows as N/A until they play.
				char sAvg[24];
				if(iTRounds > 0) {
					float fAvg = float(iSecs) / float(iTRounds);
					if(fAvg >= 60.0) {
						FormatEx(sAvg, sizeof(sAvg), "%ds", RoundToNearest(fAvg));
					}
					else {
						FormatEx(sAvg, sizeof(sAvg), "%.1fs", fAvg);
					}
				}
				else {
					strcopy(sAvg, sizeof(sAvg), "N/A");
				}
				LbChatQueueLine(client, false, "%t", "Mix LB Row Survival", iRank, sName, sTotal, sAvg);
			}
			case MIX_LB_STABS: {
				int iGiven = results.FetchInt(1);
				int iTaken = results.FetchInt(2);
				if(iRow == 1 || iGiven != iPrevKeyA || iTaken != iPrevKeyB) {
					iRank = iOffset + iRow;
				}
				iPrevKeyA = iGiven;
				iPrevKeyB = iTaken;
				LbChatQueueLine(client, false, "%t", "Mix LB Row Stabs", iRank, sName, iGiven, iTaken);
			}
			case MIX_LB_FALLDMG: {
				int iValue = results.FetchInt(1);
				if(iRow == 1 || iValue != iPrevKeyA) {
					iRank = iOffset + iRow;
				}
				iPrevKeyA = iValue;
				LbChatQueueLine(client, false, "%t", "Mix LB Row FallDmg", iRank, sName, iValue);
			}
			case MIX_LB_CLUTCHES: {
				int iValue = results.FetchInt(1);
				if(iRow == 1 || iValue != iPrevKeyA) {
					iRank = iOffset + iRow;
				}
				iPrevKeyA = iValue;
				LbChatQueueLine(client, false, "%t", "Mix LB Row Clutches", iRank, sName, iValue);
			}
		}
	}

	// Full page with more of the top 100 left: tell them how to page.
	if(iRow == iSize && (iPage + 1) * iSize < 100) {
		LbChatQueueLine(client, true, "Say \x10next\x08 / \x10back\x08 (or \x10!next\x08 / \x10!back\x08) to page through the top 100.");
	}

	LbChatFlushQueue(client);
}

// The scrollable stats menu behind every leaderboard category. Always the same columns - Rank,
// Elo, Games, Won, Stabs, Clutches, Name - ordered by whichever category was picked. Rank is the
// elo-based rank, computed per row by SQL so it is correct regardless of sort. The radio menu
// paginates the top 100 itself, so no chat paging is needed.

// Per-category WHERE + ORDER BY, shared by the chat board and this menu.
void GetMixLbFilterSort(int iCategory, char[] sBuffer, int iMaxLen) {
	switch(iCategory) {
		case MIX_LB_ELO: {
			FormatEx(sBuffer, iMaxLen, "ORDER BY elo DESC, (wins * 1.0 / %s(wins + losses, 1)) DESC, wins DESC", g_sSqlMax);
		}
		case MIX_LB_WL: {
			int iMinGames = cv_LbMinGames.IntValue;
			if(iMinGames < 1) {
				iMinGames = 1;
			}
			FormatEx(sBuffer, iMaxLen, "WHERE (wins + losses) >= %d ORDER BY (wins * 1.0 / (wins + losses)) DESC, wins DESC", iMinGames);
		}
		case MIX_LB_SURVIVAL: {
			strcopy(sBuffer, iMaxLen, "WHERE survival_time > 0 ORDER BY survival_time DESC");
		}
		case MIX_LB_STABS: {
			strcopy(sBuffer, iMaxLen, "WHERE (stabs_given + stabs_taken) > 0 ORDER BY stabs_given DESC, stabs_taken DESC");
		}
		case MIX_LB_FALLDMG: {
			strcopy(sBuffer, iMaxLen, "WHERE fall_damage > 0 ORDER BY fall_damage DESC");
		}
		case MIX_LB_CLUTCHES: {
			strcopy(sBuffer, iMaxLen, "WHERE clutches > 0 ORDER BY clutches DESC");
		}
		default: {
			sBuffer[0] = '\0';
		}
	}
}

// Left-align sVal into a fixed iWidth field. The menu font is proportional
// and a space is ~half a digit wide, so each missing char pads TWO spaces -
// single-space padding drifted columns whenever digit counts differed.
void ColL(char[] sOut, int iOutLen, const char[] sVal, int iWidth) {
	int p = 0;
	for(int i = 0; sVal[i] != '\0' && p < iOutLen - 1; i++) {
		sOut[p++] = sVal[i];
	}
	for(int iLen = strlen(sVal); iLen < iWidth && p < iOutLen - 2; iLen++) {
		sOut[p++] = ' ';
		sOut[p++] = ' ';
	}
	sOut[p] = '\0';
}

void OpenMixLbMenu(int client, int iCategory) {
	if(g_hStatsDb == null || iCategory < MIX_LB_ELO || iCategory > MIX_LB_CLUTCHES) {
		return;
	}

	char sFilterSort[256];
	GetMixLbFilterSort(iCategory, sFilterSort, sizeof(sFilterSort));

	// elo_rank is the elo+ratio competition rank, matching !rank, so the Rank column is a player's
	// global standing even when sorted by another stat. steamid rides along so selecting a row can
	// pull up that player's full profile.
	char sQuery[1024];
	FormatEx(sQuery, sizeof(sQuery),
		"SELECT name, elo, wins, losses, stabs_given, stabs_taken, fall_damage, clutches, survival_time, t_rounds, steamid, \
		(SELECT COUNT(*) + 1 FROM `%s_stats` s2 WHERE s2.elo > s1.elo OR (s2.elo = s1.elo \
		AND (s2.wins * 1.0 / %s(s2.wins + s2.losses, 1)) > (s1.wins * 1.0 / %s(s1.wins + s1.losses, 1)))) \
		FROM `%s_stats` s1 %s LIMIT 100",
		g_sSqlPrefix, g_sSqlMax, g_sSqlMax, g_sSqlPrefix, sFilterSort);

	// No cooldown check here: this is fired together with RunMixLbQuery, which
	// already gated the user's action.
	g_hStatsDb.Query(SqlCallback_MixLbMenu, sQuery,
		(GetClientUserId(client) & 0xFFFFF) | (iCategory << 20));
}

public void SqlCallback_MixLbMenu(Database db, DBResultSet results, const char[] error, any data) {
	int client = GetClientOfUserId(data & 0xFFFFF);
	int iCategory = (data >> 20) & 0x7;

	if(client < 1 || !IsClientInGame(client) || iCategory < MIX_LB_ELO || iCategory > MIX_LB_CLUTCHES) {
		return;
	}

	if(results == null) {
		LogError("[MIX] Leaderboard menu query failed: %s", error);
		return;
	}

	Menu menu = new Menu(MenuHandler_MixLbMenu);

	// Category on top, then a right-aligned header whose widths match the value columns so their right
	// edges line up. The radio menu uses a PROPORTIONAL font, so this is as tight as space-padding
	// allows and is not pixel-perfect when digit counts differ. Each menu shows only its own columns.
	char sHeader[128], h[48];
	sHeader[0] = '\0';
	switch(iCategory) {
		case MIX_LB_ELO: {
			ColL(h, sizeof(h), "Rank", 5);  StrCat(sHeader, sizeof(sHeader), h);
			ColL(h, sizeof(h), "Elo", 7);   StrCat(sHeader, sizeof(sHeader), h);
			ColL(h, sizeof(h), "Games", 7); StrCat(sHeader, sizeof(sHeader), h);
			ColL(h, sizeof(h), "Won", 6);   StrCat(sHeader, sizeof(sHeader), h);
			ColL(h, sizeof(h), "Stabs", 7); StrCat(sHeader, sizeof(sHeader), h);
			StrCat(sHeader, sizeof(sHeader), "  Player");
		}
		case MIX_LB_WL: {
			ColL(h, sizeof(h), "Games", 6); StrCat(sHeader, sizeof(sHeader), h);
			ColL(h, sizeof(h), "Won", 6);   StrCat(sHeader, sizeof(sHeader), h);
			ColL(h, sizeof(h), "Lost", 6);  StrCat(sHeader, sizeof(sHeader), h);
			ColL(h, sizeof(h), "Ratio", 9); StrCat(sHeader, sizeof(sHeader), h);
			StrCat(sHeader, sizeof(sHeader), "  Player");
		}
		case MIX_LB_SURVIVAL: {
			ColL(h, sizeof(h), "Total S/T", 11); StrCat(sHeader, sizeof(sHeader), h);
			ColL(h, sizeof(h), "Avg S/T", 9);    StrCat(sHeader, sizeof(sHeader), h);
			StrCat(sHeader, sizeof(sHeader), "  Player");
		}
		case MIX_LB_STABS: {
			ColL(h, sizeof(h), "Given", 8); StrCat(sHeader, sizeof(sHeader), h);
			ColL(h, sizeof(h), "Taken", 8); StrCat(sHeader, sizeof(sHeader), h);
			StrCat(sHeader, sizeof(sHeader), "  Player");
		}
		case MIX_LB_FALLDMG: {
			ColL(h, sizeof(h), "Fall DMG", 10); StrCat(sHeader, sizeof(sHeader), h);
			StrCat(sHeader, sizeof(sHeader), "  Player");
		}
		case MIX_LB_CLUTCHES: {
			ColL(h, sizeof(h), "Clutches", 10); StrCat(sHeader, sizeof(sHeader), h);
			StrCat(sHeader, sizeof(sHeader), "  Player");
		}
	}

	// Rows carry the radio menu's "1. " number prefix but the title doesn't -
	// the leading spaces compensate so the header sits over the value columns.
	char sTitle[160];
	FormatEx(sTitle, sizeof(sTitle), "Mix Leaderboard - %s\n     %s", g_saMixLbTitles[iCategory], sHeader);
	menu.SetTitle(sTitle);

	// 5 players per page (Next/Back/Exit fill the remaining slots).
	menu.Pagination = 5;
	menu.ExitButton = true;

	char sName[MAX_NAME_LENGTH], sRow[224], sSteamId[32], sTmp[24];
	char sA[48], sB[48], sC[48], sD[48], sE[48];
	int iRows = 0;

	while(results.FetchRow()) {
		results.FetchString(0, sName, sizeof(sName));
		TruncateMixName(sName);
		int iElo = results.FetchInt(1);
		int iWins = results.FetchInt(2);
		int iLosses = results.FetchInt(3);
		int iGiven = results.FetchInt(4);
		int iTaken = results.FetchInt(5);
		int iFall = results.FetchInt(6);
		int iClutches = results.FetchInt(7);
		int iSecs = results.FetchInt(8);
		int iTRounds = results.FetchInt(9);
		results.FetchString(10, sSteamId, sizeof(sSteamId));
		int iEloRank = results.FetchInt(11);
		int iGames = iWins + iLosses;

		// Items are ITEMDRAW_DEFAULT (selectable) so CS:GO draws them in its
		// native orange menu color; steamid is the item info for the select.
		// Column widths here MUST match the header widths above.
		switch(iCategory) {
			case MIX_LB_ELO: {
				FormatEx(sTmp, sizeof(sTmp), "#%d", iEloRank); ColL(sA, sizeof(sA), sTmp, 5);
				FormatEx(sTmp, sizeof(sTmp), "%d", iElo);      ColL(sB, sizeof(sB), sTmp, 7);
				FormatEx(sTmp, sizeof(sTmp), "%d", iGames);    ColL(sC, sizeof(sC), sTmp, 7);
				FormatEx(sTmp, sizeof(sTmp), "%d", iWins);     ColL(sD, sizeof(sD), sTmp, 6);
				FormatEx(sTmp, sizeof(sTmp), "%d", iGiven);    ColL(sE, sizeof(sE), sTmp, 7);
				FormatEx(sRow, sizeof(sRow), "%s%s%s%s%s  » %s", sA, sB, sC, sD, sE, sName);
			}
			case MIX_LB_WL: {
				float fRatio = (iGames > 0) ? (float(iWins) / float(iGames)) * 100.0 : 0.0;
				FormatEx(sTmp, sizeof(sTmp), "%d", iGames);    ColL(sA, sizeof(sA), sTmp, 6);
				FormatEx(sTmp, sizeof(sTmp), "%d", iWins);     ColL(sB, sizeof(sB), sTmp, 6);
				FormatEx(sTmp, sizeof(sTmp), "%d", iLosses);   ColL(sC, sizeof(sC), sTmp, 6);
				FormatEx(sTmp, sizeof(sTmp), "%.1f%%", fRatio);ColL(sD, sizeof(sD), sTmp, 9);
				FormatEx(sRow, sizeof(sRow), "%s%s%s%s  » %s", sA, sB, sC, sD, sName);
			}
			case MIX_LB_SURVIVAL: {
				FormatEx(sTmp, sizeof(sTmp), "%ds", iSecs);
				ColL(sA, sizeof(sA), sTmp, 11);
				if(iTRounds > 0) {
					float fAvg = float(iSecs) / float(iTRounds);
					if(fAvg >= 60.0) {
						FormatEx(sTmp, sizeof(sTmp), "%ds", RoundToNearest(fAvg));
					}
					else {
						FormatEx(sTmp, sizeof(sTmp), "%.1fs", fAvg);
					}
				}
				else {
					strcopy(sTmp, sizeof(sTmp), "N/A");
				}
				ColL(sB, sizeof(sB), sTmp, 9);
				FormatEx(sRow, sizeof(sRow), "%s%s  » %s", sA, sB, sName);
			}
			case MIX_LB_STABS: {
				FormatEx(sTmp, sizeof(sTmp), "%d", iGiven);    ColL(sA, sizeof(sA), sTmp, 8);
				FormatEx(sTmp, sizeof(sTmp), "%d", iTaken);    ColL(sB, sizeof(sB), sTmp, 8);
				FormatEx(sRow, sizeof(sRow), "%s%s  » %s", sA, sB, sName);
			}
			case MIX_LB_FALLDMG: {
				FormatEx(sTmp, sizeof(sTmp), "%d", iFall);     ColL(sA, sizeof(sA), sTmp, 10);
				FormatEx(sRow, sizeof(sRow), "%s  » %s", sA, sName);
			}
			case MIX_LB_CLUTCHES: {
				FormatEx(sTmp, sizeof(sTmp), "%d", iClutches); ColL(sA, sizeof(sA), sTmp, 10);
				FormatEx(sRow, sizeof(sRow), "%s  » %s", sA, sName);
			}
		}

		menu.AddItem(sSteamId, sRow);
		iRows++;
	}

	if(iRows == 0) {
		menu.AddItem("", "No entries yet.", ITEMDRAW_DISABLED);
	}

	menu.Display(client, MENU_TIME_FOREVER);
}

public int MenuHandler_MixLbMenu(Menu menu, MenuAction action, int param1, int param2) {
	if(action == MenuAction_Select) {
		// Selecting a row shows that player's full profile in chat (the menu
		// closes, like KZ's top-list detail view). No cooldown gate: the menu
		// closes on select, and re-opening the board is already gated.
		char sSteamId[32];
		menu.GetItem(param2, sSteamId, sizeof(sSteamId));
		if(sSteamId[0] && g_hStatsDb != null) {
			QueryMixRankBySteamId(param1, sSteamId, 0);
		}
	}
	else if(action == MenuAction_End) {
		delete menu;
	}
	return 0;
}

public Action Command_MixRank(int client, int args) {
	if(client == 0) {
		ReplyToCommand(client, "[%s] This command must be used in-game.", g_sChatPrefix);
		return Plugin_Handled;
	}

	if(g_hStatsDb == null) {
		MixPrintToChat(client, "The stats database is not connected.");
		return Plugin_Handled;
	}

	if(!CheckLbCooldown(client)) {
		return Plugin_Handled;
	}

	char sTarget[MAX_NAME_LENGTH];
	if(args >= 1) {
		GetCmdArgString(sTarget, sizeof(sTarget));
		StripQuotes(sTarget);
		TrimString(sTarget);
	}

	// No name given: look yourself up.
	if(!sTarget[0]) {
		char sAuth[32];
		if(!GetClientAuthCached(client, sAuth, sizeof(sAuth))) {
			MixPrintToChat(client, "Your SteamID isn't available yet - try again in a moment.");
			return Plugin_Handled;
		}
		QueryMixRankBySteamId(client, sAuth, client);
		return Plugin_Handled;
	}

	// Online players first: an exact name match wins, otherwise a unique
	// partial match; ambiguity asks for a longer fragment.
	int iExact = -1;
	int iPartial = -1;
	int iPartialCount = 0;
	char sName[MAX_NAME_LENGTH];
	for(int i = 1; i <= MaxClients; i++) {
		if(!IsClientInGame(i) || IsFakeClient(i)) {
			continue;
		}
		GetClientName(i, sName, sizeof(sName));
		if(StrEqual(sName, sTarget, false)) {
			iExact = i;
			break;
		}
		if(StrContains(sName, sTarget, false) != -1) {
			iPartial = i;
			iPartialCount++;
		}
	}

	if(iExact == -1 && iPartialCount > 1) {
		MixPrintToChat(client, "Multiple players match \x0F%s\x08 - be more specific.", sTarget);
		return Plugin_Handled;
	}

	int target = (iExact != -1) ? iExact : ((iPartialCount == 1) ? iPartial : -1);
	if(target != -1) {
		char sAuth[32];
		if(GetClientAuthCached(target, sAuth, sizeof(sAuth))) {
			QueryMixRankBySteamId(client, sAuth, target);
			return Plugin_Handled;
		}
	}

	// Nobody online matches (or their auth isn't ready): search the stats
	// table by stored name, so offline players can be looked up too.
	QueryMixRankByName(client, sTarget);
	return Plugin_Handled;
}

void QueryMixRankBySteamId(int client, const char[] sAuth, int target) {
	char sQuery[768];
	FormatEx(sQuery, sizeof(sQuery),
		"SELECT name, elo, wins, losses, survival_time, stabs_given, stabs_taken, fall_damage, clutches, \
		(SELECT COUNT(*) + 1 FROM `%s_stats` s2 WHERE s2.elo > s1.elo OR (s2.elo = s1.elo \
		AND (s2.wins * 1.0 / %s(s2.wins + s2.losses, 1)) > (s1.wins * 1.0 / %s(s1.wins + s1.losses, 1)))) \
		FROM `%s_stats` s1 WHERE steamid = '%s' LIMIT 1",
		g_sSqlPrefix, g_sSqlMax, g_sSqlMax, g_sSqlPrefix, sAuth);

	DataPack pack = new DataPack();
	pack.WriteCell(GetClientUserId(client));
	pack.WriteCell((target > 0) ? GetClientUserId(target) : 0); // live name beats the stored one
	pack.WriteString("");
	g_hStatsDb.Query(SqlCallback_MixRank, sQuery, pack);
}

void QueryMixRankByName(int client, const char[] sSearch) {
	// SQL-escape first, then neutralize the LIKE wildcards so names with
	// % or _ match literally. '!' is the escape char (declared via ESCAPE,
	// which works the same on MySQL and SQLite - backslash doesn't).
	char sEsc[256];
	g_hStatsDb.Escape(sSearch, sEsc, sizeof(sEsc));
	ReplaceString(sEsc, sizeof(sEsc), "!", "!!");
	ReplaceString(sEsc, sizeof(sEsc), "%", "!%");
	ReplaceString(sEsc, sizeof(sEsc), "_", "!_");

	char sQuery[900];
	FormatEx(sQuery, sizeof(sQuery),
		"SELECT name, elo, wins, losses, survival_time, stabs_given, stabs_taken, fall_damage, clutches, \
		(SELECT COUNT(*) + 1 FROM `%s_stats` s2 WHERE s2.elo > s1.elo OR (s2.elo = s1.elo \
		AND (s2.wins * 1.0 / %s(s2.wins + s2.losses, 1)) > (s1.wins * 1.0 / %s(s1.wins + s1.losses, 1)))) \
		FROM `%s_stats` s1 WHERE name LIKE '%%%s%%' ESCAPE '!' ORDER BY last_played DESC LIMIT 1",
		g_sSqlPrefix, g_sSqlMax, g_sSqlMax, g_sSqlPrefix, sEsc);

	DataPack pack = new DataPack();
	pack.WriteCell(GetClientUserId(client));
	pack.WriteCell(0);
	pack.WriteString(sSearch);
	g_hStatsDb.Query(SqlCallback_MixRank, sQuery, pack);
}

public void SqlCallback_MixRank(Database db, DBResultSet results, const char[] error, any data) {
	DataPack pack = view_as<DataPack>(data);
	pack.Reset();
	int client = GetClientOfUserId(pack.ReadCell());
	int target = GetClientOfUserId(pack.ReadCell());
	char sSearch[MAX_NAME_LENGTH];
	pack.ReadString(sSearch, sizeof(sSearch));
	delete pack;

	if(client < 1 || !IsClientInGame(client)) {
		return;
	}

	if(results == null) {
		LogError("[MIX] Rank query failed: %s", error);
		MixPrintToChat(client, "Ranked stats are unavailable right now.");
		return;
	}

	if(!results.FetchRow()) {
		if(target > 0) {
			// Known player without a stats row yet: show the defaults
			// everyone starts with instead of an error - !rank always
			// answers for a real player.
			char sLiveName[MAX_NAME_LENGTH];
			GetClientName(target, sLiveName, sizeof(sLiveName));
			TruncateMixName(sLiveName);
			PrintMixRankStatus(client, sLiveName, 0, MIX_DEFAULT_ELO, 0, 0, 0, 0, 0, 0, 0);
		}
		else if(sSearch[0]) {
			MixPrintToChat(client, "No player matching \x0F%s\x08 was found in the MIX stats.", sSearch);
		}
		else {
			MixPrintToChat(client, "You have no recorded MIX stats yet - finish a MIX first.");
		}
		return;
	}

	char sName[MAX_NAME_LENGTH];
	if(target > 0) {
		GetClientName(target, sName, sizeof(sName));
	}
	else {
		results.FetchString(0, sName, sizeof(sName));
	}
	TruncateMixName(sName);

	PrintMixRankStatus(client, sName,
		results.FetchInt(9),  // rank position (computed by the query)
		results.FetchInt(1),  // elo
		results.FetchInt(2),  // wins
		results.FetchInt(3),  // losses
		results.FetchInt(4),  // survival seconds
		results.FetchInt(5),  // stabs given
		results.FetchInt(6),  // stabs taken
		results.FetchInt(7),  // fall damage
		results.FetchInt(8)); // clutches
}

void PrintMixRankStatus(int client, const char[] sName, int iRankPos, int iElo, int iWins, int iLosses, int iSurvivalSecs, int iStabsGiven, int iStabsTaken, int iFallDmg, int iClutches) {
	// Same shape as the end-of-mix scoreboard: total seconds.
	char sTime[24];
	FormatEx(sTime, sizeof(sTime), "%ds", iSurvivalSecs);

	char sRank[16];
	Mix_GetRankString(iRankPos, sRank, sizeof(sRank));

	ScoreboardPrintOne(client, true, "%t", "Mix Rank Header", sName);
	ScoreboardPrintOne(client, false, "%t", "Mix Rank Line1", sRank, iElo);
	ScoreboardPrintOne(client, false, "%t", "Mix Rank Line2", iWins + iLosses, iWins, iLosses);
	ScoreboardPrintOne(client, false, "%t", "Mix Rank Line3", sTime, iStabsGiven, iStabsTaken);
	ScoreboardPrintOne(client, false, "%t", "Mix Rank Line4", iFallDmg, iClutches);
}

// sm_mixreset - wipes leaderboard stats, root only. all deletes every row and needs confirm as the
// second argument; a category reset zeroes just that column set. The live accumulators of the
// same category are zeroed too, so an in-progress mix cannot re-bank pre-reset values.
// ---------------------------------------------------------- targeted resets
// sm_mixreset is server-wide and can wipe elo. These two are the surgical versions: a specific
// player and a specific stat, and neither ever touches elo - a rating is earned against other
// people, so clearing one person's would free-reset every result they ever lost.

// Builds the SET clause for a category. bSelf limits it to what a player may
// clear on themselves; "all" narrows to those same columns in that mode.
bool MixResetColumns(const char[] sCat, char[] sColumns, int iColLen, char[] sWhat, int iWhatLen, bool bSelf) {
	if(StrEqual(sCat, "survival", false) || StrEqual(sCat, "survivaltime", false) || StrEqual(sCat, "time", false)) {
		// Survival time is meaningless without its round count, so both go.
		strcopy(sColumns, iColLen, "survival_time = 0, t_rounds = 0");
		strcopy(sWhat, iWhatLen, "survival time");
		return true;
	}
	if(StrEqual(sCat, "stabs", false) || StrEqual(sCat, "stab", false) || StrEqual(sCat, "ratio", false)) {
		strcopy(sColumns, iColLen, "stabs_given = 0, stabs_taken = 0");
		strcopy(sWhat, iWhatLen, "stabs (given and taken)");
		return true;
	}
	if(StrEqual(sCat, "given", false)) {
		strcopy(sColumns, iColLen, "stabs_given = 0");
		strcopy(sWhat, iWhatLen, "stabs given");
		return true;
	}
	if(StrEqual(sCat, "taken", false)) {
		strcopy(sColumns, iColLen, "stabs_taken = 0");
		strcopy(sWhat, iWhatLen, "stabs taken");
		return true;
	}
	if(StrEqual(sCat, "all", false)) {
		if(bSelf) {
			strcopy(sColumns, iColLen, "survival_time = 0, t_rounds = 0, stabs_given = 0, stabs_taken = 0");
			strcopy(sWhat, iWhatLen, "survival time and stabs");
		}
		else {
			strcopy(sColumns, iColLen, "survival_time = 0, t_rounds = 0, stabs_given = 0, stabs_taken = 0, fall_damage = 0, clutches = 0, wins = 0, losses = 0");
			strcopy(sWhat, iWhatLen, "all stats except elo");
		}
		return true;
	}

	// Admin-only categories below.
	if(bSelf) {
		return false;
	}
	if(StrEqual(sCat, "falldmg", false)) {
		strcopy(sColumns, iColLen, "fall_damage = 0");
		strcopy(sWhat, iWhatLen, "fall damage");
		return true;
	}
	if(StrEqual(sCat, "clutches", false)) {
		strcopy(sColumns, iColLen, "clutches = 0");
		strcopy(sWhat, iWhatLen, "clutches");
		return true;
	}
	if(StrEqual(sCat, "winloss", false)) {
		strcopy(sColumns, iColLen, "wins = 0, losses = 0");
		strcopy(sWhat, iWhatLen, "wins and losses");
		return true;
	}

	return false;
}

// The live and inherited accumulators for one online player, so a reset does
// not get undone by whatever is already banked for the current mix.
void MixClearCachedStats(int client, const char[] sColumns) {
	if(client < 1 || client > MaxClients) {
		return;
	}
	if(StrContains(sColumns, "survival_time") != -1) {
		fTimeSurvived[client] = 0.0;
		g_faInhSurvival[client] = 0.0;
		g_iaMixTRounds[client] = 0;
		g_iaInhTRounds[client] = 0;
	}
	if(StrContains(sColumns, "stabs_given") != -1) {
		g_iaMixStabsGiven[client] = 0;
		g_iaInhStabsGiven[client] = 0;
	}
	if(StrContains(sColumns, "stabs_taken") != -1) {
		g_iaMixStabsTaken[client] = 0;
		g_iaInhStabsTaken[client] = 0;
	}
	if(StrContains(sColumns, "fall_damage") != -1) {
		g_iaMixFallDamage[client] = 0;
		g_iaInhFallDamage[client] = 0;
	}
	if(StrContains(sColumns, "clutches") != -1) {
		g_iaMixClutches[client] = 0;
		g_iaInhClutches[client] = 0;
	}
}

// The console tokenizer splits an unquoted STEAM_1:0:X on its colons, so args
// are re-read from the raw string. CS:GO reports STEAM_1 while admin tools hand
// out STEAM_0, so the universe digit is normalized or the id matches nothing.
int MixSplitRawArgs(char[][] sOut, int iMaxArgs, int iMaxLen) {
	char sRaw[256];
	GetCmdArgString(sRaw, sizeof(sRaw));
	TrimString(sRaw);

	if(!sRaw[0]) {
		return 0;
	}
	return ExplodeString(sRaw, " ", sOut, iMaxArgs, iMaxLen);
}

void MixNormalizeSteamId(char[] sAuth) {
	if(strncmp(sAuth, "STEAM_", 6, false) == 0 && sAuth[6] != '\0' && sAuth[7] == ':') {
		sAuth[6] = '1';
	}
}

void MixRunStatReset(int client, const char[] sAuth, const char[] sName, bool bEveryone, const char[] sColumns, const char[] sWhat) {
	char sQuery[512];

	if(bEveryone) {
		FormatEx(sQuery, sizeof(sQuery), "UPDATE `%s_stats` SET %s", g_sSqlPrefix, sColumns);
		for(int i = 1; i <= MaxClients; i++) {
			MixClearCachedStats(i, sColumns);
		}
	}
	else {
		char sSafe[80];
		g_hStatsDb.Escape(sAuth, sSafe, sizeof(sSafe));
		FormatEx(sQuery, sizeof(sQuery), "UPDATE `%s_stats` SET %s WHERE steamid = '%s'", g_sSqlPrefix, sColumns, sSafe);

		int iOnline = FindClientByAuth(sAuth);
		if(iOnline != -1) {
			MixClearCachedStats(iOnline, sColumns);
		}
	}

	g_hStatsDb.Query(SqlCallback_MixReset, sQuery);
	ReplyToCommand(client, "[%s] Reset %s for %s.", g_sChatPrefix, sWhat, sName);
	LogMessage("[MIX] %L reset %s for %s.", client, sWhat, sName);
}

// Shared guard: a reset mid-mix zeroes the accumulators the results embed and
// the elo maths are about to read.
bool MixResetAllowedNow(int client) {
	if(g_hStatsDb == null) {
		ReplyToCommand(client, "[%s] The stats database is not connected.", g_sChatPrefix);
		return false;
	}
	if(IsMixActive()) {
		ReplyToCommand(client, "[%s] A mix is in progress - this would corrupt its results. Wait for it to finish.", g_sChatPrefix);
		return false;
	}
	return true;
}

public Action Command_MixResetPlayer(int client, int args) {
	if(!MixResetAllowedNow(client)) {
		return Plugin_Handled;
	}

	char sArgs[4][80];
	int iCount = MixSplitRawArgs(sArgs, sizeof(sArgs), sizeof(sArgs[]));

	if(iCount < 1) {
		ReplyToCommand(client, "[%s] Usage: sm_mixresetplayer <player|STEAM_ID|all> [survival|stabs|given|taken|falldmg|clutches|winloss|all]", g_sChatPrefix);
		ReplyToCommand(client, "[%s] Defaults to every stat except elo. Works on offline players by SteamID. Server-wide needs: ... all confirm", g_sChatPrefix);
		return Plugin_Handled;
	}

	// Naming a target but no stat lists the options rather than assuming "all".
	char sColumns[256], sWhat[48];
	if(iCount < 2 || !MixResetColumns(sArgs[1], sColumns, sizeof(sColumns), sWhat, sizeof(sWhat), false)) {
		if(iCount >= 2) {
			ReplyToCommand(client, "[%s] Unknown stat '%s'.", g_sChatPrefix, sArgs[1]);
		}
		ReplyToCommand(client, "[%s] Pick a stat for %s:", g_sChatPrefix, sArgs[0]);
		ReplyToCommand(client, "  survival  - survival time and T-round count");
		ReplyToCommand(client, "  stabs     - stabs given and taken");
		ReplyToCommand(client, "  given / taken - one side of the stab count");
		ReplyToCommand(client, "  falldmg / clutches / winloss");
		ReplyToCommand(client, "  all       - everything above (never elo)");
		ReplyToCommand(client, "[%s] Elo is only resettable server-wide, with sm_mixreset elo.", g_sChatPrefix);
		return Plugin_Handled;
	}

	char sCat[24];
	strcopy(sCat, sizeof(sCat), sArgs[1]);

	bool bEveryone = StrEqual(sArgs[0], "all", false);
	char sAuth[64], sName[MAX_NAME_LENGTH];

	if(bEveryone) {
		strcopy(sName, sizeof(sName), "everyone");
		if(iCount < 3 || !StrEqual(sArgs[2], "confirm", false)) {
			ReplyToCommand(client, "[%s] This resets %s for EVERY player and cannot be undone.", g_sChatPrefix, sWhat);
			ReplyToCommand(client, "[%s] Type: sm_mixresetplayer all %s confirm", g_sChatPrefix, sCat);
			return Plugin_Handled;
		}
	}
	else if(strncmp(sArgs[0], "STEAM_", 6, false) == 0) {
		strcopy(sAuth, sizeof(sAuth), sArgs[0]);
		MixNormalizeSteamId(sAuth);
		strcopy(sName, sizeof(sName), sAuth);
	}
	else {
		int iTarget = FindTarget(client, sArgs[0], true, false);
		if(iTarget < 1) {
			return Plugin_Handled; // FindTarget already explained why
		}
		if(!GetClientAuthId(iTarget, AuthId_Steam2, sAuth, sizeof(sAuth))) {
			ReplyToCommand(client, "[%s] Could not read that player's SteamID.", g_sChatPrefix);
			return Plugin_Handled;
		}
		GetClientName(iTarget, sName, sizeof(sName));
	}

	MixRunStatReset(client, sAuth, sName, bEveryone, sColumns, sWhat);
	return Plugin_Handled;
}

public Action Command_MixResetMine(int client, int args) {
	if(client == 0) {
		ReplyToCommand(client, "[%s] This command must be used in-game.", g_sChatPrefix);
		return Plugin_Handled;
	}
	if(!cv_AllowSelfReset.BoolValue) {
		MixPrintToChat(client, "Resetting your own stats is disabled on this server.");
		return Plugin_Handled;
	}
	if(!MixResetAllowedNow(client)) {
		return Plugin_Handled;
	}

	char sArgs[3][80];
	int iCount = MixSplitRawArgs(sArgs, sizeof(sArgs), sizeof(sArgs[]));

	// A bare !resetmystats lists the options rather than defaulting to "all".
	// Defaulting would send the least-informed input straight to the most
	// destructive path with only one confirmation between it and a wipe.
	char sColumns[256], sWhat[48];
	if(iCount < 1 || !MixResetColumns(sArgs[0], sColumns, sizeof(sColumns), sWhat, sizeof(sWhat), true)) {
		if(iCount >= 1) {
			MixPrintToChat(client, "\x02%s\x08 is not something you can reset.", sArgs[0]);
		}
		MixPrintToChat(client, "Usage: \x0F!resetmystats <stat>\x08 - what you can clear:");
		MixPrintToChat(client, "  \x0Fsurvival\x08 - your survival time and T-round count");
		MixPrintToChat(client, "  \x0Fstabs\x08 - both stabs given and stabs taken");
		MixPrintToChat(client, "  \x0Fgiven\x08 / \x0Ftaken\x08 - just one side of the stab count");
		MixPrintToChat(client, "  \x0Fall\x08 - every stat listed above");
		MixPrintToChat(client, "Elo, wins/losses, fall damage and clutches are not yours to clear.");
		return Plugin_Handled;
	}

	char sCat[24];
	strcopy(sCat, sizeof(sCat), sArgs[0]);

	// Re-issuing confirms, matching how sm_mixreset all already works rather
	// than inventing a second confirmation style.
	if(g_faSelfResetConfirmAt[client] < GetEngineTime()) {
		g_faSelfResetConfirmAt[client] = GetEngineTime() + MIX_RESET_CONFIRM_WINDOW;
		MixPrintToChat(client, "This clears your \x0F%s\x08 permanently. Run \x0F!resetmystats %s\x08 again within %d seconds to confirm.",
			sWhat, sCat, RoundToNearest(MIX_RESET_CONFIRM_WINDOW));
		return Plugin_Handled;
	}
	g_faSelfResetConfirmAt[client] = 0.0;

	char sAuth[64], sName[MAX_NAME_LENGTH];
	if(!GetClientAuthId(client, AuthId_Steam2, sAuth, sizeof(sAuth))) {
		MixPrintToChat(client, "Could not read your SteamID.");
		return Plugin_Handled;
	}
	GetClientName(client, sName, sizeof(sName));

	MixRunStatReset(client, sAuth, sName, false, sColumns, sWhat);
	return Plugin_Handled;
}

public Action Command_MixResetStats(int client, int args) {
	if(g_hStatsDb == null) {
		ReplyToCommand(client, "[%s] The stats database is not connected.", g_sChatPrefix);
		return Plugin_Handled;
	}

	// Mid-mix, a reset zeroes the very accumulators the results embed is about
	// to read and hands everyone an elo delta computed from wiped ratings.
	if(IsMixActive()) {
		ReplyToCommand(client, "[%s] A mix is in progress - stop it first (sm_stopmix), or this match's results embed and elo would be wrong.", g_sChatPrefix);
		return Plugin_Handled;
	}

	char sArg[24];
	if(args >= 1) {
		GetCmdArg(1, sArg, sizeof(sArg));
	}
	for(int i = 0; sArg[i] != '\0'; i++) {
		sArg[i] = CharToLower(sArg[i]);
	}

	char sQuery[256];
	char sWhat[32];

	if(StrEqual(sArg, "all")) {
		// Re-issuing the same command is the confirmation. The old build wanted
		// a literal 'confirm' as a second argument, which is not what the
		// warning led anyone to type.
		if(g_faResetConfirmAt[client] < GetEngineTime()) {
			g_faResetConfirmAt[client] = GetEngineTime() + MIX_RESET_CONFIRM_WINDOW;
			ReplyToCommand(client, "[%s] This wipes the ENTIRE leaderboard. Run \"sm_mixreset all\" again within %d seconds to confirm.",
				g_sChatPrefix, RoundToNearest(MIX_RESET_CONFIRM_WINDOW));
			return Plugin_Handled;
		}
		g_faResetConfirmAt[client] = 0.0;

		FormatEx(sQuery, sizeof(sQuery), "DELETE FROM `%s_stats`", g_sSqlPrefix);
		strcopy(sWhat, sizeof(sWhat), "ALL stats");
		for(int i = 1; i <= MaxClients; i++) {
			fTimeSurvived[i] = 0.0;
			g_iaMixStabsGiven[i] = 0;
			g_iaMixStabsTaken[i] = 0;
			g_iaMixFallDamage[i] = 0;
			g_iaMixClutches[i] = 0;
			g_iaMixTRounds[i] = 0;
			g_faInhSurvival[i] = 0.0;
			g_iaInhStabsGiven[i] = 0;
			g_iaInhStabsTaken[i] = 0;
			g_iaInhFallDamage[i] = 0;
			g_iaInhClutches[i] = 0;
			g_iaInhTRounds[i] = 0;
			g_iaElo[i] = MIX_DEFAULT_ELO; // cached ratings reset with the table
		}
	}
	else if(StrEqual(sArg, "elo")) {
		FormatEx(sQuery, sizeof(sQuery), "UPDATE `%s_stats` SET elo = 1000", g_sSqlPrefix);
		strcopy(sWhat, sizeof(sWhat), "elo (back to 1000)");
		for(int i = 1; i <= MaxClients; i++) {
			g_iaElo[i] = MIX_DEFAULT_ELO; // keep the caches in step
		}
	}
	else if(StrEqual(sArg, "winloss")) {
		FormatEx(sQuery, sizeof(sQuery), "UPDATE `%s_stats` SET wins = 0, losses = 0", g_sSqlPrefix);
		strcopy(sWhat, sizeof(sWhat), "wins/losses (total games)");
	}
	else if(StrEqual(sArg, "stabs") || StrEqual(sArg, "stab")) {
		FormatEx(sQuery, sizeof(sQuery), "UPDATE `%s_stats` SET stabs_given = 0, stabs_taken = 0", g_sSqlPrefix);
		strcopy(sWhat, sizeof(sWhat), "stabs (given/taken)");
		for(int i = 1; i <= MaxClients; i++) {
			g_iaMixStabsGiven[i] = 0;
			g_iaMixStabsTaken[i] = 0;
		}
	}
	else if(StrEqual(sArg, "falldmg")) {
		FormatEx(sQuery, sizeof(sQuery), "UPDATE `%s_stats` SET fall_damage = 0", g_sSqlPrefix);
		strcopy(sWhat, sizeof(sWhat), "fall damage");
		for(int i = 1; i <= MaxClients; i++) {
			g_iaMixFallDamage[i] = 0;
		}
	}
	else if(StrEqual(sArg, "clutches")) {
		FormatEx(sQuery, sizeof(sQuery), "UPDATE `%s_stats` SET clutches = 0", g_sSqlPrefix);
		strcopy(sWhat, sizeof(sWhat), "clutches");
		for(int i = 1; i <= MaxClients; i++) {
			g_iaMixClutches[i] = 0;
		}
	}
	else if(StrEqual(sArg, "survivaltime") || StrEqual(sArg, "survival")) {
		// Survival time is meaningless without its round count, so wipe both.
		FormatEx(sQuery, sizeof(sQuery), "UPDATE `%s_stats` SET survival_time = 0, t_rounds = 0", g_sSqlPrefix);
		strcopy(sWhat, sizeof(sWhat), "survival time");
		for(int i = 1; i <= MaxClients; i++) {
			fTimeSurvived[i] = 0.0;
			g_iaMixTRounds[i] = 0;
		}
	}
	else {
		ReplyToCommand(client, "[%s] Usage: sm_mixreset <all|elo|winloss|stabs|falldmg|clutches|survivaltime>  ('all' must be run twice to confirm)", g_sChatPrefix);
		return Plugin_Handled;
	}

	g_hStatsDb.Query(SqlCallback_MixReset, sQuery);
	ReplyToCommand(client, "[%s] Reset %s.", g_sChatPrefix, sWhat);
	LogMessage("[MIX] %L reset mix stats: %s", client, sWhat);
	return Plugin_Handled;
}

// Everything that reads the stats table has to be told it just changed. The old build fired the
// query and stopped, so the standing embeds and every rank prefix kept showing pre-reset numbers
// - which is what it doesn't actually reset anything looked like. The status embed carries no
// stats, so it is left alone.
public void SqlCallback_MixReset(Database db, DBResultSet results, const char[] error, any data) {
	if(results == null) {
		LogError("[MIX] Stats reset failed: %s", error);
		return;
	}

	for(int i = 1; i <= MaxClients; i++) {
		if(!IsClientInGame(i) || IsFakeClient(i)) {
			continue;
		}
		// Clear the prefix first: after a full wipe there is no row left, so
		// LoadClientElo's callback never fires and the old rank would stay up.
		g_iaEloRank[i] = 0;
		RefreshEloTag(i);
		LoadClientElo(i);
	}

	RefreshLiveMixLbEmbeds();
}

// Where the !helpmix list is split into its two print batches.
#define HELPMIX_SPLIT 10

public Action Command_HelpMix(int client, int args) {
	if(client == 0) {
		ReplyToCommand(client, "[%s] This command must be used in-game.", g_sChatPrefix);
		return Plugin_Handled;
	}

	MixPrintToChat(client, "Mix commands - \x0B(Captain)\x08 / \x07(Admin)\x08 marks who can use them:");

	// First batch now, the rest a moment later: 20 lines in one frame risks
	// the engine silently dropping some chat messages.
	PrintHelpMixLines(client, 0, HELPMIX_SPLIT);
	CreateTimer(0.2, Timer_HelpMixRest, GetClientUserId(client), TIMER_FLAG_NO_MAPCHANGE);
	return Plugin_Handled;
}

static const char g_saHelpMixLines[][] = {
	" \x10!mix\x08 - guided mix setup: captains, size, time, picks \x07(Admin)",
	" \x10!votemix\x08 (or just type \x10votemix\x08) - vote to start a mix",
	" \x10!forcemix\x08 - start a mix without the vote \x07(Admin)",
	" \x10!c\x08 / \x10!uc\x08 - volunteer as / step down from captain",
	" \x10!pick <player>\x08 - pick a spectator onto your team \x0B(Captain)",
	" \x10!replace <picked> <spec>\x08 - swap one of your picks \x0B(Captain)",
	" \x10!replaceme\x08 - offer your own spot to a spectator",
	" \x10!startmix\x08 - start the match once teams are ready \x0B(Captain)\x08/\x07(Admin)",
	" \x10!stopmix\x08 - cancel the setup or stop the live mix \x0B(Captain)\x08/\x07(Admin)",
	" \x10!mixmenu\x08 (\x10!mm\x08) - the mix panel \x0B(Captain)\x08/\x07(Admin)",
	" \x10!pause\x08 / \x10!unpause\x08 - freeze / resume the live match \x0B(Captain)\x08/\x07(Admin)",
	" \x10!surrender\x08 (\x10!ff\x08) - start a team surrender vote",
	" \x10!add\x08 / \x10!canceladd\x08 - grow the live mix by one player per team \x0B(Captain)\x08/\x07(Admin)",
	" \x10!forceadd\x08 - add one player to a chosen team, even if uneven \x07(Admin)",
	" \x10!mixtopdiscord <category|all>\x08 - post a leaderboard to Discord; it then auto-updates \x07(Admin)",
	" \x10!mixstatus [new]\x08 - force the Discord server-status embed to refresh \x07(Admin)",
	" \x10!extend\x08 - add time to a disconnect wait \x0B(Captain)\x08/\x07(Admin)",
	" \x10!dcmenu\x08 - reopen the disconnect/replace menu \x0B(Captain)\x08/\x07(Admin)",
	" \x10!nomix\x08 / \x10!yesmix\x08 (\x10!noplay\x08 toggles) - opt out of / back into being picked",
	" \x10!mixtop\x08 (\x10!lb\x08) - leaderboards, page with \x10!next\x08/\x10!back\x08",
	" \x10!rank [player]\x08 - view a player's rank profile",
	" \x10!mixreset <category|all>\x08 - reset the whole leaderboard, elo included \x07(Admin)",
	" \x10!mixresetplayer <player|all> [stat]\x08 - reset one player's stats, never elo \x07(Admin)",
	" \x10!resetmystats [stat]\x08 - clear your own survival time / stabs, if enabled",
	" \x10!helpmix\x08 (\x10!cmds\x08, \x10!hnsmix\x08) - this command list"
};

void PrintHelpMixLines(int client, int iStart, int iEnd) {
	if(iEnd > sizeof(g_saHelpMixLines)) {
		iEnd = sizeof(g_saHelpMixLines);
	}
	for(int i = iStart; i < iEnd; i++) {
		PrintToChat(client, "%s", g_saHelpMixLines[i]);
	}
}

public Action Timer_HelpMixRest(Handle timer, any userid) {
	int client = GetClientOfUserId(userid);
	if(client >= 1 && IsClientInGame(client)) {
		PrintHelpMixLines(client, HELPMIX_SPLIT, sizeof(g_saHelpMixLines));
	}
	return Plugin_Stop;
}

// Single-client sibling of ScoreboardPrintAll: translated phrase, {color}
// tags resolved, optional [MIX] prefix.
void ScoreboardPrintOne(int client, bool bPrefix, const char[] format, any ...) {
	char sMsg[256];
	SetGlobalTransTarget(client);
	VFormat(sMsg, sizeof(sMsg), format, 4);
	FormatMixChatColors(sMsg, sizeof(sMsg));
	EmitMixChat(client, bPrefix, sMsg);
}

// The end-of-mix chat scoreboard. All texts and colors come from
// translations/hnsmix.phrases.txt - see write_default_mix_phrases().
void PrintMixScoreboard() {
	PrintToChatAll(" ");
	PrintTeamScoreboard(__TEAM_T, 1);
	PrintToChatAll(" ");
	PrintTeamScoreboard(__TEAM_CT, 2);
}

// The teams' color tags are phrases too, so the file controls them.
void GetMixTeamColorTag(int iTeamNumber, char[] sBuffer, int iMaxLen) {
	FormatEx(sBuffer, iMaxLen, "%T", (iTeamNumber == 1) ? "Mix Team1 Color" : "Mix Team2 Color", LANG_SERVER);
}

void PrintTeamScoreboard(int teamIndex, int iTeamNumber) {
	if(g_alPlayers[teamIndex] == null || g_alPlayers[teamIndex].Length == 0) {
		return;
	}

	char sColorTag[16];
	GetMixTeamColorTag(iTeamNumber, sColorTag, sizeof(sColorTag));

	int iCaptain = (teamIndex == __TEAM_CT) ? g_iCTCaptain : g_iTCaptain;
	bool bCaptainValid = (iCaptain >= 1 && IsClientInGame(iCaptain) && !IsFakeClient(iCaptain));

	// Seated players, pre-mix team elo, and totals for contribution shares.
	int iaClients[MAXPLAYERS + 1];
	int n = 0;
	int iTeamElo = 0;
	float fTotalSurv = 0.0;
	int iTotalStabs = 0;
	int iTotalClutches = 0;

	Player_t player;
	for(int i = 0; i < g_alPlayers[teamIndex].Length; i++) {
		g_alPlayers[teamIndex].GetArray(i, player, sizeof(Player_t));
		int c = player.clientIdx;
		if(c >= 1 && IsClientInGame(c) && !IsFakeClient(c)) {
			iTeamElo += g_iaElo[c];
			fTotalSurv += fTimeSurvived[c];
			iTotalStabs += g_iaMixStabsGiven[c];
			iTotalClutches += g_iaMixClutches[c];
			iaClients[n++] = c;
		}
	}

	// Casual mixes carry no elo - the headers/rows leave it out entirely.
	bool bCasual = IsCasualMix();

	if(bCaptainValid) {
		char sCapName[MAX_NAME_LENGTH];
		GetClientName(iCaptain, sCapName, sizeof(sCapName));
		TruncateMixName(sCapName);
		// Color tag twice: phrases can't reuse a format parameter.
		if(bCasual) {
			ScoreboardPrintAll(true, "%t", "Mix Team Header Casual", sColorTag, iTeamNumber, sColorTag, sCapName);
		}
		else {
			ScoreboardPrintAll(true, "%t", "Mix Team Header", sColorTag, iTeamNumber, iTeamElo, sColorTag, sCapName);
		}
	}
	else {
		if(bCasual) {
			ScoreboardPrintAll(true, "%t", "Mix Team Header No Captain Casual", sColorTag, iTeamNumber);
		}
		else {
			ScoreboardPrintAll(true, "%t", "Mix Team Header No Captain", sColorTag, iTeamNumber, iTeamElo, sColorTag);
		}
	}

	// Rows sorted by contribution (70% stabs / 25% survival / 5% clutches).
	float faScore[MAXPLAYERS + 1];
	for(int i = 0; i < n; i++) {
		int c = iaClients[i];
		float fShareT = (fTotalSurv > 0.0) ? fTimeSurvived[c] / fTotalSurv : 0.0;
		float fShareS = (iTotalStabs > 0) ? float(g_iaMixStabsGiven[c]) / float(iTotalStabs) : 0.0;
		float fShareC = (iTotalClutches > 0) ? float(g_iaMixClutches[c]) / float(iTotalClutches) : 0.0;
		faScore[i] = 0.70 * fShareS + 0.25 * fShareT + 0.05 * fShareC;
	}

	for(int i = 1; i < n; i++) {
		int c = iaClients[i];
		float fScore = faScore[i];
		int j = i - 1;
		while(j >= 0 && faScore[j] < fScore) {
			iaClients[j + 1] = iaClients[j];
			faScore[j + 1] = faScore[j];
			j--;
		}
		iaClients[j + 1] = c;
		faScore[j + 1] = fScore;
	}

	for(int i = 0; i < n; i++) {
		PrintPlayerStatRow(iaClients[i], sColorTag, i + 1);
	}
}

void PrintPlayerStatRow(int client, const char[] sColorTag, int iRank) {
	int iSurvival = RoundToFloor(fTimeSurvived[client]);

	char sRowName[MAX_NAME_LENGTH];
	GetClientName(client, sRowName, sizeof(sRowName));
	TruncateMixName(sRowName);

	// Casual rows show no elo (none is at stake).
	if(IsCasualMix()) {
		ScoreboardPrintAll(false, "%t", "Mix Player Row Casual",
			sColorTag, iRank, sColorTag, sRowName,
			iSurvival,
			g_iaMixStabsGiven[client],
			g_iaMixFallDamage[client],
			g_iaMixClutches[client]);
		return;
	}

	ScoreboardPrintAll(false, "%t", "Mix Player Row",
		sColorTag, iRank, sColorTag, sRowName,
		g_iaElo[client],
		iSurvival,
		g_iaMixStabsGiven[client],
		g_iaMixFallDamage[client],
		g_iaMixClutches[client]);
}

// Prints a scoreboard phrase to everyone, translated per player, with the
// {color} tags resolved to chat color bytes afterwards. bPrefix adds the
// usual [MIX] chat prefix (headers/announcements); rows go without it.
void ScoreboardPrintAll(bool bPrefix, const char[] format, any ...) {
	char sMsg[256];
	for(int i = 1; i <= MaxClients; i++) {
		if(!IsClientInGame(i) || IsFakeClient(i)) {
			continue;
		}
		SetGlobalTransTarget(i);
		VFormat(sMsg, sizeof(sMsg), format, 3);
		FormatMixChatColors(sMsg, sizeof(sMsg));
		EmitMixChat(i, bPrefix, sMsg);
	}
}

// Color tags used by hnsmix.phrases.txt -> CS:GO chat color bytes.
void FormatMixChatColors(char[] sMsg, int iMaxLen) {
	ReplaceString(sMsg, iMaxLen, "{default}", "\x01", false);
	ReplaceString(sMsg, iMaxLen, "{white}", "\x01", false);
	ReplaceString(sMsg, iMaxLen, "{darkred}", "\x02", false);
	ReplaceString(sMsg, iMaxLen, "{green}", "\x04", false);
	ReplaceString(sMsg, iMaxLen, "{lightgreen}", "\x06", false);
	ReplaceString(sMsg, iMaxLen, "{red}", "\x07", false);
	ReplaceString(sMsg, iMaxLen, "{grey}", "\x08", false);
	ReplaceString(sMsg, iMaxLen, "{gray}", "\x08", false);
	ReplaceString(sMsg, iMaxLen, "{yellow}", "\x09", false);
	ReplaceString(sMsg, iMaxLen, "{gold}", "\x09", false);
	ReplaceString(sMsg, iMaxLen, "{blue}", "\x0B", false);
	ReplaceString(sMsg, iMaxLen, "{darkblue}", "\x0C", false);
	ReplaceString(sMsg, iMaxLen, "{purple}", "\x0E", false);
	ReplaceString(sMsg, iMaxLen, "{orange}", "\x10", false);
}

// Ships the default scoreboard phrases: written on first load if the
// translations file doesn't exist yet, then loaded normally. Edit the file
// on the server (translations/hnsmix.phrases.txt) to restyle the scoreboard.
void write_default_mix_phrases() {
	char sPath[PLATFORM_MAX_PATH];
	BuildPath(Path_SM, sPath, sizeof(sPath), "translations/hnsmix.phrases.txt");
	// A file without the current version marker predates phrases this build needs and would cause
	// missing-phrase errors or silently dropped columns. Upgrading rewrites the WHOLE file, so
	// server-side wording edits are lost once per upgrade and must be re-applied.
	if(FileExists(sPath) && MixPhrasesFileCurrent(sPath)) {
		return;
	}

	File hFile = OpenFile(sPath, "w");
	if(hFile == null) {
		LogError("[MIX] Could not create default translations at %s", sPath);
		return;
	}

	hFile.WriteLine("// hnsmix phrases version: 15 - keep this line! Files without the current");
	hFile.WriteLine("// version marker are rewritten with fresh defaults at plugin load.");
	hFile.WriteLine("// End-of-mix scoreboard texts. Color tags: {default} {grey} {red} {blue}");
	hFile.WriteLine("// {green} {gold}/{yellow} {orange} {darkred} {lightgreen} {darkblue} {purple} {default}");
	hFile.WriteLine("// Team colors are phrases too (Mix Team1/Team2 Color).");
	hFile.WriteLine("\"Phrases\"");
	hFile.WriteLine("{");
	hFile.WriteLine("	// Version probe - the plugin checks this phrase to detect a stale");
	hFile.WriteLine("	// translation cache. Renamed on every phrase-format change.");
	hFile.WriteLine("	\"Mix Phrases V15\"");
	hFile.WriteLine("	{");
	hFile.WriteLine("		\"en\"			\"15\"");
	hFile.WriteLine("	}");
	hFile.WriteLine("	\"Mix Team1 Color\"");
	hFile.WriteLine("	{");
	hFile.WriteLine("		\"en\"			\"{red}\"");
	hFile.WriteLine("	}");
	hFile.WriteLine("	\"Mix Team2 Color\"");
	hFile.WriteLine("	{");
	hFile.WriteLine("		\"en\"			\"{blue}\"");
	hFile.WriteLine("	}");
	hFile.WriteLine("	\"Mix Win\"");
	hFile.WriteLine("	{");
	hFile.WriteLine("		\"#format\"		\"{1:s},{2:d},{3:d},{4:d}\"");
	hFile.WriteLine("		\"en\"			\"The game has ended & {1}Team #{2}{grey} has won the {3}v{4}!\"");
	hFile.WriteLine("	}");
	hFile.WriteLine("	\"Mix Win Forfeit\"");
	hFile.WriteLine("	{");
	hFile.WriteLine("		\"#format\"		\"{1:s},{2:d},{3:d},{4:d}\"");
	hFile.WriteLine("		\"en\"			\"The game has ended & {1}Team #{2}{grey} has won the {3}v{4} by forfeit!\"");
	hFile.WriteLine("	}");
	hFile.WriteLine("	// The team color tag is passed TWICE ({1} and {4}) - SourceMod");
	hFile.WriteLine("	// phrases can't reuse a format parameter within one phrase.");
	hFile.WriteLine("	\"Mix Team Header\"");
	hFile.WriteLine("	{");
	hFile.WriteLine("		\"#format\"		\"{1:s},{2:d},{3:d},{4:s},{5:s}\"");
	hFile.WriteLine("		\"en\"			\"{1}Team #{2} {default}| {orange}{3} elo {default}- {4}Captain {5}:\"");
	hFile.WriteLine("	}");
	hFile.WriteLine("	\"Mix Team Header No Captain\"");
	hFile.WriteLine("	{");
	hFile.WriteLine("		\"#format\"		\"{1:s},{2:d},{3:d},{4:s}\"");
	hFile.WriteLine("		\"en\"			\"{1}Team #{2} {default}| {orange}{3} elo{4}:\"");
	hFile.WriteLine("	}");
	hFile.WriteLine("	\"Mix Player Row\"");
	hFile.WriteLine("	{");
	hFile.WriteLine("		\"#format\"		\"{1:s},{2:d},{3:s},{4:s},{5:d},{6:d},{7:d},{8:d},{9:d}\"");
	hFile.WriteLine("		\"en\"			\"- {1}#{2} {default}| {3}{4} {default}- {orange}{5} {default}| {green}{6}s {default}- {orange}{7} stabs {default}- {red}{8} fall dmg {default}- {purple}{9} clutches\"");
	hFile.WriteLine("	}");
	hFile.WriteLine("	// Casual variants: no elo shown (none is at stake).");
	hFile.WriteLine("	\"Mix Team Header Casual\"");
	hFile.WriteLine("	{");
	hFile.WriteLine("		\"#format\"		\"{1:s},{2:d},{3:s},{4:s}\"");
	hFile.WriteLine("		\"en\"			\"{1}Team #{2} {default}- {3}Captain {4}:\"");
	hFile.WriteLine("	}");
	hFile.WriteLine("	\"Mix Team Header No Captain Casual\"");
	hFile.WriteLine("	{");
	hFile.WriteLine("		\"#format\"		\"{1:s},{2:d}\"");
	hFile.WriteLine("		\"en\"			\"{1}Team #{2}{default}:\"");
	hFile.WriteLine("	}");
	hFile.WriteLine("	\"Mix Player Row Casual\"");
	hFile.WriteLine("	{");
	hFile.WriteLine("		\"#format\"		\"{1:s},{2:d},{3:s},{4:s},{5:d},{6:d},{7:d},{8:d}\"");
	hFile.WriteLine("		\"en\"			\"- {1}#{2} {default}| {3}{4} {default}| {green}{5}s {default}- {orange}{6} stabs {default}- {red}{7} fall dmg {default}- {purple}{8} clutches\"");
	hFile.WriteLine("	}");
	hFile.WriteLine("	\"Mix LB Header\"");
	hFile.WriteLine("	{");
	hFile.WriteLine("		\"#format\"		\"{1:s}\"");
	hFile.WriteLine("		\"en\"			\"{red}Leaderboard {default}- {orange}{1}\"");
	hFile.WriteLine("	}");
	hFile.WriteLine("	\"Mix LB Empty\"");
	hFile.WriteLine("	{");
	hFile.WriteLine("		\"en\"			\"{grey}No entries yet.\"");
	hFile.WriteLine("	}");
	hFile.WriteLine("	\"Mix LB Row Elo\"");
	hFile.WriteLine("	{");
	hFile.WriteLine("		\"#format\"		\"{1:d},{2:s},{3:d},{4:d},{5:d},{6:d}\"");
	hFile.WriteLine("		\"en\"			\"{orange}#{1} {default}| {green}{2} {default}- {blue}Elo: {orange}{3} {default}| {blue}Games: {orange}{4} {default}| {blue}Won: {orange}{5} {default}| {blue}Stabs: {orange}{6}\"");
	hFile.WriteLine("	}");
	hFile.WriteLine("	\"Mix LB Row WL\"");
	hFile.WriteLine("	{");
	hFile.WriteLine("		\"#format\"		\"{1:d},{2:s},{3:d},{4:d},{5:d},{6:s}\"");
	hFile.WriteLine("		\"en\"			\"{orange}#{1} {default}| {green}{2} {default}- {blue}{3} games {default}- {green}{4}W{default}/{red}{5}L {default}- {orange}{6}\"");
	hFile.WriteLine("	}");
	hFile.WriteLine("	\"Mix LB Row Survival\"");
	hFile.WriteLine("	{");
	hFile.WriteLine("		\"#format\"		\"{1:d},{2:s},{3:s},{4:s}\"");
	hFile.WriteLine("		\"en\"			\"{orange}#{1} {default}| {green}{2} {default}- {blue}Total S/T: {orange}{3} {default}- {blue}Average S/T: {orange}{4}\"");
	hFile.WriteLine("	}");
	hFile.WriteLine("	\"Mix LB Row Stabs\"");
	hFile.WriteLine("	{");
	hFile.WriteLine("		\"#format\"		\"{1:d},{2:s},{3:d},{4:d}\"");
	hFile.WriteLine("		\"en\"			\"{orange}#{1} {default}| {green}{2} {default}- {orange}{3} given {default}/ {red}{4} taken\"");
	hFile.WriteLine("	}");
	hFile.WriteLine("	\"Mix LB Row FallDmg\"");
	hFile.WriteLine("	{");
	hFile.WriteLine("		\"#format\"		\"{1:d},{2:s},{3:d}\"");
	hFile.WriteLine("		\"en\"			\"{orange}#{1} {default}| {green}{2} {default}- {red}{3} fall dmg\"");
	hFile.WriteLine("	}");
	hFile.WriteLine("	\"Mix LB Row Clutches\"");
	hFile.WriteLine("	{");
	hFile.WriteLine("		\"#format\"		\"{1:d},{2:s},{3:d}\"");
	hFile.WriteLine("		\"en\"			\"{orange}#{1} {default}| {green}{2} {default}- {purple}{3} clutches\"");
	hFile.WriteLine("	}");
	hFile.WriteLine("	\"Mix Rank Header\"");
	hFile.WriteLine("	{");
	hFile.WriteLine("		\"#format\"		\"{1:s}\"");
	hFile.WriteLine("		\"en\"			\"{default}Rank Profile for {green}{1}\"");
	hFile.WriteLine("	}");
	hFile.WriteLine("	\"Mix Rank Line1\"");
	hFile.WriteLine("	{");
	hFile.WriteLine("		\"#format\"		\"{1:s},{2:d}\"");
	hFile.WriteLine("		\"en\"			\"{red}Rank: {orange}{1} {default}- {red}Elo: {orange}{2}\"");
	hFile.WriteLine("	}");
	hFile.WriteLine("	\"Mix Rank Line2\"");
	hFile.WriteLine("	{");
	hFile.WriteLine("		\"#format\"		\"{1:d},{2:d},{3:d}\"");
	hFile.WriteLine("		\"en\"			\"{blue}Games: {orange}{1} {default}- {blue}Wins: {orange}{2} {default}- {blue}Losses: {orange}{3}\"");
	hFile.WriteLine("	}");
	hFile.WriteLine("	\"Mix Rank Line3\"");
	hFile.WriteLine("	{");
	hFile.WriteLine("		\"#format\"		\"{1:s},{2:d},{3:d}\"");
	hFile.WriteLine("		\"en\"			\"{blue}S/T: {orange}{1} {default}- {blue}Stabs Given: {orange}{2} {default}- {blue}Stabs Taken: {orange}{3}\"");
	hFile.WriteLine("	}");
	hFile.WriteLine("	\"Mix Rank Line4\"");
	hFile.WriteLine("	{");
	hFile.WriteLine("		\"#format\"		\"{1:d},{2:d}\"");
	hFile.WriteLine("		\"en\"			\"{blue}FallDMG: {orange}{1} {default}- {blue}Clutches: {orange}{2}\"");
	hFile.WriteLine("	}");
	hFile.WriteLine("}");
	delete hFile;

	LogMessage("[MIX] Wrote default scoreboard translations to %s.", sPath);
}

// True when the existing translations file carries the current version
// marker, i.e. it was written by this plugin version and has every phrase
// this build uses.
bool MixPhrasesFileCurrent(const char[] sPath) {
	File hFile = OpenFile(sPath, "r");
	if(hFile == null) {
		return false;
	}

	char sLine[512];
	while(hFile.ReadLine(sLine, sizeof(sLine))) {
		if(StrContains(sLine, "hnsmix phrases version: 15") != -1) {
			delete hFile;
			return true;
		}
	}
	delete hFile;
	return false;
}

void SuspendWinConditions() {
	if(g_bWinCondsSuspended) {
		return;
	}
	ConVar cv = FindConVar("mp_ignore_round_win_conditions");
	if(cv != null) {
		cv.SetInt(1);
		g_bWinCondsSuspended = true;
	}
}

void RestoreWinConditions() {
	if(!g_bWinCondsSuspended) {
		return;
	}
	ConVar cv = FindConVar("mp_ignore_round_win_conditions");
	if(cv != null) {
		cv.SetInt(0);
	}
	g_bWinCondsSuspended = false;
}

void CancelDcWait() {
	StopTimer(g_hDcWaitTimer);
	g_iDcWaitSecondsLeft = 0;
	g_iDcWaitTeam = 0;
	g_sDcWaitAuth[0] = '\0';
	g_sDcWaitName[0] = '\0';
	for(int i = 1; i <= MaxClients; i++) {
		g_baDcWaitMenuOpen[i] = false;
	}
}

public Action Timer_DcWaitTick(Handle timer) {
	if(!g_Init) {
		g_hDcWaitTimer = null;
		return Plugin_Stop;
	}

	g_iDcWaitSecondsLeft--;

	if(g_iDcWaitSecondsLeft <= 0) {
		// This timer is ending right here - don't let CancelDcWait /
		// StopTimer double-free it from inside its own callback.
		g_hDcWaitTimer = null;

		// Out of time: the missing player forfeits and the other team wins -
		// unless nobody from that team is left either (both sides gone).
		int iWinner = GetOppositeTeam(g_iDcWaitTeam);
		if(!TeamHasConnectedRosterPlayer(iWinner)) {
			MixPrintToChatAll("Nobody is left to take the win - the MIX is abandoned.");
			CancelDcWait();
			Stop1v1();
			return Plugin_Stop;
		}

		MixPrintToChatAll("\x0F%s\x08 did not return in time and forfeits.", g_sDcWaitName);
		DeclareMixForfeitWin(iWinner, "forfeit");
		return Plugin_Stop;
	}

	// Periodic reminders: every minute, then the final 5-count.
	if(g_iDcWaitSecondsLeft % 60 == 0 || g_iDcWaitSecondsLeft <= 5) {
		MixPrintToChatAll("Waiting for \x0F%s\x08 - \x0F%d:%02d\x08 until they forfeit. (\x0F!extend\x08 adds time)", g_sDcWaitName, g_iDcWaitSecondsLeft / 60, g_iDcWaitSecondsLeft % 60);
	}

	// Live countdown: re-render the wait menu each second for whoever has it
	// open, so the title's timer ticks down in front of them.
	for(int i = 1; i <= MaxClients; i++) {
		if(g_baDcWaitMenuOpen[i] && IsClientInGame(i) && !IsFakeClient(i)) {
			OpenDcWaitMenu(i);
		}
	}
	return Plugin_Continue;
}

bool TeamHasConnectedRosterPlayer(int iRosterTeam) {
	int teamIndex = (iRosterTeam == CS_TEAM_CT) ? __TEAM_CT : __TEAM_T;
	Player_t player;
	for(int i = 0; i < g_alPlayers[teamIndex].Length; i++) {
		g_alPlayers[teamIndex].GetArray(i, player, sizeof(Player_t));
		if(player.clientIdx >= 1 && IsClientInGame(player.clientIdx) && !IsFakeClient(player.clientIdx)) {
			return true;
		}
	}
	return false;
}

void OpenDcWaitMenu(int captain) {
	if(g_hDcWaitTimer == null) {
		return;
	}

	g_baDcWaitMenuOpen[captain] = true;

	Menu menu = new Menu(MenuHandler_DcWait);
	menu.SetTitle("[%s] %s disconnected\nForfeits in %d:%02d unless they return:", g_sChatPrefix, g_sDcWaitName, g_iDcWaitSecondsLeft / 60, g_iDcWaitSecondsLeft % 60);
	menu.AddItem("extend", "Extend the wait (+3 minutes)");
	menu.ExitButton = true;
	menu.Display(captain, MENU_TIME_FOREVER);
}

public int MenuHandler_DcWait(Menu menu, MenuAction action, int param1, int param2) {
	switch(action) {
		case MenuAction_Select: {
			char sInfo[16];
			menu.GetItem(param2, sInfo, sizeof(sInfo));

			if(StrEqual(sInfo, "extend")) {
				ExtendDcWait(param1);
				OpenDcWaitMenu(param1);
			}
		}
		case MenuAction_Cancel: {
			// Only a deliberate exit stops the live refresh - being
			// interrupted by our own per-second re-render does not.
			if(param2 == MenuCancel_Exit) {
				g_baDcWaitMenuOpen[param1] = false;
			}
		}
		case MenuAction_End: {
			delete menu;
		}
	}
	return 0;
}

void ExtendDcWait(int client) {
	if(g_hDcWaitTimer == null) {
		MixPrintToChat(client, "Nobody is being waited on.");
		return;
	}
	g_iDcWaitSecondsLeft += cv_DcForfeitTime.IntValue;
	MixPrintToChatAll("\x0F%N\x08 extended the wait for \x0F%s\x08 - \x0F%d:%02d\x08 left.", client, g_sDcWaitName, g_iDcWaitSecondsLeft / 60, g_iDcWaitSecondsLeft % 60);
}

// !extend: either captain or an admin adds time to the 1v1 disconnect wait.
public Action Command_Extend(int client, int args) {
	if(client < 1 || !IsClientInGame(client)) {
		return Plugin_Handled;
	}

	if(!CanPauseMix(client)) {
		MixPrintToChat(client, "Only captains and admins can extend the wait.");
		return Plugin_Handled;
	}

	ExtendDcWait(client);
	return Plugin_Handled;
}

// !dcmenu: reopen whichever disconnect menu applies - the 1v1 wait menu, or
// the replace menu for the first missing player the caller may decide for.
public Action Command_DcMenu(int client, int args) {
	if(client < 1 || !IsClientInGame(client)) {
		return Plugin_Handled;
	}

	if(!CanPauseMix(client)) {
		MixPrintToChat(client, "Only captains and admins can open this menu.");
		return Plugin_Handled;
	}

	if(!g_Init) {
		MixPrintToChat(client, "There is no live MIX.");
		return Plugin_Handled;
	}

	if(g_hDcWaitTimer != null) {
		OpenDcWaitMenu(client);
		return Plugin_Handled;
	}

	bool bAdmin = HasMixAdminAccess(client);
	DcPlayer_t dc;
	for(int i = 0; i < g_alDcPlayers.Length; i++) {
		g_alDcPlayers.GetArray(i, dc, sizeof(DcPlayer_t));
		if(dc.bReplaced) {
			continue;
		}
		if(bAdmin || IsMixTeamDecider(client, dc.iRosterTeam)) {
			OpenDcReplaceMenu(client, dc.sAuth);
			return Plugin_Handled;
		}
	}

	MixPrintToChat(client, "Nobody is missing from the MIX.");
	return Plugin_Handled;
}


void OpenSpecMenu(int client) {
	Menu menu = new Menu(MenuHandler_Spec);
	menu.SetTitle("Choose a player to move to spectator:");

	menu.AddItem("-1", "Move All Players to Spec");

	char sID[16]; char sName[MAX_NAME_LENGTH];
	for (int i = 1; i <= MaxClients; i++) {
		if (!IsClientInGame(i) || IsClientSourceTV(i) || GetClientTeam(i) < 2) {
			continue;
		}
		
		IntToString(GetClientUserId(i), sID, sizeof(sID));
		GetClientName(i, sName, sizeof(sName));
		menu.AddItem(sID, sName);
	}

	if (menu.ItemCount == 0) {
		menu.AddItem("", " :: No Players Found", ITEMDRAW_DISABLED);
	}
	
	menu.Display(client, MENU_TIME_FOREVER);
}

public int MenuHandler_Spec(Menu menu, MenuAction action, int param1, int param2) {
	switch (action) {
		case MenuAction_Select: {
			if(!HasMixAdminAccess(param1)) {
				MixPrintToChat(param1, "Only admins can move players to spectator.");
				return 0;
			}

			char sID[16]; char sName[MAX_NAME_LENGTH];
			menu.GetItem(param2, sID, sizeof(sID), _, sName, sizeof(sName));
			int userid = StringToInt(sID);

			if(userid == -1) {
				// MoveAllToSpec authorizes each move itself.
				MoveAllToSpec();
				MixPrintToChatAll("\x0F%N\x0A has moved all players to spec.", param1);
				OpenMixMenu(param1);
				return 0;
			}

			int target = GetClientOfUserId(userid);

			if(target < 1) {
				MixPrintToChat(param1, "\x0F%s\x0A is no longer available.", sName);
				OpenSpecMenu(param1);
				return 0;
			}
			g_baAuthorizedSpecMove[target] = true; // deliberate admin action
			ChangeClientTeam(target, CS_TEAM_SPECTATOR);
			OpenSpecMenu(param1);
		}

		case MenuAction_End:
			delete menu;
	}
	return 0;
}

void ToggleTeamLock(int client) {
	g_IsTeamsLocked = !g_IsTeamsLocked;
	MixPrintToChatAll("\x0F%N\x08 has %s team switching.", client, g_IsTeamsLocked ? "locked" : "unlocked");
}

bool IsPlayerInTeam(int client, int team) {

	int teamIndex = (team == CS_TEAM_T) ? __TEAM_T : __TEAM_CT;
	if(g_alPlayers[teamIndex] == null) {
		return false;
	}
	int len = g_alPlayers[teamIndex].Length;

	if(len == 0) {
		return false;
	}

	Player_t player;
	for(int i = 0; i < len; i++) {
		g_alPlayers[teamIndex].GetArray(i, player, sizeof(Player_t));

		if(player.clientIdx == client) {
			return true;
		}
	}
	return false;
}

void OpenPlayerListMenu(int client, int team) {
	char sTeam[32]; strcopy(sTeam, sizeof(sTeam), (team == CS_TEAM_T) ? "Team 1" : "Team 2");

	Menu menu = new Menu(MenuHandler_PlayerList);
	menu.SetTitle("Choose a player for %s:", sTeam);

	int teamIndex = (team == CS_TEAM_T) ? __TEAM_T : __TEAM_CT;

	char sID[16]; char sName[MAX_NAME_LENGTH];

	Player_t player;
	for(int i = 0; i < g_alPlayers[teamIndex].Length; i++) {
		g_alPlayers[teamIndex].GetArray(i, player, sizeof(Player_t));

		if(player.clientIdx == -1) {
			continue;
		}

		IntToString(GetClientUserId(player.clientIdx), sID, sizeof(sID));
		GetClientName(player.clientIdx, sName, sizeof(sName));
		menu.AddItem(team == CS_TEAM_CT ? "choose_ct" : "choose_t", sName, ITEMDRAW_DISABLED);
	}

	while(menu.ItemCount < g_iCurrentPlayerMode) {
		char sItemName[32];
		FormatEx(sItemName, sizeof(sItemName), "<open slot>", (g_iCurrentPlayerMode - menu.ItemCount));
		menu.AddItem(team == CS_TEAM_CT ? "choose_ct" : "choose_t", sItemName);
	}

	if(HasMixAdminAccess(client)) {
		menu.AddItem(team == CS_TEAM_CT ? "clear_team_ct" : "clear_team_t", "Reset Team");
	}

	menu.ExitButton = false;
	menu.ExitBackButton = false;

	menu.Display(client, MENU_TIME_FOREVER);
}

public int MenuHandler_PlayerList(Menu menu, MenuAction action, int client, int option) {
	switch (action) {
		case MenuAction_Select: {
			char sItem[32];
			menu.GetItem(option, sItem, sizeof(sItem));

			if(StrEqual(sItem, "choose_ct")) {
				OpenPlayersMenu(client, CS_TEAM_CT);
				return 0;
			}

			if(StrEqual(sItem, "choose_t")) {
				OpenPlayersMenu(client, CS_TEAM_T);
				return 0;
			}

			// Clear teams
			if(StrEqual(sItem, "clear_team_ct")) {
				g_alPlayers[__TEAM_CT].Clear();
				OpenPlayerListMenu(client, CS_TEAM_CT);
				return 0;
			}

			if(StrEqual(sItem, "clear_team_t")) {
				g_alPlayers[__TEAM_T].Clear();
				OpenPlayerListMenu(client, CS_TEAM_T);
				return 0;
			}
		}
		case MenuAction_End: {
			delete menu;
		}
	}
	return 0;
}

// Live roster panel during picking: every willing non-captain watches the teams fill in, with a
// single Leave Mix option that !noplay's them. A picked leaver frees their spot and that captain
// immediately re-picks.

void CloseMixRosterPanels() {
	for(int i = 1; i <= MaxClients; i++) {
		if(g_baRosterPanelOpen[i]) {
			g_baRosterPanelOpen[i] = false;
			if(IsClientInGame(i) && !IsFakeClient(i)) {
				CancelClientMenu(i);
			}
		}
	}
}

// (Re)draws the panel for everyone eligible and closes it for viewers who stopped being eligible.
// Captains see it while they WAIT - only the captain whose turn it is keeps their pick menu.
void RefreshMixRosterPanels() {
	if(g_gameState != eGameState_PickingPlayers) {
		return;
	}

	// CT captain picks after T's pick and vice versa; at picking start
	// g_iLastPickedTeam is CS_TEAM_T so the CT captain goes first.
	int iCurrentPicker = (g_iLastPickedTeam == CS_TEAM_CT) ? g_iTCaptain : g_iCTCaptain;

	for(int i = 1; i <= MaxClients; i++) {
		if(!IsClientInGame(i) || IsFakeClient(i) || IsClientSourceTV(i)) {
			continue;
		}
		if(!g_bWantsToPlay[i] || i == iCurrentPicker) {
			if(g_baRosterPanelOpen[i]) {
				g_baRosterPanelOpen[i] = false;
				CancelClientMenu(i);
			}
			continue;
		}
		ShowMixRosterPanel(i);
	}
}

// Pool changed mid-pick: repaint roster panels + the current picker's menu.
void RefreshPickingPhaseMenus() {
	if(g_gameState != eGameState_PickingPlayers) {
		return;
	}

	int iPickTeam = GetOppositeTeam(g_iLastPickedTeam);
	int iCaptain = (iPickTeam == CS_TEAM_CT) ? g_iCTCaptain : g_iTCaptain;
	if(iCaptain >= 1 && IsClientInGame(iCaptain) && !IsFakeClient(iCaptain)) {
		OpenPlayersMenu(iCaptain, iPickTeam);
	}
	RefreshMixRosterPanels();
}

// One frame after a mid-pick connect, so the repaint sees the joiner.
void Frame_RefreshPickPhase(any data) {
	RefreshPickingPhaseMenus();
}

// Next picker (never a full team - blind alternation built 5v6s), or finish.
void ContinuePicking() {
	if(g_gameState != eGameState_PickingPlayers) {
		return;
	}

	if(g_alPlayers[__TEAM_CT].Length >= g_iCurrentPlayerMode && g_alPlayers[__TEAM_T].Length >= g_iCurrentPlayerMode) {
		MixPrintToChatAll("Teams have been picked.");
		g_gameState = eGameState_DonePickingPlayers;
		g_iLastPickedTeam = CS_TEAM_CT;
		FinishMixSetup();
		return;
	}

	int iNextTeam = GetOppositeTeam(g_iLastPickedTeam);
	if(g_alPlayers[(iNextTeam == CS_TEAM_T) ? __TEAM_T : __TEAM_CT].Length >= g_iCurrentPlayerMode) {
		// Other team full - same side keeps picking until even.
		iNextTeam = GetOppositeTeam(iNextTeam);
		g_iLastPickedTeam = GetOppositeTeam(iNextTeam);
	}

	RefreshMixRosterPanels(); // spectators watch the rosters fill in live

	int iCaptain = (iNextTeam == CS_TEAM_CT) ? g_iCTCaptain : g_iTCaptain;
	if(iCaptain >= 1 && IsClientInGame(iCaptain) && !IsFakeClient(iCaptain)) {
		OpenPlayersMenu(iCaptain, iNextTeam);
	}
	else {
		MixPrintToChatAll("The %s captain slot is vacant - type \x0F!c\x08 to fill it and continue picking!", iNextTeam == CS_TEAM_CT ? MIX_TEAM2_CHAT : MIX_TEAM1_CHAT);
	}
}

void DrawRosterTeamLines(Panel panel, int teamIndex, int iTeamNumber) {
	char sBuf[96];
	FormatEx(sBuf, sizeof(sBuf), "Team %d (%d/%d):", iTeamNumber, g_alPlayers[teamIndex].Length, g_iCurrentPlayerMode);
	panel.DrawText(sBuf);

	char sName[MAX_NAME_LENGTH];
	Player_t player;
	for(int i = 0; i < g_alPlayers[teamIndex].Length; i++) {
		g_alPlayers[teamIndex].GetArray(i, player, sizeof(Player_t));
		int c = player.clientIdx;
		if(c < 1 || !IsClientInGame(c)) {
			continue;
		}
		GetClientName(c, sName, sizeof(sName));
		TruncateMixName(sName);
		FormatEx(sBuf, sizeof(sBuf), " » %s%s", sName, IsClientCaptain(c) ? " (C)" : "");
		panel.DrawText(sBuf);
	}
}

void ShowMixRosterPanel(int client) {
	char sBuf[96];
	FormatEx(sBuf, sizeof(sBuf), "MIX Picking Phase - %dv%d", g_iCurrentPlayerMode, g_iCurrentPlayerMode);

	Panel panel = new Panel();
	panel.SetTitle(sBuf);
	panel.DrawText(" ");
	DrawRosterTeamLines(panel, __TEAM_T, 1);
	panel.DrawText(" ");
	DrawRosterTeamLines(panel, __TEAM_CT, 2);
	panel.DrawText(" ");
	panel.DrawText("____________________");
	if(IsClientCaptain(client)) {
		panel.DrawText((g_iTCaptain == client) ? "You are the Team 1 captain" : "You are the Team 2 captain");
	}
	else if(IsPlayerInTeam(client, CS_TEAM_T)) {
		panel.DrawText("You are on Team 1");
	}
	else if(IsPlayerInTeam(client, CS_TEAM_CT)) {
		panel.DrawText("You are on Team 2");
	}
	else {
		panel.DrawText("Waiting to be picked...");
	}
	panel.DrawText(" ");
	// Captains can't opt out mid-pick - they just get a close button.
	panel.DrawItem(IsClientCaptain(client) ? "Close" : "Leave Mix");
	panel.Send(client, PanelHandler_MixRoster, MENU_TIME_FOREVER);
	delete panel;

	g_baRosterPanelOpen[client] = true;
}

public int PanelHandler_MixRoster(Menu menu, MenuAction action, int param1, int param2) {
	if(action == MenuAction_Select) {
		g_baRosterPanelOpen[param1] = false;
		if(param2 == 1 && !IsClientCaptain(param1)) {
			MixRosterLeave(param1);
		}
	}
	else if(action == MenuAction_Cancel) {
		g_baRosterPanelOpen[param1] = false;
	}
	return 0;
}

// Leave Mix pressed: the player goes !noplay. A picked leaver also frees
// their team spot, and that team's captain gets the pick menu right away to
// choose a replacement.
void MixRosterLeave(int client) {
	if(g_gameState != eGameState_PickingPlayers || IsClientCaptain(client)) {
		return; // picking ended while their panel was still up (or a captain)
	}

	g_bWantsToPlay[client] = false;
	SetClientCookie(client, g_hNoMixCookie, "1");

	int iRosterTeam = 0;
	if(IsPlayerInTeam(client, CS_TEAM_T)) {
		iRosterTeam = CS_TEAM_T;
	}
	else if(IsPlayerInTeam(client, CS_TEAM_CT)) {
		iRosterTeam = CS_TEAM_CT;
	}

	if(iRosterTeam != 0) {
		FindAndRemovePlayer(client, iRosterTeam);
		g_baAuthorizedSpecMove[client] = true;
		ChangeClientTeam(client, CS_TEAM_SPECTATOR);
		MixPrintToChatAll("\x0F%N\x08 left the MIX and the %s team! (\x0F!nomix\x08) The captain must pick a replacement.", client, iRosterTeam == CS_TEAM_CT ? MIX_TEAM2_CHAT : MIX_TEAM1_CHAT);

		// That team is short now - its captain re-picks immediately. The turn
		// marker moves with it, so the roster-panel refresh below treats them
		// as the current picker and never overwrites their fresh pick menu.
		int iCaptain = (iRosterTeam == CS_TEAM_CT) ? g_iCTCaptain : g_iTCaptain;
		if(iCaptain >= 1 && IsClientInGame(iCaptain) && !IsFakeClient(iCaptain)) {
			g_iLastPickedTeam = GetOppositeTeam(iRosterTeam);
			OpenPlayersMenu(iCaptain, iRosterTeam);
		}
	}
	else {
		MixPrintToChatAll("\x0F%N\x08 left the MIX pool. (\x0F!nomix\x08)", client);
	}

	MixPrintToChat(client, "You opted out - type \x0F!yesmix\x08 to be pickable again.");
	RefreshMixRosterPanels();
}

void OpenPlayersMenu(int client, int team) {
	char sTeam[32]; strcopy(sTeam, sizeof(sTeam), (team == CS_TEAM_T) ? "Team 1" : "Team 2");

	Menu menu = new Menu(MenuHandler_Players);
	menu.SetTitle("Choose a player for %s:", sTeam);

	char sID[16]; char sBuffer[256];
	for(int i = 1; i <= MaxClients; i++) {
		if(!IsClientInGame(i) || IsClientSourceTV(i)) {
			continue;
		}

		if(!g_bWantsToPlay[i]) {
			continue;
		}

		// Captains lead the teams; they are not pickable.
		if(IsClientCaptain(i)) {
			continue;
		}

		// Already-picked players stay visible but grayed out so the other captain can't pick them.
		bool bPicked = (IsPlayerInTeam(i, CS_TEAM_CT) || IsPlayerInTeam(i, CS_TEAM_T));

		IntToString(GetClientUserId(i), sID, sizeof(sID));

		FormatEx(sBuffer, sizeof(sBuffer), "%N%s", i, bPicked ? " (picked)" : "");
		menu.AddItem(sID, sBuffer, bPicked ? ITEMDRAW_DISABLED : ITEMDRAW_DEFAULT);
	}

	menu.ExitButton = false;
	menu.ExitBackButton = false;

	if(menu.ItemCount == 0) {
		menu.AddItem("", " :: No Players Found", ITEMDRAW_DISABLED);
		menu.ExitButton = true;
	}
	
	PushMenuInt(menu, "team", team);

	menu.Display(client, MENU_TIME_FOREVER);
}

public int MenuHandler_Players(Menu menu, MenuAction action, int param1, int param2) {
	switch (action) {
		case MenuAction_Select: {
			char sID[16]; char sName[MAX_NAME_LENGTH];
			menu.GetItem(param2, sID, sizeof(sID), _, sName, sizeof(sName));

			int target = GetClientOfUserId(StringToInt(sID));
			int team = GetMenuInt(menu, "team");

			if(target < 1) {
				CPrintToChat(param1, "%s is no longer available.", sName);
				OpenPlayersMenu(param1, team);
				return 0;
			}

			if(IsClientCaptain(target)) {
				MixPrintToChat(param1, "Captains cannot be picked as players.");
				OpenPlayersMenu(param1, team);
				return 0;
			}

			if(IsPlayerInTeam(target, CS_TEAM_CT) || IsPlayerInTeam(target, CS_TEAM_T)) {
				MixPrintToChat(param1, "\x0F%s\x08 has already been picked.", sName);
				OpenPlayersMenu(param1, team);
				return 0;
			}

			// !nomix may have landed after the menu was drawn.
			if(!g_bWantsToPlay[target]) {
				MixPrintToChat(param1, "\x0F%s\x08 opted out with \x0F!nomix\x08.", sName);
				OpenPlayersMenu(param1, team);
				return 0;
			}

			int teamIndex = (team == CS_TEAM_T) ? __TEAM_T : __TEAM_CT;

			// Stale menu must never overfill a team.
			if(g_alPlayers[teamIndex].Length >= g_iCurrentPlayerMode) {
				MixPrintToChat(param1, "Your team is already full.");
				ContinuePicking();
				return 0;
			}

			Player_t player;
			player.clientIdx = target;

			g_alPlayers[teamIndex].PushArray(player, sizeof(Player_t));
			MovePlayerToTeam(target, GetInGameTeamFor(team));
			MixPrintToChatAll("\x0F%N\x08 has been added to the %s team.", target, team == CS_TEAM_CT ? MIX_TEAM2_CHAT : MIX_TEAM1_CHAT);

			g_iLastPickedTeam = team;
			ContinuePicking();
		}
		case MenuAction_End: {
			delete menu;
		}
	}
	return 0;
}

bool PushMenuInt(Menu menu, const char[] id, int value) {
	char sBuffer[128];
	IntToString(value, sBuffer, sizeof(sBuffer));
	return menu.AddItem(id, sBuffer, ITEMDRAW_IGNORE);
}

int GetMenuInt(Menu menu, const char[] id, int defaultvalue = 0) {
	char info[128]; char data[128];
	for (int i = 0; i < menu.ItemCount; i++) {
		if (menu.GetItem(i, info, sizeof(info), _, data, sizeof(data)) && StrEqual(info, id)) {
			return StringToInt(data);
		}
	}
	return defaultvalue;
}

bool StopTimer(Handle& timer) {
	if (timer != null) {
		KillTimer(timer);
		timer = null;
		return true;
	}
	
	return false;
}

void MovePlayerToTeam(int client, int team) {
	if(GetClientTeam(client) == team) {
		return;
	}

	if(IsPlayerAlive(client)) {
		ChangeClientTeam_Alive(client, team);
	}
	else {
		ChangeClientTeam(client, team);
		g_baAuthorizedSpawn[client] = true; // deliberate hnsmix respawn (pick/replace)
		CS_RespawnPlayer(client);
	}
}

void GetMixGrenadeValues(float fMixValues[sizeof(g_szHnsCvarNames)]) {
	fMixValues[0] = cv_DecoyMax.FloatValue;
	fMixValues[1] = cv_DecoyChance.FloatValue;
	fMixValues[2] = cv_FlashChance.FloatValue;
	fMixValues[3] = cv_FlashMax.FloatValue;
	fMixValues[4] = cv_HeChance.FloatValue;
	fMixValues[5] = cv_HeMax.FloatValue;
	fMixValues[6] = cv_MolotovChance.FloatValue;
	fMixValues[7] = cv_MolotovMax.FloatValue;
	fMixValues[8] = cv_SmokeMax.FloatValue;
	fMixValues[9] = cv_SmokeChance.FloatValue;
	fMixValues[10] = 0.0;
	fMixValues[11] = 0.0;

	// Knife rounds are knives only. The special Anti-Frag entries are already
	// zero for every mix; zero the grenade values as well.
	if(g_iKnifeStage != KNIFE_NONE) {
		for(int i = 0; i < sizeof(g_szHnsCvarNames); i++) {
			fMixValues[i] = 0.0;
		}
	}
}

void SetMixGrenadeCvars() {
	if(g_bHnsCvarsOverridden) {
		return;
	}

	float fMixValues[sizeof(g_szHnsCvarNames)];
	GetMixGrenadeValues(fMixValues);

	// Knife rounds always override the nade cvars (to zero), master toggle or not.
	bool bNadeOverride = cv_NadeOverride.BoolValue || g_iKnifeStage != KNIFE_NONE;

	for(int i = 0; i < sizeof(g_szHnsCvarNames); i++) {
		g_bHnsCvarFound[i] = false;

		// Grenade entries respect the master toggle; Anti-Frag is always disabled
		// during an active mix.
		if(i < HNS_NADE_CVAR_COUNT && !bNadeOverride) {
			continue;
		}

		ConVar cvar = FindConVar(g_szHnsCvarNames[i]);
		if(cvar == null) {
			continue;
		}

		g_fHnsCvarPrevValues[i] = cvar.FloatValue;
		cvar.SetFloat(fMixValues[i]);
		g_bHnsCvarFound[i] = true;
	}

	g_bHnsCvarsOverridden = true;
}

// Re-assert the mix values without touching the saved originals. Runs every
// round while a mix is live so the hnsmix settings always beat whatever
// touched the hidenseek convars in the meantime.
void ApplyMixGrenadeCvars() {
	if(!g_bHnsCvarsOverridden) {
		return;
	}

	float fMixValues[sizeof(g_szHnsCvarNames)];
	GetMixGrenadeValues(fMixValues);

	// Knife rounds always override the grenade cvars (to zero), master toggle or not.
	bool bNadeOverride = cv_NadeOverride.BoolValue || g_iKnifeStage != KNIFE_NONE;

	for(int i = 0; i < sizeof(g_szHnsCvarNames); i++) {
		if(i < HNS_NADE_CVAR_COUNT && !bNadeOverride) {
			continue;
		}

		ConVar cvar = FindConVar(g_szHnsCvarNames[i]);
		if(cvar != null && cvar.FloatValue != fMixValues[i]) {
			cvar.SetFloat(fMixValues[i]);
		}
	}
}

void RestoreMixGrenadeCvars() {
	if(!g_bHnsCvarsOverridden) {
		return;
	}

	for(int i = 0; i < sizeof(g_szHnsCvarNames); i++) {
		if(!g_bHnsCvarFound[i]) {
			continue;
		}

		ConVar cvar = FindConVar(g_szHnsCvarNames[i]);
		if(cvar != null) {
			cvar.SetFloat(g_fHnsCvarPrevValues[i]);
		}
		g_bHnsCvarFound[i] = false;
	}
	g_bHnsCvarsOverridden = false;
}

// Anti forced-spectate: a roster player pushed to spectator during a live mix by anything other
// than hnsmix is pulled back onto their team. If they were genuinely dead this round they come
// back DEAD, no free respawns, and rejoin properly next round.
public void EventPlayerTeam_Mix(Event event, const char[] name, bool dontBroadcast) {
	if(!g_Init) {
		return;
	}

	int client = GetClientOfUserId(event.GetInt("userid"));
	if(client < 1 || !IsClientInGame(client) || IsFakeClient(client)) {
		return;
	}

	// A replaced player may not rejoin a team while this mix runs - bounce
	// any non-spectator join straight back.
	if(g_baReplacedSpectator[client] && event.GetInt("team") > CS_TEAM_SPECTATOR) {
		CreateTimer(0.1, Timer_ForceReplacedSpec, GetClientUserId(client), TIMER_FLAG_NO_MAPCHANGE);
		return;
	}

	if(event.GetInt("team") != CS_TEAM_SPECTATOR) {
		return;
	}

	// hnsmix moved them on purpose (admin spec tools, replacement, etc.).
	if(g_baAuthorizedSpecMove[client]) {
		g_baAuthorizedSpecMove[client] = false;
		return;
	}

	// Only roster members are protected.
	if(!IsClientCaptain(client) && !IsPlayerInTeam(client, CS_TEAM_CT) && !IsPlayerInTeam(client, CS_TEAM_T)) {
		return;
	}

	// The team change is still being processed - restore shortly after.
	CreateTimer(0.1, Timer_RestoreMixPlayer, GetClientUserId(client), TIMER_FLAG_NO_MAPCHANGE);
}

public Action Timer_RestoreMixPlayer(Handle timer, any userid) {
	int client = GetClientOfUserId(userid);
	if(client < 1 || !g_Init || !IsClientInGame(client) || GetClientTeam(client) != CS_TEAM_SPECTATOR) {
		return Plugin_Stop;
	}

	int iRosterTeam = 0;
	if(g_iCTCaptain == client || IsPlayerInTeam(client, CS_TEAM_CT)) {
		iRosterTeam = CS_TEAM_CT;
	}
	else if(g_iTCaptain == client || IsPlayerInTeam(client, CS_TEAM_T)) {
		iRosterTeam = CS_TEAM_T;
	}
	else {
		return Plugin_Stop; // no longer on the roster (replaced meanwhile)
	}

	int iInGameTeam = GetInGameTeamFor(iRosterTeam);
	CS_SwitchTeam(client, iInGameTeam);

	// A player who was ALIVE when force-spec'd was killed by the team switch
	// itself (a death within the last half second) - give their life back.
	// A player who genuinely died earlier this round stays dead, as usual.
	if(!IsPlayerAlive(client) && !g_bBetweenRounds && GetGameTime() - g_faLastDeathTime[client] < 0.5) {
		g_baAuthorizedSpawn[client] = true;
		CS_RespawnPlayer(client);
	}

	MixPrintToChat(client, "You are part of the live MIX - you can't be moved to spectator.");
	LogMessage("[MIX] Restored %L to their team after an external spectator move.", client);
	return Plugin_Stop;
}

// Last line of defense against any rogue respawner: during a live mix round, a spawn hnsmix did
// not cause and that is not part of the round transition gets undone. Spectators cannot be
// force-respawned, so this cannot loop.
public void EventPlayerSpawn_Mix(Event event, const char[] name, bool dontBroadcast) {
	if(!g_Init) {
		return;
	}

	int client = GetClientOfUserId(event.GetInt("userid"));
	if(client < 1 || !IsClientInGame(client) || IsFakeClient(client)) {
		return;
	}

	g_iaLastKnownHealth[client] = GetClientHealth(client);

	// hnsmix respawned them on purpose (round transition, replacement,
	// delayed CT respawn) - consume the pass and allow it.
	if(g_baAuthorizedSpawn[client]) {
		g_baAuthorizedSpawn[client] = false;
		g_baDeadThisRound[client] = false;
		return;
	}

	// Round transitions spawn everyone legitimately. The grace window is
	// tight on purpose: the round-restart wave spawns everyone within the
	// first second, and anything later is a rogue respawn.
	if(g_bBetweenRounds || GetGameTime() - g_fRoundStartedAt < 1.5) {
		g_baDeadThisRound[client] = false;
		return;
	}

	// A spawn well after the death is a deliberate act - an admin forcing a respawn - and is allowed
	// to stand. The shield only benches INSTANT respawns: wave timers and mp_respawn_on_death_* are
	// already forced off while a mix runs, so anything instant is rogue.
	if(GetGameTime() - g_faLastDeathTime[client] > 2.0) {
		g_baDeadThisRound[client] = false;
		return;
	}

	g_baAuthorizedSpecMove[client] = true; // anti-respawn enforcement is our own move
	ChangeClientTeam(client, CS_TEAM_SPECTATOR);
	MixPrintToChat(client, "No respawning during a MIX round - you'll be back next round.");
	LogMessage("[MIX] Blocked a rogue mid-round respawn of %L (moved to spectator).", client);
}

public void EventPlayerHurt_Mix(Event event, const char[] name, bool dontBroadcast) {
	int victim = GetClientOfUserId(event.GetInt("userid"));
	if(victim < 1 || victim > MaxClients) {
		return;
	}
	g_iaLastKnownHealth[victim] = event.GetInt("health");

	// Stab tracking: knife damage between two mix players during a live,
	// unpaused mix. (Paused players are god-moded anyway - belt and braces.)
	// Knife rounds are selection rounds - stabs there count nowhere.
	if(!g_Init || g_bMatchPaused || g_iKnifeStage != KNIFE_NONE) {
		return;
	}

	int attacker = GetClientOfUserId(event.GetInt("attacker"));
	if(attacker < 1 || attacker > MaxClients || attacker == victim) {
		return;
	}

	char sWeapon[32];
	event.GetString("weapon", sWeapon, sizeof(sWeapon));
	if(StrContains(sWeapon, "knife", false) == -1) {
		return;
	}

	if((IsPlayerInTeam(attacker, CS_TEAM_CT) || IsPlayerInTeam(attacker, CS_TEAM_T))
	&& (IsPlayerInTeam(victim, CS_TEAM_CT) || IsPlayerInTeam(victim, CS_TEAM_T))) {
		g_iaMixStabsGiven[attacker]++;
		g_iaMixStabsTaken[victim]++;
	}
}

// Fall damage tracking for the mix stats: counted per victim while a mix is
// live. (hns-fall-damage may regenerate the health afterwards - the damage
// was still taken.)
public void OnTakeDamagePost_Mix(int victim, int attacker, int inflictor, float damage, int damagetype) {
	if(!g_Init || g_bMatchPaused || g_iKnifeStage != KNIFE_NONE || !(damagetype & DMG_FALL) || victim < 1 || victim > MaxClients) {
		return;
	}

	if(IsPlayerInTeam(victim, CS_TEAM_CT) || IsPlayerInTeam(victim, CS_TEAM_T)) {
		g_iaMixFallDamage[victim] += RoundToNearest(damage);
	}
}

public Action EventPlayerDeath(Event event, const char[] name, bool dontBroadcast) {
	if(!g_Init) {
		return Plugin_Continue;
	}

	int victim = GetClientOfUserId(event.GetInt("userid"));
	if(victim > 0) {
		g_faLastDeathTime[victim] = GetGameTime();
		if(!g_bBetweenRounds) {
			g_baDeadThisRound[victim] = true;
		}
	}
	CheckLoneTerrorist(victim);

	// Delayed CT respawn: instant respawn (mp_respawn_on_death_ct) is disabled
	// while the mix is live, so dead CTs come back after the configured delay.
	if(victim > 0 && IsClientInGame(victim) && GetClientTeam(victim) == CS_TEAM_CT) {
		float fDelay = cv_CtRespawnDelay.FloatValue;
		if(fDelay > 0.0) {
			MixPrintToChat(victim, "You will respawn in \x0F%d\x08 seconds.", RoundToNearest(fDelay));
			CreateTimer(fDelay, Timer_MixRespawnCT, GetClientUserId(victim), TIMER_FLAG_NO_MAPCHANGE);
		}
	}
	return Plugin_Continue;
}

public Action Timer_MixRespawnCT(Handle timer, any userid) {
	int client = GetClientOfUserId(userid);
	if(client < 1 || !g_Init || !IsClientInGame(client) || IsPlayerAlive(client)) {
		return Plugin_Stop;
	}

	// Still dead but the match is paused - retry every second until it resumes.
	if(g_bMatchPaused) {
		CreateTimer(1.0, Timer_MixRespawnCT, userid, TIMER_FLAG_NO_MAPCHANGE);
		return Plugin_Stop;
	}

	if(GetClientTeam(client) != CS_TEAM_CT) {
		return Plugin_Stop;
	}

	g_baAuthorizedSpawn[client] = true;
	CS_RespawnPlayer(client);
	return Plugin_Stop;
}

public Action Timer_CheckLoneT(Handle timer) {
	CheckLoneTerrorist();
	return Plugin_Stop;
}

void CheckLoneTerrorist(int excludeClient = -1) {
	// No free flashbang during knife rounds - knives only.
	if(!g_Init || g_bGaveLoneTFlash || !cv_LoneTFlashbang.BoolValue || g_iKnifeStage != KNIFE_NONE) {
		return;
	}

	int aliveCount = 0;
	int lastAlive = -1;

	for(int i = 1; i <= MaxClients; i++) {
		if(i == excludeClient || !IsClientInGame(i)) {
			continue;
		}

		if(GetClientTeam(i) == CS_TEAM_T && IsPlayerAlive(i)) {
			aliveCount++;
			lastAlive = i;
		}
	}

	if(aliveCount == 1) {
		g_bGaveLoneTFlash = true;
		GivePlayerItem(lastAlive, "weapon_flashbang");
		MixPrintToChat(lastAlive, "You are the last terrorist alive - here is a \x0Fflashbang\x08!");
	}
}

// Server settings for controlled rounds (knife rounds + the real match): no
// auto-balance/team limits/instant respawns. The -1 sentinels guard double-saves.

void SaveAndApplyMatchCvars() {
	ConVar cvBalance = FindConVar("mp_autoteambalance");
	if(cvBalance != null && g_iPrevAutoTeamBalance == -1) {
		g_iPrevAutoTeamBalance = cvBalance.IntValue;
		cvBalance.SetInt(0);
	}

	ConVar cvLimit = FindConVar("mp_limitteams");
	if(cvLimit != null && g_iPrevLimitTeams == -1) {
		g_iPrevLimitTeams = cvLimit.IntValue;
		cvLimit.SetInt(0);
	}

	ConVar cvRespawnCT = FindConVar("mp_respawn_on_death_ct");
	if(cvRespawnCT != null && g_iPrevRespawnOnDeathCT == -1) {
		g_iPrevRespawnOnDeathCT = cvRespawnCT.IntValue;
		cvRespawnCT.SetInt(0);
	}

	ConVar cvRespawnT = FindConVar("mp_respawn_on_death_t");
	if(cvRespawnT != null && g_iPrevRespawnOnDeathT == -1) {
		g_iPrevRespawnOnDeathT = cvRespawnT.IntValue;
		cvRespawnT.SetInt(0);
	}

	ConVar cvWaveCT = FindConVar("mp_respawnwavetime_ct");
	if(cvWaveCT != null && g_fPrevRespawnWaveCT < 0.0) {
		g_fPrevRespawnWaveCT = cvWaveCT.FloatValue;
		cvWaveCT.SetFloat(99999.0);
	}

	ConVar cvWaveT = FindConVar("mp_respawnwavetime_t");
	if(cvWaveT != null && g_fPrevRespawnWaveT < 0.0) {
		g_fPrevRespawnWaveT = cvWaveT.FloatValue;
		cvWaveT.SetFloat(99999.0);
	}
}

void RestoreMatchCvars() {
	if(g_iPrevAutoTeamBalance != -1) {
		ConVar cvBalance = FindConVar("mp_autoteambalance");
		if(cvBalance != null) {
			cvBalance.SetInt(g_iPrevAutoTeamBalance);
		}
		g_iPrevAutoTeamBalance = -1;
	}

	if(g_iPrevLimitTeams != -1) {
		ConVar cvLimit = FindConVar("mp_limitteams");
		if(cvLimit != null) {
			cvLimit.SetInt(g_iPrevLimitTeams);
		}
		g_iPrevLimitTeams = -1;
	}

	if(g_iPrevRespawnOnDeathCT != -1) {
		ConVar cvRespawnCT = FindConVar("mp_respawn_on_death_ct");
		if(cvRespawnCT != null) {
			cvRespawnCT.SetInt(g_iPrevRespawnOnDeathCT);
		}
		g_iPrevRespawnOnDeathCT = -1;
	}

	if(g_iPrevRespawnOnDeathT != -1) {
		ConVar cvRespawnT = FindConVar("mp_respawn_on_death_t");
		if(cvRespawnT != null) {
			cvRespawnT.SetInt(g_iPrevRespawnOnDeathT);
		}
		g_iPrevRespawnOnDeathT = -1;
	}

	if(g_fPrevRespawnWaveCT >= 0.0) {
		ConVar cvWaveCT = FindConVar("mp_respawnwavetime_ct");
		if(cvWaveCT != null) {
			cvWaveCT.SetFloat(g_fPrevRespawnWaveCT);
		}
		g_fPrevRespawnWaveCT = -1.0;
	}

	if(g_fPrevRespawnWaveT >= 0.0) {
		ConVar cvWaveT = FindConVar("mp_respawnwavetime_t");
		if(cvWaveT != null) {
			cvWaveT.SetFloat(g_fPrevRespawnWaveT);
		}
		g_fPrevRespawnWaveT = -1.0;
	}
}

// Knife rounds: one-round mini matches on the live-mix machinery, seated from
// the rosters. The first live round_end decides them; nothing is counted.

// Fresh setups and full stops drop every knife leftover,
// including the side-pick deadline timer.
void ResetKnifeState() {
	SetEasySpawnProtectionForKnife(false);
	g_iKnifeStage = KNIFE_NONE;
	g_bTeamsKnifeDone = false;
	g_bKnifeSideSwap = false;
	g_bKnifeSidePickPending = false;
	g_iKnifeSideWinnerTeam = 0;
	g_iKnifeSideChooser = -1;
	StopTimer(g_hKnifeSideTimer);
}

// Knife rounds enabled for the current mix size? (hnsmix_selection_phase)
bool IsSelectionPhaseEnabled() {
	int iMode = cv_SelectionPhase.IntValue;
	if(iMode == 0) {
		return false;
	}
	if(iMode == 2 && !IsCasualMix()) {
		return false; // disabled for ranked
	}
	if(iMode == 3 && IsCasualMix()) {
		return false; // disabled for casual
	}
	return true;
}

// Any live players left on this in-game side?
bool SideHasAlivePlayers(int iSide) {
	for(int i = 1; i <= MaxClients; i++) {
		if(IsClientInGame(i) && GetClientTeam(i) == iSide && IsPlayerAlive(i)) {
			return true;
		}
	}
	return false;
}

// hidenseek's hns_t_knife: Ts can knife-damage CTs (slow-stab only).
// On for knife rounds, off everywhere else.
void SetTKnifeAllowed(bool bAllowed) {
	ConVar cvar = FindConVar("hns_t_knife");
	if(cvar != null) {
		cvar.SetBool(bAllowed);
	}
}

// EasySpawnProtection independently gives every spawn god mode and a render
// color for its configured duration. Suspend it only for knife rounds and put
// the server's prior setting back when the knife state ends.
void SetEasySpawnProtectionForKnife(bool bDisable) {
	ConVar cvar = FindConVar("sm_easysp_enabled");
	if(cvar == null) {
		return;
	}

	if(bDisable) {
		if(g_iPrevEasySpawnProtection == -1) {
			g_iPrevEasySpawnProtection = cvar.BoolValue ? 1 : 0;
		}
		if(cvar.BoolValue) {
			cvar.SetBool(false);
		}
	}
	else if(g_iPrevEasySpawnProtection != -1) {
		cvar.SetBool(g_iPrevEasySpawnProtection != 0);
		g_iPrevEasySpawnProtection = -1;
	}
}

// Clear an already-active EasySpawnProtection window that began just before
// the knife restart. Disabling its cvar prevents new grants but does not undo
// a live god-mode timer or its render color by itself.
void ClearKnifeRoundSpawnProtection() {
	for(int i = 1; i <= MaxClients; i++) {
		if(!IsClientInGame(i) || !IsPlayerAlive(i)) {
			continue;
		}

		if(HasEntProp(i, Prop_Data, "m_takedamage")) {
			SetEntProp(i, Prop_Data, "m_takedamage", 2, 1);
		}
		SetEntityRenderMode(i, RENDER_NORMAL);
		SetEntityRenderColor(i, 255, 255, 255, 255);
	}
}

// HideNSeek must know a knife round is active before its own round_start and
// player_spawn callbacks run.  Zeroing hns_countdown_time alone was racy: a
// cached HNS countdown could still freeze CTs for five seconds.
void SetHnsCountdownSuppressed(bool bSuppressed) {
	ConVar cvar = FindConVar("hns_skip_countdown");
	if(cvar != null) {
		cvar.SetBool(bSuppressed);
	}
}

// hns_countdown_time (5s CT freeze) is zeroed during knife rounds.
void SuspendHnsCountdownForKnife() {
	ConVar cvar = FindConVar("hns_countdown_time");
	if(cvar != null && g_fPrevHnsCountdownTime < 0.0) {
		g_fPrevHnsCountdownTime = cvar.FloatValue;
		cvar.SetFloat(0.0);
	}
}

void RestoreHnsCountdown() {
	if(g_fPrevHnsCountdownTime >= 0.0) {
		ConVar cvar = FindConVar("hns_countdown_time");
		if(cvar != null) {
			cvar.SetFloat(g_fPrevHnsCountdownTime);
		}
		g_fPrevHnsCountdownTime = -1.0;
	}
}

// Round-start CT freeze length: hidenseek's countdown, or our fallback.
float GetRoundStartCtFreezeTime() {
	ConVar cvar = FindConVar("hns_countdown_time");
	return (cvar != null) ? cvar.FloatValue : cv_RoundStartPause.FloatValue;
}

// Opens the picking phase with the given roster team picking first.
void BeginPickingPhase(int iFirstPickTeam) {
	g_gameState = eGameState_PickingPlayers;
	g_iLastPickedTeam = GetOppositeTeam(iFirstPickTeam);

	int iCaptain = (iFirstPickTeam == CS_TEAM_CT) ? g_iCTCaptain : g_iTCaptain;
	AnnounceNoMixPlayers();
	if(iCaptain >= 1 && IsClientInGame(iCaptain)) {
		MixPrintToChatAll("Captains are now picking players - \x0F%N\x08 picks first!", iCaptain);
		OpenPlayersMenu(iCaptain, iFirstPickTeam);
	}
	else {
		MixPrintToChatAll("Captains are now picking players - type \x0F!c\x08 to fill the vacant captain slot!");
	}
	RefreshMixRosterPanels(); // spectators watch the rosters fill in live
}

void StartKnifeRound(int iStage) {
	g_iKnifeStage = iStage;
	g_bMixRoundWasLive = false; // the round the restart cuts short must not decide it

	ApplyPermanentRoundTime(); // knife stage is set - applies KNIFE_ROUND_TIME
	SaveAndApplyMatchCvars();
	SetMixGrenadeCvars();
	SetTKnifeAllowed(true); // Ts can stab CTs for the knife fight
	SetEasySpawnProtectionForKnife(true);
	ClearKnifeRoundSpawnProtection();
	SetHnsCountdownSuppressed(true); // neither side may be CT-frozen
	SuspendHnsCountdownForKnife(); // no CT freeze in a knife fight

	// A knife round owes no CT freeze - drop any remainder banked by an
	// earlier pause so OnGameFrame can't re-pin CTs for the whole round.
	g_fPostUnpauseCtFreeze = 0.0;
	g_bPostUnpauseCtFreezeActive = false;

	g_bGaveLoneTFlash = false;

	SetupTeams(); // seats the rosters, benches everyone else

	if(cv_LockTeams.BoolValue) {
		g_IsTeamsLocked = true;
	}

	if(iStage == KNIFE_CAPTAINS) {
		MixPrintToChatAll("\x0FKNIFE ROUND\x08 - the captains fight \x0F1v1\x08! The winner gets the \x0Ffirst pick\x08.");
	}
	else {
		MixPrintToChatAll("\x0FKNIFE ROUND\x08 - win the round and \x0Fchoose your starting side\x08!");
	}
	MixPrintToChatAll("This is a selection round - \x10nothing counts\x08 toward stats or elo.");

	g_Init = true;
	g_bBetweenRounds = true; // the restart below spawns everyone legitimately
	CloseAllMixMenus();
	ServerCommand("mp_restartgame 1");
}

// Winner known (roster CS_TEAM_*): stop the mini match, keep rosters/captains,
// and move on - into picking (captains) or the side-choice menu (teams).
void ConcludeKnifeRound(int iWinnerRosterTeam) {
	int iStage = g_iKnifeStage;
	g_iKnifeStage = KNIFE_NONE; // first: a terminate below must not re-enter

	// Restore mp_roundtime now - the next round_start is too late.
	ApplyPermanentRoundTime();

	g_Init = false;
	StopTimer(g_1v1Ticker);
	StopTimer(g_hPauseTimer);
	g_bMatchPaused = false;
	g_iUnpauseCountdown = 0;
	g_IsTimerPaused = true;
	g_bDidSwitchTeams = false;
	RestoreWinConditions();
	CancelDcWait();
	FreezePlayers(false);
	g_fPostUnpauseCtFreeze = 0.0;
	g_bPostUnpauseCtFreezeActive = false;
	UnfreezeGrenades();
	if(g_bEnginePaused) {
		ServerCommand("unpause");
		FindConVar("sv_pausable").SetInt(0);
		g_bEnginePaused = false;
	}
	RestoreMatchCvars();
	RestoreMixGrenadeCvars();
	SetTKnifeAllowed(false); // T stabs were for the knife fight only
	SetEasySpawnProtectionForKnife(false);
	SetHnsCountdownSuppressed(false);
	RestoreHnsCountdown();   // CT freeze back for live rounds

	bool bWinnerIsT = (iWinnerRosterTeam == CS_TEAM_T);

	if(iStage == KNIFE_CAPTAINS) {
		MixPrintToChatAll("%s won the knife round and picks first!", bWinnerIsT ? MIX_TEAM1_CHAT : MIX_TEAM2_CHAT);
		BeginPickingPhase(iWinnerRosterTeam);
		return;
	}

	// Teams knife: the winning team picks the side the match starts on.
	g_bTeamsKnifeDone = true;
	g_iKnifeSideWinnerTeam = iWinnerRosterTeam;
	MixPrintToChatAll("%s won the knife round and gets to choose their starting side!", bWinnerIsT ? MIX_TEAM1_CHAT : MIX_TEAM2_CHAT);

	int iChooser = GetMixTeamDecider(iWinnerRosterTeam);
	if(iChooser != -1) {
		OpenKnifeSideMenu(iChooser);
	}
	else {
		// Nobody left to choose (shouldn't happen - they just won a round):
		// keep the default sides and go live.
		g_bKnifeSideSwap = false;
		int iStarter = GetMixTeamDecider(GetOppositeTeam(iWinnerRosterTeam));
		if(iStarter != -1) {
			StartMatch(iStarter);
		}
	}
}

void OpenKnifeSideMenu(int client) {
	Menu menu = new Menu(MenuHandler_KnifeSide);
	menu.SetTitle("[%s] You won the knife round!\nChoose your team's starting side:", g_sChatPrefix);
	menu.AddItem("t", "Terrorists");
	menu.AddItem("ct", "Counter-Terrorists");
	menu.ExitButton = false;

	g_bKnifeSidePickPending = true;
	g_iKnifeSideChooser = client;
	// The timer owns the deadline, so a closed/displaced menu can't skip it.
	StopTimer(g_hKnifeSideTimer);
	g_hKnifeSideTimer = CreateTimer(float(KNIFE_SIDE_MENU_TIME), Timer_KnifeSideDefault, _, TIMER_FLAG_NO_MAPCHANGE);

	menu.Display(client, KNIFE_SIDE_MENU_TIME);
	MixPrintToChatAll("\x0F%N\x08 has \x0F%d\x08 seconds to choose their team's starting side.", client, KNIFE_SIDE_MENU_TIME);
	MixPrintToChat(client, "Pick from the menu, or type \x0F!ct\x08 / \x0F!t\x08 (or just \x0Fct\x08 / \x0Ft\x08) in chat. The \x0FT\x08 side is picked automatically when time runs out.");
}

// Applies the side pick (menu, chat or timeout) and starts the match.
void ApplyKnifeSidePick(int iSide) {
	if(!g_bKnifeSidePickPending || g_gameState != eGameState_DonePickingPlayers) {
		return; // the mix was stopped/reset while the pick was open
	}
	g_bKnifeSidePickPending = false;
	StopTimer(g_hKnifeSideTimer);

	int iChooser = g_iKnifeSideChooser;
	g_iKnifeSideChooser = -1;
	// Chat/timeout picks leave the menu up - close it (its Cancel is inert now).
	if(iChooser >= 1 && IsClientInGame(iChooser)) {
		CancelClientMenu(iChooser);
	}

	g_bKnifeSideSwap = (iSide != g_iKnifeSideWinnerTeam);
	MixPrintToChatAll("%s starts on the \x0F%s\x08 side!", (g_iKnifeSideWinnerTeam == CS_TEAM_T) ? MIX_TEAM1_CHAT : MIX_TEAM2_CHAT, (iSide == CS_TEAM_CT) ? "CT" : "T");

	int iStarter = (iChooser >= 1 && IsClientInGame(iChooser)) ? iChooser : GetMixTeamDecider(g_iKnifeSideWinnerTeam);
	if(iStarter == -1) {
		iStarter = GetMixTeamDecider(GetOppositeTeam(g_iKnifeSideWinnerTeam));
	}
	if(iStarter != -1) {
		StartMatch(iStarter);
	}
}

public Action Timer_KnifeSideDefault(Handle timer) {
	g_hKnifeSideTimer = null;
	if(g_bKnifeSidePickPending) {
		MixPrintToChatAll("Time is up - the \x0FT\x08 side was picked automatically.");
		ApplyKnifeSidePick(CS_TEAM_T);
	}
	return Plugin_Stop;
}

public int MenuHandler_KnifeSide(Menu menu, MenuAction action, int param1, int param2) {
	switch (action) {
		case MenuAction_Select: {
			char sInfo[8];
			menu.GetItem(param2, sInfo, sizeof(sInfo));
			ApplyKnifeSidePick(StrEqual(sInfo, "ct") ? CS_TEAM_CT : CS_TEAM_T);
		}
		case MenuAction_Cancel: {
			// Chat picks and the deadline timer keep working without the menu.
		}
		case MenuAction_End: {
			delete menu;
		}
	}
	return 0;
}

void StartMatch(int client) {
	if(g_iKnifeStage != KNIFE_NONE) {
		return; // a knife round is already being fought
	}

	int ttCount = CountPlayersInTeam(CS_TEAM_T);
	int ctCount = CountPlayersInTeam(CS_TEAM_CT);

	if(ctCount < 1 || ttCount < 1) {
		MixPrintToChat(client, "Not enough players to start a MIX.");
		return;
	}

	if(ctCount < g_iCurrentPlayerMode || ttCount < g_iCurrentPlayerMode) {
		MixPrintToChat(client, "Both players must be set correctly to start a %dv%d. (currently %dv%d)", g_iCurrentPlayerMode, g_iCurrentPlayerMode, ttCount, ctCount);
		return;
	}

	// The full teams fight a knife round for the starting side first; the
	// side pick re-enters StartMatch once made. Skipped when disabled.
	if(!g_bTeamsKnifeDone && IsSelectionPhaseEnabled()) {
		StartKnifeRound(KNIFE_TEAMS);
		return;
	}

	float fRoundTime = (g_fMixRoundTime > 0.0) ? g_fMixRoundTime : float(g_iCurrentPlayerMode * cv_TimePerPlayer.IntValue);
	g_TeamTimer[__TEAM_T] = fRoundTime;
	g_TeamTimer[__TEAM_CT] = fRoundTime;
	g_fMixConfiguredTime = fRoundTime;
	g_fMixMatchStart = GetEngineTime(); // wall clock for the Discord embed
	RequestMixStatusRefresh(); // going live is worth showing immediately

	// Temporarily restrict T grenades via hidenseek.sp convars for the duration of the mix.
	SetMixGrenadeCvars();
	g_bGaveLoneTFlash = false;

	// The scoreboard team scores double as the mix timers; save the real scores for restore.
	g_iPrevTeamScoreT = GetTeamScore(CS_TEAM_T);
	g_iPrevTeamScoreCT = GetTeamScore(CS_TEAM_CT);

	for(int i = 1; i <= MaxClients; i++) {
		fTimeSurvived[i] = 0.0;
		g_iaMixStabsGiven[i] = 0;
		g_iaMixStabsTaken[i] = 0;
		g_iaMixFallDamage[i] = 0;
		g_iaMixClutches[i] = 0;
		g_iaMixTRounds[i] = 0;
		g_faInhSurvival[i] = 0.0;
		g_iaInhStabsGiven[i] = 0;
		g_iaInhStabsTaken[i] = 0;
		g_iaInhFallDamage[i] = 0;
		g_iaInhClutches[i] = 0;
		g_iaInhTRounds[i] = 0;
	}
	g_bMixRoundWasLive = false;
	MixPrintToChatAll("\x0F%d\x0Av\x0F%d\x0A is now starting!", g_iCurrentPlayerMode, g_iCurrentPlayerMode);

	// Everyone knows the stakes up front: sizes at or below
	// hnsmix_elo_casual_max_size play casual (no elo, nothing banked to
	// !rank / !lb), larger sizes ranked.
	int iCasualMax = cv_EloCasualMaxSize.IntValue;
	// Fix the verdict for this whole mix - a later !add must not flip it.
	g_iMixCasualLock = (g_iCurrentPlayerMode <= iCasualMax) ? 1 : 0;
	g_bMixWentLiveRanked = (g_iMixCasualLock == 0);
	if(IsCasualMix()) {
		MixPrintToChatAll("This is a \x10CASUAL\x08 MIX - no elo or stats at stake. All MIXes \x0F%dv%d\x08 and under are casual; bigger sizes are ranked.", iCasualMax, iCasualMax);
	}
	else {
		MixPrintToChatAll("This is a \x04RANKED\x08 MIX - elo is at stake!");
	}

	SendStartingMatchHUDToAll();

	// No auto-balance/team limits/instant respawns for the whole mix; restored
	// at match stop. (hnsmix_ct_respawn_delay optionally revives CTs delayed.)
	SaveAndApplyMatchCvars();

	// Seat the sides the way the teams-knife winner chose them (the flag is
	// re-derived from reality every round start anyway).
	g_bDidSwitchTeams = g_bKnifeSideSwap;

	SetupTeams();

	if(cv_LockTeams.BoolValue) {
		g_IsTeamsLocked = true;
	}

	if(cv_QueuedMatchmaking.BoolValue) {
		GameRules_SetProp("m_bIsQueuedMatchmaking", 1);
		g_bQueuedMatchmakingSet = true;
	}

	g_Init = true;
	g_gameState = eGameState_Match;
	g_bBetweenRounds = true; // the restart below spawns everyone legitimately
	LogMessage("[MIX] Mix is live - anti-respawn enforcement enabled.");
	CloseAllMixMenus(); // the Start Mix panels (admin + captains) are done
	ServerCommand("mp_restartgame 1");
}

void SetupTeams() {
	for (int i = 1; i <= MaxClients; i++) {
		if(!IsClientInGame(i) || i == 0 || IsClientSourceTV(i)) {
			continue;
		}
		bool bIsCTPlayer = IsPlayerInTeam(i, CS_TEAM_CT);
		bool bIsTPlayer = IsPlayerInTeam(i, CS_TEAM_T);

		if(!bIsCTPlayer && !bIsTPlayer) {
			if(GetClientTeam(i) != CS_TEAM_SPECTATOR) {
				ChangeClientTeam(i, CS_TEAM_SPECTATOR);
			}
			continue;
		}

		// Live mix: hidenseek owns every T/CT move at round end, swapping sides on CT wins and T streaks.
		// Re-seating roster players against the raw roster sides here double-swapped around hidenseek's
		// SwapTeams(): everyone was yanked back first, hidenseek then swapped the restored teams, and
		// the sides never changed again after the first swap. Roster players are only seated at match
		// start; at round start the flag is re-derived from wherever hidenseek actually put them.
		if(g_Init) {
			continue;
		}

		if(bIsTPlayer && GetClientTeam(i) != GetInGameTeamFor(CS_TEAM_T)) {
			if(IsPlayerAlive(i)) {
				ChangeClientTeam_Alive(i, GetInGameTeamFor(CS_TEAM_T));
			}
			else {
				ChangeClientTeam(i, GetInGameTeamFor(CS_TEAM_T));
			}
			// They have been switched, no need to check the next thing, continue.
			continue;
		}

		if(bIsCTPlayer && GetClientTeam(i) != GetInGameTeamFor(CS_TEAM_CT)) {
			if(IsPlayerAlive(i)) {
				ChangeClientTeam_Alive(i, GetInGameTeamFor(CS_TEAM_CT));
			}
			else {
				ChangeClientTeam(i, GetInGameTeamFor(CS_TEAM_CT));
			}
			// yep.. same here.
			continue;
		}
	}

	if(!g_Init) {
		CheckTeamPlayersAreAlive(CS_TEAM_CT);
		CheckTeamPlayersAreAlive(CS_TEAM_T);
	}
}
// Match-start seating net: pulls roster members onto the side their roster
// team is currently playing (flag-aware condition AND target, so it can
// never fight a side swap it compares against).
void CheckTeamPlayersAreAlive(int team) {
	int teamIndex = (team == CS_TEAM_CT ? __TEAM_CT : __TEAM_T);
	int count = g_alPlayers[teamIndex].Length;

	if(count < 1) {
		return;
	}

	int iSide = GetInGameTeamFor(team);

	Player_t player;
	for(int i = 0; i < count; i++) {
		g_alPlayers[teamIndex].GetArray(i, player, sizeof(Player_t));

		if(GetClientTeam(player.clientIdx) != iSide) {
			ChangeClientTeam(player.clientIdx, iSide);
			// No respawn here: this runs at round end, and respawning would
			// bring dead players back before the next round starts. The
			// round_start RespawnPlayers net catches anyone the engine misses.
		}
	}
}

// hidenseek owns the physical T/CT swap; the side flag is re-derived from where the rosters
// actually sit every round start, so hnsmix can never fight it over who plays where - even for
// swaps hnsmix did not see happen.
void SyncSideFlagWithReality() {
	Player_t player;

	for(int i = 0; i < g_alPlayers[__TEAM_T].Length; i++) {
		g_alPlayers[__TEAM_T].GetArray(i, player, sizeof(Player_t));
		int c = player.clientIdx;
		if(c < 1 || !IsClientInGame(c)) {
			continue;
		}
		int iTeam = GetClientTeam(c);
		if(iTeam == CS_TEAM_T) {
			g_bDidSwitchTeams = false;
			return;
		}
		if(iTeam == CS_TEAM_CT) {
			g_bDidSwitchTeams = true;
			return;
		}
	}

	for(int i = 0; i < g_alPlayers[__TEAM_CT].Length; i++) {
		g_alPlayers[__TEAM_CT].GetArray(i, player, sizeof(Player_t));
		int c = player.clientIdx;
		if(c < 1 || !IsClientInGame(c)) {
			continue;
		}
		int iTeam = GetClientTeam(c);
		if(iTeam == CS_TEAM_CT) {
			g_bDidSwitchTeams = false;
			return;
		}
		if(iTeam == CS_TEAM_T) {
			g_bDidSwitchTeams = true;
			return;
		}
	}
	// Nobody seated on either side (everyone benched/disconnected) - keep
	// the flag as tracked.
}

void RespawnPlayers(int team) {
	int teamIndex = (team == CS_TEAM_CT ? __TEAM_CT : __TEAM_T);
	int count = g_alPlayers[teamIndex].Length;

	Player_t player;
	for(int i = 0; i < count; i++) {
		g_alPlayers[teamIndex].GetArray(i, player, sizeof(Player_t));

		if(player.clientIdx == -1) {
			continue;
		}

		// Respawn-only net: never move players between T and CT here, that is hidenseek's job and fighting
		// it caused kill/respawn storms at round start. One exception: a roster player stuck in spectator
		// is rescued onto their side first so the respawn has somewhere to put them.
		if(GetClientTeam(player.clientIdx) == CS_TEAM_SPECTATOR) {
			ChangeClientTeam(player.clientIdx, GetInGameTeamFor(team));
		}

		if(!IsPlayerAlive(player.clientIdx)) {
			CS_RespawnPlayer(player.clientIdx);
		}
	}
}

// GameState_Starting
void InitializeRound() {
	StopTimer(g_1v1Ticker);
	StopTimer(g_hPauseTimer);
	g_1v1Ticker = CreateTimer(1.0, Timer_1v1Tick, _, TIMER_REPEAT | TIMER_FLAG_NO_MAPCHANGE);
}

void MoveAllToSpec() {
	for (int i = 1; i <= MaxClients; i++) {
		if (!IsClientInGame(i) || IsClientSourceTV(i)) {
			continue;
		}

		if(GetClientTeam(i) != CS_TEAM_SPECTATOR) {
			g_baAuthorizedSpecMove[i] = true; // deliberate admin action
			ChangeClientTeam(i, CS_TEAM_SPECTATOR);
		}
	}
}

stock bool ChangeClientTeam_Alive(int client, int team) {
	if (client == 0 || client > MaxClients || !IsClientInGame(client) || !IsPlayerAlive(client) || team < 2 || team > 3) {
		return false;
	}

	int lifestate = GetEntProp(client, Prop_Send, "m_lifeState");
	SetEntProp(client, Prop_Send, "m_lifeState", 2);
	ChangeClientTeam(client, team);
	SetEntProp(client, Prop_Send, "m_lifeState", lifestate);
	
	return true;
}

public void AddSurviveTimeToAliveTeamPlayers(int team) {
	int teamIndex = (team == CS_TEAM_CT ? __TEAM_CT : __TEAM_T);
	int count = g_alPlayers[teamIndex].Length;

	Player_t player;
	for(int i = 0; i < count; i++) {
		g_alPlayers[teamIndex].GetArray(i, player, sizeof(Player_t));

		if(!IsPlayerAlive(player.clientIdx) || GetClientTeam(player.clientIdx) != CS_TEAM_T) {
			continue;
		}
		fTimeSurvived[player.clientIdx] += 1.0;
	}
}

public Action Timer_1v1Tick(Handle timer) {
	// Catch revives - rogue plugins that restore life state directly, which never fires player_spawn
	// and slips past the spawn shield. Anyone who died this round and is somehow alive again is
	// benched until the next round.
	if(!g_bBetweenRounds && !g_bMatchPaused) {
		for(int i = 1; i <= MaxClients; i++) {
			if(g_baDeadThisRound[i] && IsClientInGame(i) && !IsFakeClient(i) && IsPlayerAlive(i)
			&& (IsClientCaptain(i) || IsPlayerInTeam(i, CS_TEAM_CT) || IsPlayerInTeam(i, CS_TEAM_T))) {
				g_baDeadThisRound[i] = false;
				g_baAuthorizedSpecMove[i] = true;
				ChangeClientTeam(i, CS_TEAM_SPECTATOR);
				MixPrintToChat(i, "No respawning during a MIX round - you'll be back next round.");
				LogMessage("[MIX] Blocked a rogue revive of %L (moved to spectator).", i);
			}
		}
	}

	// Knife rounds run no clocks and bank no survival time - the revive shield
	// above still applies; round_end picks the winner.
	if(g_iKnifeStage != KNIFE_NONE) {
		return Plugin_Continue;
	}

	if(g_TeamTimer[__TEAM_CT] > 0.0 && g_TeamTimer[__TEAM_T] > 0.0) {
		// Decrement BEFORE refreshing the scoreboard: displaying first made the HUD lag the real clock by
		// one tick, so the last decrement only appeared after the round ended - which looked like the
		// timer still counting down after the CTs killed everyone.
		if(!g_IsTimerPaused && !g_bBetweenRounds) {

			int iCurrent = (g_bDidSwitchTeams ? __TEAM_CT : __TEAM_T);
			g_TeamTimer[iCurrent] -= 1.0;
			AddSurviveTimeToAliveTeamPlayers(CS_TEAM_CT);
			AddSurviveTimeToAliveTeamPlayers(CS_TEAM_T);
		}

		SendHudToAll();
		return Plugin_Continue;
	}

	int team = -1;
	if(g_TeamTimer[__TEAM_T] <= 0.0) {
		team = __TEAM_T;
	}

	if(g_TeamTimer[__TEAM_CT] <= 0.0) {
		team = __TEAM_CT;
	}

	char sWinColorTag[16];
	GetMixTeamColorTag((team == __TEAM_T) ? 1 : 2, sWinColorTag, sizeof(sWinColorTag));
	ScoreboardPrintAll(true, "%t", "Mix Win", sWinColorTag, (team == __TEAM_T) ? 1 : 2, g_iCurrentPlayerMode, g_iCurrentPlayerMode);

	// This ticker is ending right here - clear the handle first so Stop1v1's
	// StopTimer doesn't double-free it from inside its own callback.
	g_1v1Ticker = null;
	EndMixWithWinner(team, "time");

	g_hPauseTimer = null;
	return Plugin_Stop;
}

enum struct SurvivalStats_t {
	int clientIdx;
	float fTime;
}

void Stop1v1(int client = -1) {
	bool bWasLive = (g_Init || g_1v1Ticker != null);
	// A mix stopped mid-knife never concluded anything: knife rounds are
	// selection rounds - no scoreboard, no elo, nothing banked.
	bool bKnifeWasActive = (g_iKnifeStage != KNIFE_NONE);

	if(client > 0) {
		MixPrintToChatAll("\x0F%N\x08 has stopped the match.", client);
	}

	g_Init = false;
	g_bDidSwitchTeams = false;
	ResetKnifeState();

	if(bWasLive && !bKnifeWasActive) {
		LogMessage("[MIX] Mix ended - anti-respawn enforcement disabled.");

		// Stats wrap-up while the rosters and captains are still intact: the chat scoreboard, then the
		// cumulative MySQL flush. Wins/losses only when EndMixWithWinner set a winner; aborted mixes
		// persist activity stats without a result.
		PrintMixScoreboard();
		// Ratings first - the contribution math needs the per-mix accumulators
		// that FlushAllMixStats zeroes right after. The Discord embed reads the
		// same accumulators (plus the fresh elo), so it goes between the two.
		ApplyMixElo(g_iPendingStatsWinner);
		SendMixDiscordResults(g_iPendingStatsWinner);
		FlushAllMixStats(g_iPendingStatsWinner);
		// Ratings just moved, so the standing leaderboard embed is stale. Casual mixes bank nothing and
		// never trigger a refresh. Delayed because the elo writes above are threaded - querying now
		// would read the pre-mix table. Read before g_iMixCasualLock is cleared below.
		if(!IsCasualMix() && cv_DiscordLbAuto.BoolValue) {
			CreateTimer(3.0, Timer_RefreshMixLbEmbed, _, TIMER_FLAG_NO_MAPCHANGE);
		}
	}
	g_iPendingStatsWinner = -1;
	g_sMixEndReason[0] = '\0';
	RequestMixStatusRefresh(); // back to idle - drop the roster block now

	g_iMixCasualLock = -1; // the next mix decides casual/ranked on its own size
	g_bMixWentLiveRanked = false;

	// An add in flight dies with the mix - the rosters go below anyway.
	g_bAddActive = false;
	g_iAddPicker = -1;
	g_iaAddedUserId[0] = 0;
	g_iaAddedUserId[1] = 0;

	g_alPlayers[__TEAM_T].Clear();
	g_alPlayers[__TEAM_CT].Clear();

	// The mix is over - nobody is a captain anymore. (Leaving these set kept
	// ex-captains "part of the current mix" for !nomix/!replace checks.)
	g_iCTCaptain = -1;
	g_iTCaptain = -1;

	// Disconnect bookkeeping ends with the mix: replaced players are free
	// again, surrender votes/budgets reset, and nobody has a roster spot waiting.
	RestoreWinConditions();
	CancelDcWait();

	// Any outstanding self-replace offers die with the mix.
	for(int i = 1; i <= MaxClients; i++) {
		if(g_baSelfReplaceActive[i]) {
			ResolveSelfReplace(i, SELFREP_VOID);
		}
	}
	EndSurrenderVote(false);
	g_faSurrenderNextVote[__TEAM_T] = 0.0;
	g_faSurrenderNextVote[__TEAM_CT] = 0.0;
	if(g_alDcPlayers != null) {
		g_alDcPlayers.Clear();
	}
	if(g_alMixSwaps != null) {
		g_alMixSwaps.Clear();
	}
	if(g_alSurrenderVoteStarts != null) {
		g_alSurrenderVoteStarts.Clear();
	}
	for(int i = 1; i <= MaxClients; i++) {
		g_baReplacedSpectator[i] = false;
		g_iaPendingSeatTeam[i] = 0;
		g_baPendingSeatDead[i] = false;
		g_baPendingSeatSpot[i] = false;
		g_iaPendingSeatHealth[i] = 0;
		g_iaSelfOfferFrom[i] = 0;
		g_baSelfOfferMenuOpen[i] = false;
		g_baSelfReplaceActive[i] = false;
		g_iaSelfReplacePending[i] = 0;
		g_baSelfWaitPanelOpen[i] = false;
		g_haSelfReplaceTimeout[i] = null; // TIMER_FLAG_NO_MAPCHANGE: already dead across maps
	}

	g_TeamTimer[__TEAM_T] = 0.0;
	g_TeamTimer[__TEAM_CT] = 0.0;
	
	g_MenuAccess = -1;
	ClearAllHuds();

	g_IsTeamsLocked = false;
	MixPrintToChatAll("Teams are now \x04unlocked\x08!");

	StopTimer(g_1v1Ticker);
	StopTimer(g_hPauseTimer);
	g_gameState = eGameState_None;
	g_bAwaitingCaptains = false;

	g_bMatchPaused = false;
	g_iUnpauseCountdown = 0;
	FreezePlayers(false);
	UnfreezeGrenades();
	if(g_alPausedInfernos != null) {
		g_alPausedInfernos.Clear(); // mix stopped - snuffed fires stay out
	}
	if(g_alPausedSmokes != null) {
		g_alPausedSmokes.Clear(); // and snuffed smokes stay gone
	}
	RefreshOpenMixMenus();
	if(g_bEnginePaused) {
		ServerCommand("unpause");
		FindConVar("sv_pausable").SetInt(0);
		g_bEnginePaused = false;
	}

	if(g_bQueuedMatchmakingSet) {
		GameRules_SetProp("m_bIsQueuedMatchmaking", 0);
		g_bQueuedMatchmakingSet = false;
	}

	RestoreMixGrenadeCvars();
	SetTKnifeAllowed(false); // in case the mix stopped mid-knife-round
	SetHnsCountdownSuppressed(false);
	RestoreHnsCountdown();   // same - mid-knife stop

	// Owed post-unpause CT freeze dies with the mix.
	g_fPostUnpauseCtFreeze = 0.0;
	g_bPostUnpauseCtFreezeActive = false;

	// Re-split the teams first, then restore the balance convars, so the game's
	// auto-balancer doesn't fight the re-split while it happens.
	ReinstateTeams();

	RestoreMatchCvars();

	ArrayList g_alTimeSurvived = new ArrayList(sizeof(SurvivalStats_t));

	SurvivalStats_t stats;
	for(int i = 1; i <= MaxClients; i++) {
		if(!IsClientInGame(i) || IsClientSourceTV(i)) {
			continue;
		}
		stats.clientIdx = i;
		stats.fTime = fTimeSurvived[i];
		
		g_alTimeSurvived.PushArray(stats, sizeof(SurvivalStats_t));
	}
	SortADTArrayCustom(g_alTimeSurvived, ArrayADTCustomCallback);
	
	BuildSurvivalTimePanel(g_alTimeSurvived);

	for(int i = 1; i <= MaxClients; i++) {
		fTimeSurvived[i] = 0.0;
	}
	delete g_alTimeSurvived;

	if(bWasLive) {
		// Give the score slots back their real values now that they no longer
		// show timers. (A knife round never touched them - nothing to restore.)
		if(!bKnifeWasActive) {
			SetTeamScore(CS_TEAM_T, g_iPrevTeamScoreT);
			SetTeamScore(CS_TEAM_CT, g_iPrevTeamScoreCT);
		}

		// End the current round so the server resets back to normal play.
		if(cv_EndRoundOnStop.BoolValue) {
			CS_TerminateRound(0.0, CSRoundEnd_Draw, false);
		}
	}
}

public int ArrayADTCustomCallback(int index1, int index2, Handle array, Handle hndl) {
	SurvivalStats_t stats1; SurvivalStats_t stats2;

	GetArrayArray(array, index1, stats1, sizeof(SurvivalStats_t));
	GetArrayArray(array, index2, stats2, sizeof(SurvivalStats_t));

	return (stats2.fTime > stats1.fTime) ? 1 : 0;
}

void BuildSurvivalTimePanel(ArrayList alStats) {
	int len = alStats.Length;
	if(len == 0) {
		return;
	} 
	SurvivalStats_t stats;
	int itemCount = 0;

	int iFreeSpace = 60;

	char sWinPanelString[640], szBuffer[64], sName[128];

	FormatEx(sWinPanelString, sizeof(sWinPanelString), "<span class='fontSize-l'>%s<font color='#00ff00'> has won the match!</font></span><br /><br />", g_iLastWinningTeam == __TEAM_CT ? "<font color='#4EA6EA'>Team 2</font>" : "<font color='#FFA500'>Team 1</font>");

	for(int i = 0; i < len; i++) {
		alStats.GetArray(i, stats, sizeof(SurvivalStats_t));

		if(stats.fTime > 0.0) {

			Format(szBuffer, sizeof(szBuffer), "%.2f", stats.fTime);
			int iSpaces = (iFreeSpace - strlen(szBuffer));
			if(iSpaces < 0) {
				iSpaces = 0;
			}
			AddSymbolToText(iSpaces, szBuffer, sizeof(szBuffer), " ");
			GetClientName(stats.clientIdx, sName, sizeof(sName));
			FormatEx(sWinPanelString, sizeof(sWinPanelString), "%s<br />%s | %s", sWinPanelString, szBuffer, sName);

			itemCount++;
		}
	}

	if(itemCount > 0) {
		for(int i = 1; i <= MaxClients; i++) {
			if(!IsClientInGame(i) || IsClientSourceTV(i)) {
				continue;
			}
			ShowWinPanelHud(i, sWinPanelString);
		}
	}
}

void SendStartingMatchHUDToAll() {
	for(int i = 1; i <= MaxClients; i++) {
		if(!IsClientInGame(i) || IsClientSourceTV(i) || IsFakeClient(i)) {
			continue;
		}

		float fPos = -1.0;
		SetHudTextParams(fPos, fPos, 5.0, 255, 255, 128, 128, 2, 0.1, 0.2, 0.1);
		ShowSyncHudText(i, g_HudSyncMatchIsLive, "LIVE!\nLIVE!\nLIVE!");
	}
}

void SendHudToAll() {
	if(!cv_ScoreboardTimer.BoolValue) {
		return;
	}

	// The scoreboard team score slots display each team's remaining time in seconds.
	SetTeamScore(CS_TEAM_T, RoundToNearest(g_TeamTimer[g_bDidSwitchTeams ? __TEAM_CT : __TEAM_T]));
	SetTeamScore(CS_TEAM_CT, RoundToNearest(g_TeamTimer[!g_bDidSwitchTeams ? __TEAM_CT : __TEAM_T]));
}

void ClearAllHuds() {
	for(int i = 1; i <= MaxClients; i++) {
		if(!IsClientInGame(i) || IsClientSourceTV(i) || IsFakeClient(i)) {
			continue;
		}
		ClearSyncHud(i, g_HudSyncMatchIsLive);
	}
}

void ReinstateTeams() {
	// Alternate players between T and CT so the split is always even.
	// (The old logic split by client index halves, which could dump
	// every connected player onto the same team.)
	int iNext = CS_TEAM_T;

	for(int i = 1; i <= MaxClients; i++) {
		if(!IsClientInGame(i) || IsClientSourceTV(i)) {
			continue;
		}

		if(GetClientTeam(i) != iNext) {
			CS_SwitchTeam(i, iNext);
		}
		iNext = GetOppositeTeam(iNext);
	}

	for(int i = 1; i <= MaxClients; i++) {
		if(IsClientInGame(i) && GetClientTeam(i) != CS_TEAM_SPECTATOR && !IsClientSourceTV(i) && !IsPlayerAlive(i)) {
			CS_RespawnPlayer(i);
		}
	}
}

public Action EventRoundStart(Event event, const char[] name, bool dontBroadcast) {
	// mp_roundtime is enforced permanently, mix or no mix.
	ApplyPermanentRoundTime();

	// Pin the round starting NOW too - the convar only applies from the next.
	// Skipped during OVA for the same reason as above: hnsova pins its own.
	if(!MixOvaActive()) {
		float fRoundMinutes = (g_iKnifeStage != KNIFE_NONE) ? KNIFE_ROUND_TIME : cv_RoundTime.FloatValue;
		GameRules_SetProp("m_iRoundTime", RoundToNearest(fRoundMinutes * 60.0));
	}

	g_iRoundSerial++;
	g_bBetweenRounds = false;
	g_fRoundStartedAt = GetGameTime();
	RequestMixStatusRefresh(); // round clock restarted and sides may have swapped
	if(g_iKnifeStage != KNIFE_NONE) {
		ClearKnifeRoundSpawnProtection();
	}

	for(int i = 1; i <= MaxClients; i++) {
		g_baDeadThisRound[i] = false; // everyone starts the round fresh
	}

	if(g_Init) {
		// A new round ends any active pause; players respawn unfrozen anyway. Snuffed fires are NOT re-lit,
		// they belonged to the previous round. EXCEPTION: a disconnect pause survives the transition -
		// the leaver's death usually ENDS the round, and clearing the pause resumed play silently.
		if(g_bMatchPaused || g_iUnpauseCountdown > 0) {
			if(g_hDcWaitTimer != null || HasPendingDcEntries() || g_bAddActive) {
				g_iUnpauseCountdown = 0;
				StopTimer(g_hPauseTimer);
				g_hPauseTimer = CreateTimer(1.0, Timer_PauseHold, _, TIMER_REPEAT | TIMER_FLAG_NO_MAPCHANGE);
				FreezePlayers(true);
				// Pause spans the fresh round - CTs owe its full freeze window.
				g_fPostUnpauseCtFreeze = GetRoundStartCtFreezeTime();
				MixPrintToChatAll("The match stays \x02paused\x08 - %s.", g_bAddActive ? "captains are still adding players" : "still waiting on a missing player");
				RefreshOpenMixMenus();
			}
			else {
				g_bMatchPaused = false;
				g_iUnpauseCountdown = 0;
				g_fPostUnpauseCtFreeze = 0.0; // the new round runs its own freeze
				RestoreWinConditions(); // the suspension must die with the pause
				FreezePlayers(false);
				UnfreezeGrenades();
				g_alPausedInfernos.Clear();
				g_alPausedSmokes.Clear();
				MixPrintToChatAll("Pause cleared - a new round has started.");
				CloseAllMixMenus(); // the match is live again - drop stale panels
			}
		}

		g_IsTimerPaused = true;
		g_bGaveLoneTFlash = false;
		g_bMixRoundWasLive = true; // this round counts toward T-rounds played
		// Leftover post-unpause freeze belongs to the previous round.
		g_bPostUnpauseCtFreezeActive = false;
		// This round's CT freeze window (pauses bank the remainder).
		g_fCtFreezeEndsAt = GetGameTime() + GetRoundStartCtFreezeTime();
		// Timer stays paused at round start while CTs are frozen and Ts run
		// out. The round serial rides along so a stale timer (round ended
		// inside this window) can never resume the clock later.
		CreateTimer(cv_RoundStartPause.FloatValue, UnpauseTimer, g_iRoundSerial, TIMER_FLAG_NO_MAPCHANGE);

		// The side flag follows reality (hidenseek performs the swaps),
		// then the safety net respawns any roster player the engine's
		// new-round wave missed, inside the round-start grace window.
		SyncSideFlagWithReality();
		RespawnPlayers(CS_TEAM_CT);
		RespawnPlayers(CS_TEAM_T);

		// Re-assert T stabs every round: on during knife rounds, off otherwise.
		SetTKnifeAllowed(g_iKnifeStage != KNIFE_NONE);

		// Keep the game's instant respawns (both teams) off for the whole
		// mix, in case another cfg/plugin re-enables them between rounds.
		ConVar cvRespawnCT = FindConVar("mp_respawn_on_death_ct");
		if(cvRespawnCT != null && cvRespawnCT.IntValue != 0) {
			cvRespawnCT.SetInt(0);
		}
		ConVar cvRespawnT = FindConVar("mp_respawn_on_death_t");
		if(cvRespawnT != null && cvRespawnT.IntValue != 0) {
			cvRespawnT.SetInt(0);
		}
		ConVar cvWaveCT = FindConVar("mp_respawnwavetime_ct");
		if(cvWaveCT != null && cvWaveCT.FloatValue < 99999.0) {
			cvWaveCT.SetFloat(99999.0);
		}
		ConVar cvWaveT = FindConVar("mp_respawnwavetime_t");
		if(cvWaveT != null && cvWaveT.FloatValue < 99999.0) {
			cvWaveT.SetFloat(99999.0);
		}

		// The engine's auto-balance stays dead for the whole mix - hidenseek
		// re-enables it at map start, and a mix round must never begin with
		// anything re-balancing the rosters.
		ConVar cvBalanceMix = FindConVar("mp_autoteambalance");
		if(cvBalanceMix != null && cvBalanceMix.IntValue != 0) {
			cvBalanceMix.SetInt(0);
		}

		// Safety: the win-condition suspension must never outlive the pause that created it. A
		// round-transition pause clear used to leak it, leaving rounds unable to end by elimination,
		// so no CT wins and therefore no side swaps from hidenseek.
		if(!g_bMatchPaused && g_hDcWaitTimer == null && !HasPendingDcEntries()) {
			RestoreWinConditions();
		}

		// The hnsmix grenade settings always beat hidenseek's - re-assert
		// them every round in case anything changed them mid-mix.
		ApplyMixGrenadeCvars();

		// In a 1v1 the only terrorist is the lone terrorist from the start of
		// the round - no death/disconnect ever triggers the check, so run it
		// here too. Delayed a second so spawns/team swaps have settled.
		CreateTimer(1.0, Timer_CheckLoneT, _, TIMER_FLAG_NO_MAPCHANGE);

		InitializeRound();
	}
	return Plugin_Continue;
}

void ApplyPermanentRoundTime() {
	// hnsova owns the round length while One Versus All runs. Enforcing the mix round time on top of
	// it parked the OVA clock at 2:30 while the round ran ten minutes. A mix suspends OVA, so this
	// hands control back automatically.
	if(MixOvaActive()) {
		return;
	}

	float fMinutes = cv_RoundTime.FloatValue;

	// Knife rounds run longer - the clock shouldn't decide them.
	if(g_iKnifeStage != KNIFE_NONE) {
		fMinutes = KNIFE_ROUND_TIME;
	}

	ConVar cvar = FindConVar("mp_roundtime");
	if(cvar != null) {
		cvar.SetFloat(fMinutes);
	}

	cvar = FindConVar("mp_roundtime_hostage");
	if(cvar != null) {
		cvar.SetFloat(fMinutes);
	}

	cvar = FindConVar("mp_roundtime_defuse");
	if(cvar != null) {
		cvar.SetFloat(fMinutes);
	}
}

public void OnConfigsExecuted() {
	MigrateLegacyEloTagFormat();
	ApplyPermanentRoundTime();

	// Connect once, after the autoconfig executed, so hnsmix_sql_prefix from
	// the cfg is respected.
	if(!g_bStatsDbInit) {
		g_bStatsDbInit = true;
		cv_SqlPrefix.GetString(g_sSqlPrefix, sizeof(g_sSqlPrefix));
		ConnectStatsDatabase();
	}
}

// Existing server configs retain old cvar values. Update only the previous
// stock layouts so intentionally customized tag formats are never overwritten.
void MigrateLegacyEloTagFormat() {
	char sFormat[128];
	cv_EloTagChat.GetString(sFormat, sizeof(sFormat));
	if(StrEqual(sFormat, "{orange}{rank} {elo} elo {default}")
		|| StrEqual(sFormat, "{orange}{rank} {elo} elo {white}")
		|| StrEqual(sFormat, "{orange}{rank} {default}[{orange}{elo} ELO{default}] ")) {
		cv_EloTagChat.SetString("{default}{rank} [{elo} ELO] ");
	}

	cv_EloTagScore.GetString(sFormat, sizeof(sFormat));
	if(StrEqual(sFormat, "[{rank} {elo} elo] ")
		|| StrEqual(sFormat, "[{rank} {elo} elo]")) {
		cv_EloTagScore.SetString("{rank} [{elo} ELO] ");
	}
}

// hidenseek's round_end handler calls SwapTeams(), which CS_SwitchTeam's every player on the spot.
// Both plugins hook round_end as Post, so order is just load order and hidenseek sorts first: by
// the time the knife-round branch asked whether the losing side was still alive, the winner was
// standing on the loser's team and the answer inverted. SourceMod fires every Pre hook before any
// Post hook, so snapshotting here is order-independent. Do not move this into the Post handler.
public Action EventRoundEndPre(Event event, const char[] name, bool dontBroadcast) {
	int winner = event.GetInt("winner");
	g_bKnifeLoserAliveAtEnd = (winner == CS_TEAM_T || winner == CS_TEAM_CT)
		&& SideHasAlivePlayers(GetOppositeTeam(winner));
	return Plugin_Continue;
}

public Action EventRoundEnd(Event event, const char[] name, bool dontBroadcast) {
	g_IsTimerPaused = true;
	g_bBetweenRounds = true;
	RequestMixStatusRefresh(); // rosters and the round clock both move at round end
	int winner = event.GetInt("winner");

	// A knife round: its first live round decides it. The counters and side
	// bookkeeping below are deliberately skipped - knife rounds count nowhere.
	if(g_Init && g_iKnifeStage != KNIFE_NONE) {
		if(!g_bMixRoundWasLive) {
			return Plugin_Continue; // the leftover round mp_restartgame cut short
		}
		g_bMixRoundWasLive = false;

		if(winner != CS_TEAM_T && winner != CS_TEAM_CT) {
			MixPrintToChatAll("The knife round had no winner - fighting it again!");
			return Plugin_Continue; // the next round starts itself and re-decides
		}

		// Map the winning side to its roster team (the flag hasn't toggled yet).
		int iKnifeWinner = g_bDidSwitchTeams ? GetOppositeTeam(winner) : winner;

		// Losing side still alive means the clock decided, not a kill. A survival win means nothing in a
		// knife fight, so coinflip instead. Read from the Pre-hook snapshot: asking live team membership
		// here answers the wrong question, because the teams have already swapped.
		if(g_bKnifeLoserAliveAtEnd) {
			iKnifeWinner = (GetRandomInt(0, 1) == 0) ? CS_TEAM_T : CS_TEAM_CT;
			MixPrintToChatAll("Time ran out with both sides alive - \x0Fcoinflip\x08 decides the knife round!");
		}

		ConcludeKnifeRound(iKnifeWinner);
		return Plugin_Continue;
	}

	if(g_Init) {
		// Before the side flag toggles: clutches and rounds-played for the
		// T side that just played.
		CountRoundClutches();
		CountRoundTRounds();
		g_bMixRoundWasLive = false;

		if(winner == CS_TEAM_CT) {
			g_bDidSwitchTeams = !g_bDidSwitchTeams;
		}
		// Only re-seat stragglers here - do NOT respawn anyone and do NOT swap sides. hidenseek's
		// SwapTeams() physically swaps every player on CT wins; hnsmix just tracks it, and moving players
		// ourselves double-swapped and tore the round transition apart. The flag is re-derived from
		// reality at round start, so even unseen swaps cannot desync it.
		SetupTeams();
		FindConVar("mp_autoteambalance").IntValue = 0;
	}
	return Plugin_Continue;
}

stock void FreezePlayers(bool freeze = true) {
	for(int i = 1; i <= MaxClients; i++) {
		if(!IsClientInGame(i) || IsClientSourceTV(i) || IsFakeClient(i)) {
			continue;
		}

		// Only touch alive T/CT players - forcing MOVETYPE_WALK on spectators
		// would break their observer camera.
		if(GetClientTeam(i) < CS_TEAM_T || !IsPlayerAlive(i)) {
			continue;
		}

		SetEntityMoveType(i, freeze ? MOVETYPE_NONE : MOVETYPE_WALK);

		// God mode while paused: a frozen player standing in a (frozen)
		// molotov or next to a live grenade must not take damage.
		SetEntProp(i, Prop_Data, "m_takedamage", freeze ? 0 : 2, 1);
	}
}

// While the match is paused, no one can attack - this blocks knife swings and
// also stops new grenades from being thrown for the duration of the pause.
public Action OnPlayerRunCmd(int client, int &buttons) {
	if(g_bMatchPaused && (buttons & (IN_ATTACK | IN_ATTACK2))) {
		buttons &= ~(IN_ATTACK | IN_ATTACK2);
		return Plugin_Changed;
	}
	return Plugin_Continue;
}

// Freeze every grenade in flight: stop its motion (velocity saved for the unpause) and let
// HoldGrenadeThinks suspend its fuse. Molotov fire needs no motion handling - burn, spread and
// damage all run through its think, which is suspended too.
void FreezeGrenades() {
	float vel[3];

	float pos[3];

	for(int c = 0; c < sizeof(g_szNadeProjectiles); c++) {
		bool bSmoke = StrEqual(g_szNadeProjectiles[c], "smokegrenade_projectile");

		int ent = -1;
		while((ent = FindEntityByClassname(ent, g_szNadeProjectiles[c])) != -1) {
			// A smoke that already popped is the emitter of a client-side cloud that fades on wall time
			// regardless, so freezing it only leaves a ghost shell. Snuff it and re-deploy on unpause,
			// the same treatment as burning molotovs.
			if(bSmoke && GetEntProp(ent, Prop_Send, "m_bDidSmokeEffect") != 0) {
				SnuffPoppedSmoke(ent);
				continue;
			}

			int ref = EntIndexToEntRef(ent);
			if(IsNadeFrozen(ref)) {
				continue;
			}

			GetEntPropVector(ent, Prop_Data, "m_vecAbsVelocity", vel);
			GetEntPropVector(ent, Prop_Data, "m_vecAbsOrigin", pos);

			int idx = g_alFrozenNades.Push(ref);
			g_alFrozenNades.Set(idx, view_as<int>(vel[0]), 1);
			g_alFrozenNades.Set(idx, view_as<int>(vel[1]), 2);
			g_alFrozenNades.Set(idx, view_as<int>(vel[2]), 3);
			g_alFrozenNades.Set(idx, view_as<int>(pos[0]), 4);
			g_alFrozenNades.Set(idx, view_as<int>(pos[1]), 5);
			g_alFrozenNades.Set(idx, view_as<int>(pos[2]), 6);

			TeleportEntity(ent, NULL_VECTOR, NULL_VECTOR, view_as<float>({0.0, 0.0, 0.0}));
		}
	}
}

bool IsNadeFrozen(int ref) {
	for(int i = 0; i < g_alFrozenNades.Length; i++) {
		if(g_alFrozenNades.Get(i, 0) == ref) {
			return true;
		}
	}
	return false;
}

// Gravity nudges a "stopped" nade between frames - snap each one back to its
// freeze position with zero velocity every frame so it hangs perfectly still.
void PinFrozenNades() {
	float pos[3];
	for(int i = 0; i < g_alFrozenNades.Length; i++) {
		int ent = EntRefToEntIndex(g_alFrozenNades.Get(i, 0));
		if(ent == -1 || !IsValidEntity(ent)) {
			continue;
		}

		pos[0] = view_as<float>(g_alFrozenNades.Get(i, 4));
		pos[1] = view_as<float>(g_alFrozenNades.Get(i, 5));
		pos[2] = view_as<float>(g_alFrozenNades.Get(i, 6));
		TeleportEntity(ent, pos, NULL_VECTOR, view_as<float>({0.0, 0.0, 0.0}));

		// The fuse compares against wall-clock game time (m_flDetonateTime), which keeps advancing while
		// paused - without this the nade pops the instant the pause ends. Pushing the detonate time
		// forward one tick per frame preserves the remaining fuse exactly.
		SetEntPropFloat(ent, Prop_Data, "m_flDetonateTime", GetEntPropFloat(ent, Prop_Data, "m_flDetonateTime") + GetTickInterval());
	}
}

// Resume every frozen grenade on its original flight path.
void UnfreezeGrenades() {
	if(g_alFrozenNades == null) {
		return;
	}

	float vel[3]; float pos[3];
	for(int i = 0; i < g_alFrozenNades.Length; i++) {
		int ent = EntRefToEntIndex(g_alFrozenNades.Get(i, 0));
		if(ent == -1 || !IsValidEntity(ent)) {
			continue; // removed by a round change while frozen
		}

		vel[0] = view_as<float>(g_alFrozenNades.Get(i, 1));
		vel[1] = view_as<float>(g_alFrozenNades.Get(i, 2));
		vel[2] = view_as<float>(g_alFrozenNades.Get(i, 3));
		pos[0] = view_as<float>(g_alFrozenNades.Get(i, 4));
		pos[1] = view_as<float>(g_alFrozenNades.Get(i, 5));
		pos[2] = view_as<float>(g_alFrozenNades.Get(i, 6));

		TeleportEntity(ent, pos, NULL_VECTOR, vel);
	}
	g_alFrozenNades.Clear();
}

// Snuff every burning molotov/incendiary: flames and the fire-loop sound stop
// cleanly, and the fire's spot + thrower are remembered so RelightInfernos can
// bring it back on unpause.
void FreezeInfernos() {
	float pos[3];
	int ent = -1;

	while((ent = FindEntityByClassname(ent, "inferno")) != -1) {
		GetEntPropVector(ent, Prop_Data, "m_vecAbsOrigin", pos);

		int owner = GetEntPropEnt(ent, Prop_Data, "m_hOwnerEntity");
		int userid = (owner >= 1 && owner <= MaxClients && IsClientInGame(owner)) ? GetClientUserId(owner) : -1;

		int idx = g_alPausedInfernos.Push(view_as<int>(pos[0]));
		g_alPausedInfernos.Set(idx, view_as<int>(pos[1]), 1);
		g_alPausedInfernos.Set(idx, view_as<int>(pos[2]), 2);
		g_alPausedInfernos.Set(idx, userid, 3);

		AcceptEntityInput(ent, "Kill");
	}
}

void SnuffPoppedSmoke(int ent) {
	float pos[3];
	GetEntPropVector(ent, Prop_Data, "m_vecAbsOrigin", pos);

	int owner = GetEntPropEnt(ent, Prop_Data, "m_hOwnerEntity");
	int userid = (owner >= 1 && owner <= MaxClients && IsClientInGame(owner)) ? GetClientUserId(owner) : -1;

	int idx = g_alPausedSmokes.Push(view_as<int>(pos[0]));
	g_alPausedSmokes.Set(idx, view_as<int>(pos[1]), 1);
	g_alPausedSmokes.Set(idx, view_as<int>(pos[2]), 2);
	g_alPausedSmokes.Set(idx, userid, 3);

	AcceptEntityInput(ent, "Kill");
}

// Spawn a replacement grenade projectile and coax it into detonating: plugin-spawned projectiles
// never receive the fuse/think setup the game's own Create() functions do, so the fuse is marked
// elapsed and the think is kicked manually. A garbage-collect timer removes shells that never pop.
int SpawnPausedNade(const char[] sClassname, const float pos[3], int owner) {
	int ent = CreateEntityByName(sClassname);
	if(ent == -1) {
		return -1;
	}

	if(owner > 0 && IsClientInGame(owner)) {
		SetEntPropEnt(ent, Prop_Send, "m_hOwnerEntity", owner);
		SetEntProp(ent, Prop_Send, "m_iTeamNum", GetClientTeam(owner));
	}

	DispatchSpawn(ent);

	if(owner > 0 && IsClientInGame(owner)) {
		SetEntPropEnt(ent, Prop_Send, "m_hThrower", owner);
	}

	SetEntPropFloat(ent, Prop_Data, "m_flDetonateTime", GetGameTime());
	SetEntProp(ent, Prop_Data, "m_nNextThinkTick", GetGameTickCount() + 2);

	TeleportEntity(ent, pos, NULL_VECTOR, view_as<float>({0.0, 0.0, -300.0}));

	CreateTimer(20.0, Timer_KillPausedNade, EntIndexToEntRef(ent), TIMER_FLAG_NO_MAPCHANGE);
	return ent;
}

public Action Timer_KillPausedNade(Handle timer, any ref) {
	int ent = EntRefToEntIndex(ref);
	if(ent != -1 && IsValidEntity(ent)) {
		AcceptEntityInput(ent, "Kill");
	}
	return Plugin_Stop;
}

// Re-deploy every snuffed smoke where it was. The cloud is force-started via
// the two props the client actually renders the smoke from, so the cover
// comes back even if the projectile's own detonation logic never fires.
void RedeploySmokes() {
	if(g_alPausedSmokes == null) {
		return;
	}

	float pos[3];
	for(int i = 0; i < g_alPausedSmokes.Length; i++) {
		pos[0] = view_as<float>(g_alPausedSmokes.Get(i, 0));
		pos[1] = view_as<float>(g_alPausedSmokes.Get(i, 1));
		pos[2] = view_as<float>(g_alPausedSmokes.Get(i, 2)) + 8.0;

		int owner = GetClientOfUserId(g_alPausedSmokes.Get(i, 3));

		int ent = SpawnPausedNade("smokegrenade_projectile", pos, owner);
		if(ent == -1) {
			continue;
		}

		SetEntProp(ent, Prop_Send, "m_bDidSmokeEffect", 1);
		SetEntProp(ent, Prop_Send, "m_nSmokeEffectTickBegin", GetGameTickCount());
	}
	g_alPausedSmokes.Clear();
}

// Relit fires are reimplemented by hand (flame particles plus a damage tick): a real inferno can
// only be built by the game's own Create() functions, whose symbols are stripped from this build,
// and a bare-spawned molotov projectile never detonates.
#define RELIGHT_FIRE_DURATION 7.0   // seconds, ~a standard molotov burn
#define RELIGHT_FIRE_RADIUS 140.0   // units, ~inferno coverage
#define RELIGHT_FIRE_DAMAGE 10.0    // per half-second tick (20/s)

void RelightInfernos() {
	if(g_alPausedInfernos == null) {
		return;
	}

	float pos[3];
	for(int i = 0; i < g_alPausedInfernos.Length; i++) {
		pos[0] = view_as<float>(g_alPausedInfernos.Get(i, 0));
		pos[1] = view_as<float>(g_alPausedInfernos.Get(i, 1));
		pos[2] = view_as<float>(g_alPausedInfernos.Get(i, 2));

		StartFakeFire(pos, g_alPausedInfernos.Get(i, 3));
	}
	g_alPausedInfernos.Clear();
}

void StartFakeFire(const float pos[3], int ownerUserid) {
	int particle = CreateEntityByName("info_particle_system");
	if(particle != -1) {
		DispatchKeyValue(particle, "effect_name", "molotov_groundfire");
		DispatchKeyValue(particle, "start_active", "1");
		DispatchSpawn(particle);
		ActivateEntity(particle);
		TeleportEntity(particle, pos, NULL_VECTOR, NULL_VECTOR);
		AcceptEntityInput(particle, "Start");
	}

	DataPack dp = new DataPack();
	dp.WriteFloat(pos[0]);
	dp.WriteFloat(pos[1]);
	dp.WriteFloat(pos[2]);
	dp.WriteCell(ownerUserid);
	dp.WriteCell(particle == -1 ? -1 : EntIndexToEntRef(particle));
	dp.WriteFloat(GetGameTime() + RELIGHT_FIRE_DURATION);

	CreateTimer(0.5, Timer_FakeFireTick, dp, TIMER_REPEAT | TIMER_FLAG_NO_MAPCHANGE | TIMER_DATA_HNDL_CLOSE);
}

public Action Timer_FakeFireTick(Handle timer, DataPack dp) {
	dp.Reset();
	float pos[3];
	pos[0] = dp.ReadFloat();
	pos[1] = dp.ReadFloat();
	pos[2] = dp.ReadFloat();
	int ownerUserid = dp.ReadCell();
	int particleRef = dp.ReadCell();
	float endTime = dp.ReadFloat();

	// Burnt out, or the mix ended - remove the flames and stop.
	if(GetGameTime() >= endTime || !g_Init) {
		int particle = (particleRef == -1) ? -1 : EntRefToEntIndex(particleRef);
		if(particle != -1 && IsValidEntity(particle)) {
			AcceptEntityInput(particle, "Stop");
			AcceptEntityInput(particle, "Kill");
		}
		return Plugin_Stop;
	}

	// Never burn anyone during a (re-)pause; players are god-moded anyway.
	if(g_bMatchPaused) {
		return Plugin_Continue;
	}

	int owner = GetClientOfUserId(ownerUserid);
	float clientPos[3];

	for(int i = 1; i <= MaxClients; i++) {
		if(!IsClientInGame(i) || !IsPlayerAlive(i) || GetClientTeam(i) < CS_TEAM_T) {
			continue;
		}

		// No team damage, matching normal inferno behavior.
		if(owner > 0 && IsClientInGame(owner) && GetClientTeam(i) == GetClientTeam(owner)) {
			continue;
		}

		GetClientAbsOrigin(i, clientPos);
		if(GetVectorDistance(clientPos, pos) > RELIGHT_FIRE_RADIUS) {
			continue;
		}

		SDKHooks_TakeDamage(i, (owner > 0) ? owner : 0, (owner > 0) ? owner : 0, RELIGHT_FIRE_DAMAGE, DMG_BURN);
	}
	return Plugin_Continue;
}

// Push every frozen grenade's next think one tick forward each frame while paused: fuse timers,
// smoke deploys and decoy pops all suspend, and the remaining time resumes intact. Burning
// molotovs are handled by FreezeInfernos/RelightInfernos instead.
void HoldGrenadeThinks() {
	int ent;
	for(int c = 0; c < sizeof(g_szNadeProjectiles); c++) {
		ent = -1;
		while((ent = FindEntityByClassname(ent, g_szNadeProjectiles[c])) != -1) {
			BumpNextThink(ent);
		}
	}
}

void BumpNextThink(int ent) {
	int tick = GetEntProp(ent, Prop_Data, "m_nNextThinkTick");
	if(tick > 0) {
		SetEntProp(ent, Prop_Data, "m_nNextThinkTick", tick + 1);
	}
}

// Captains and admins can pause; in a 1v1 both players can, regardless of
// captain bookkeeping - there is nobody else to ask.
bool CanPauseMix(int client) {
	if(IsClientCaptain(client) || HasMixAdminAccess(client)) {
		return true;
	}

	if(g_iCurrentPlayerMode == 1 && (IsPlayerInTeam(client, CS_TEAM_CT) || IsPlayerInTeam(client, CS_TEAM_T))) {
		return true;
	}
	return false;
}

public Action Command_PauseMix(int client, int args) {
	if(client == 0) {
		ReplyToCommand(client, "[%s] This command must be used in-game.", g_sChatPrefix);
		return Plugin_Handled;
	}

	if(!CanPauseMix(client)) {
		MixPrintToChat(client, "Only captains and admins can pause the match.");
		return Plugin_Handled;
	}

	DoMatchPause(client);
	return Plugin_Handled;
}

public Action Command_UnpauseMix(int client, int args) {
	if(client == 0) {
		ReplyToCommand(client, "[%s] This command must be used in-game.", g_sChatPrefix);
		return Plugin_Handled;
	}

	if(!CanPauseMix(client)) {
		MixPrintToChat(client, "Only captains and admins can unpause the match.");
		return Plugin_Handled;
	}

	DoMatchUnpause(client);
	return Plugin_Handled;
}

void DoMatchPause(int client) {
	if(!g_Init) {
		MixPrintToChat(client, "There is no live MIX to pause.");
		return;
	}

	if(g_bMatchPaused) {
		// Pausing during the unpause countdown cancels the resume.
		if(g_iUnpauseCountdown > 0) {
			g_iUnpauseCountdown = 0;
			StopTimer(g_hPauseTimer);
			g_hPauseTimer = CreateTimer(1.0, Timer_PauseHold, _, TIMER_REPEAT | TIMER_FLAG_NO_MAPCHANGE);
			MixPrintToChatAll("\x0F%N\x08 cancelled the resume - the match stays \x02paused\x08.", client);
			RefreshOpenMixMenus();
			return;
		}
		MixPrintToChat(client, "The match is already paused.");
		return;
	}

	g_bMatchPaused = true;
	g_iUnpauseCountdown = 0;
	g_IsTimerPaused = true;
	BankRoundStartCtFreeze();

	FreezePlayers(true);
	FreezeGrenades();
	FreezeInfernos();

	StopTimer(g_hPauseTimer);
	g_hPauseTimer = CreateTimer(1.0, Timer_PauseHold, _, TIMER_REPEAT | TIMER_FLAG_NO_MAPCHANGE);

	MixPrintToChatAll("\x0F%N\x08 has \x02paused\x08 the match! Use \x0F!unpause\x08 to resume.", client);
	RefreshOpenMixMenus();
}

// Bank what's left of the round-start CT freeze so it resumes after unpause.
void BankRoundStartCtFreeze() {
	g_bPostUnpauseCtFreezeActive = false; // pause freeze owns everyone now
	float fFreezeLeft = g_fCtFreezeEndsAt - GetGameTime();
	g_fPostUnpauseCtFreeze = (!g_bBetweenRounds && fFreezeLeft > 0.0) ? fFreezeLeft : 0.0;
}

void DoMatchUnpause(int client) {
	if(!g_Init || !g_bMatchPaused) {
		MixPrintToChat(client, "The match is not paused.");
		return;
	}

	// A 1v1 has no replacement pool: while the wait runs, captains may not unpause - they return,
	// forfeit on the clock, or the mix is stopped. Admins may override; the missing player keeps
	// their spot and no forfeit fires later.
	if(g_hDcWaitTimer != null) {
		if(!HasMixAdminAccess(client)) {
			MixPrintToChat(client, "Waiting for \x0F%s\x08 to reconnect (\x0F%d:%02d\x08 left) - the match can't be unpaused until they return or forfeit.", g_sDcWaitName, g_iDcWaitSecondsLeft / 60, g_iDcWaitSecondsLeft % 60);
			return;
		}
		MixPrintToChatAll("\x0F%N\x08 overrode the wait for \x0F%s\x08 - they can still reconnect and rejoin.", client, g_sDcWaitName);
		CancelDcWait();
	}

	// An add owns the pause until both picks land (or it is cancelled).
	if(g_bAddActive && !HasMixAdminAccess(client)) {
		MixPrintToChat(client, "Captains are still adding players - \x0F!canceladd\x08 to cancel.");
		return;
	}

	if(g_iUnpauseCountdown > 0) {
		MixPrintToChat(client, "The match is already resuming.");
		return;
	}

	g_iUnpauseCountdown = 5;

	StopTimer(g_hPauseTimer);
	g_hPauseTimer = CreateTimer(1.0, Timer_UnpauseCountdown, _, TIMER_REPEAT | TIMER_FLAG_NO_MAPCHANGE);

	MixPrintToChatAll("\x0F%N\x08 has \x04unpaused\x08 the match!", client);
	RefreshOpenMixMenus();
}

// While paused, including the unpause countdown, freeze the round clock dead. The clock displays
// (m_fRoundStartTime + m_iRoundTime - now) and the server ends the round on the same math, so
// pushing the round start forward by exactly one frame every frame holds both still - with none
// of the once-per-second flicker a timer-based hold would show.
public void OnGameFrame() {
	if(!g_bMatchPaused) {
		// Re-pin CTs during the owed freeze - stray hidenseek timers unfreeze.
		// Never during a knife round: those have no CT freeze (both sides fight),
		// so a stale owed-freeze flag must not pin CTs for the whole round.
		if(g_bPostUnpauseCtFreezeActive && g_iKnifeStage == KNIFE_NONE) {
			for(int i = 1; i <= MaxClients; i++) {
				if(!IsClientInGame(i) || IsFakeClient(i) || IsClientSourceTV(i)) {
					continue;
				}
				if(GetClientTeam(i) != CS_TEAM_CT || !IsPlayerAlive(i)) {
					continue;
				}
				if(GetEntityMoveType(i) != MOVETYPE_NONE) {
					SetEntityMoveType(i, MOVETYPE_NONE);
				}
			}
		}
		return;
	}
	GameRules_SetPropFloat("m_fRoundStartTime", GameRules_GetPropFloat("m_fRoundStartTime") + GetTickInterval());

	// Re-pin frozen players every frame: hidenseek's round-start CT countdown expires on its own timer
	// and unfreezes them, which overrode the pause freeze for up to a second. The prop check keeps
	// this a cheap no-op for players already pinned.
	for(int i = 1; i <= MaxClients; i++) {
		if(!IsClientInGame(i) || IsFakeClient(i) || IsClientSourceTV(i)) {
			continue;
		}
		if(GetClientTeam(i) < CS_TEAM_T || !IsPlayerAlive(i)) {
			continue;
		}
		if(GetEntityMoveType(i) != MOVETYPE_NONE) {
			SetEntityMoveType(i, MOVETYPE_NONE);
		}
		// The pause's god mode gets re-pinned the same way (the unfreeze
		// restores m_takedamage along with the movetype).
		if(GetEntProp(i, Prop_Data, "m_takedamage", 2) != 0) {
			SetEntProp(i, Prop_Data, "m_takedamage", 0, 1);
		}
	}

	// Suspend every grenade fuse for the duration of the pause, and hold each
	// frozen nade exactly at its freeze position.
	HoldGrenadeThinks();
	PinFrozenNades();
}

// While paused: keep everyone frozen and the arena clear.
public Action Timer_PauseHold(Handle timer) {
	if(!g_bMatchPaused) {
		g_hPauseTimer = null;
		return Plugin_Stop;
	}

	// Anyone who respawned or joined mid-pause gets frozen too, and any
	// grenade or fire that slipped through in the same frame the pause
	// landed gets frozen/snuffed as well.
	FreezePlayers(true);
	FreezeGrenades();
	FreezeInfernos();
	return Plugin_Continue;
}

public Action Timer_UnpauseCountdown(Handle timer) {
	if(!g_bMatchPaused) {
		g_hPauseTimer = null;
		return Plugin_Stop;
	}

	if(g_iUnpauseCountdown > 0) {
		// The round clock stays frozen through the countdown: OnGameFrame
		// keeps holding it as long as g_bMatchPaused is true.
		MixPrintToChatAll("Resuming in \x0F%d\x08...", g_iUnpauseCountdown);
		g_iUnpauseCountdown--;
		return Plugin_Continue;
	}

	g_bMatchPaused = false;
	RestoreWinConditions(); // rounds may end normally again
	FreezePlayers(false);
	UnfreezeGrenades();
	RelightInfernos();
	RedeploySmokes();

	// CTs serve the freeze remainder the pause swallowed.
	float fCtFreeze = g_fPostUnpauseCtFreeze;
	g_fPostUnpauseCtFreeze = 0.0;
	if(fCtFreeze > 0.1 && !g_bBetweenRounds) {
		StartPostUnpauseCtFreeze(fCtFreeze);
	}
	else {
		g_IsTimerPaused = false;
	}

	MixPrintToChatAll("The match is \x04LIVE\x08!");
	CloseAllMixMenus(); // nobody plays a live round with a panel up

	g_hPauseTimer = null;
	return Plugin_Stop;
}

// Re-freeze the CT side (movement + weapon) for the owed remainder.
void StartPostUnpauseCtFreeze(float fDuration) {
	g_fCtFreezeEndsAt = GetGameTime() + fDuration; // re-pause re-banks the rest
	g_bPostUnpauseCtFreezeActive = true;
	g_IsTimerPaused = true;
	SetCtSideFrozen(true, fDuration);
	MixPrintToChatAll("CTs stay frozen for \x0F%d\x08 more second%s - the round-start freeze resumes where the pause caught it.", RoundToCeil(fDuration), (RoundToCeil(fDuration) == 1) ? "" : "s");
	CreateTimer(fDuration, Timer_PostUnpauseCtFreezeEnd, g_iRoundSerial, TIMER_FLAG_NO_MAPCHANGE);
}

public Action Timer_PostUnpauseCtFreezeEnd(Handle timer, any data) {
	// Void if the round ended, a new pause took over, or the mix stopped.
	if(data != g_iRoundSerial || !g_Init || g_bBetweenRounds || g_bMatchPaused || !g_bPostUnpauseCtFreezeActive) {
		return Plugin_Stop;
	}
	g_bPostUnpauseCtFreezeActive = false;
	SetCtSideFrozen(false);
	g_IsTimerPaused = false;
	return Plugin_Stop;
}

// Freeze/unfreeze alive CTs; fAttackDelay also blocks their held weapon.
void SetCtSideFrozen(bool bFrozen, float fAttackDelay = 0.0) {
	for(int i = 1; i <= MaxClients; i++) {
		if(!IsClientInGame(i) || IsFakeClient(i) || IsClientSourceTV(i)) {
			continue;
		}
		if(GetClientTeam(i) != CS_TEAM_CT || !IsPlayerAlive(i)) {
			continue;
		}
		SetEntityMoveType(i, bFrozen ? MOVETYPE_NONE : MOVETYPE_WALK);
		if(bFrozen && fAttackDelay > 0.0) {
			int iWeapon = GetEntPropEnt(i, Prop_Send, "m_hActiveWeapon");
			if(iWeapon > 0 && IsValidEntity(iWeapon)) {
				SetEntPropFloat(iWeapon, Prop_Send, "m_flNextPrimaryAttack", GetGameTime() + fAttackDelay);
				SetEntPropFloat(iWeapon, Prop_Send, "m_flNextSecondaryAttack", GetGameTime() + fAttackDelay);
			}
		}
	}
}
Action UnpauseTimer(Handle timer, any data) {
	// Only the CURRENT round's freeze-window timer may resume the clock. A stale one, whose round
	// ended early, must not unpause between rounds (the bank would drain through the whole
	// post-round) or fire early into the next round's window. And never resume while a match pause holds.
	if(data == g_iRoundSerial && !g_bBetweenRounds && !g_bMatchPaused) {
		g_IsTimerPaused = false;
	}
	return Plugin_Stop;
}

stock void AddSymbolToText(int count, char [] gszBuffer, int len, const char[] symbol) {
	for(int i = 0; i < count; i++) {
		Format(gszBuffer, len, "%s%s", gszBuffer, symbol);
	}
}

void ShowWinPanelHud(int client, char[] message) {
	Event event = CreateEvent("cs_win_panel_round");
	event.SetString("funfact_token", message);

	if(IsClientInGame(client) && !IsFakeClient(client)) {
		event.FireToClient(client);
	}
	event.Cancel();
	CreateTimer(5.0, Timer_ResetWinPanel, GetClientUserId(client), TIMER_FLAG_NO_MAPCHANGE);
}

public Action Timer_ResetWinPanel(Handle tmr, any data) {
	int client = GetClientOfUserId(data);
	if(!IsClientInGame(client) || IsFakeClient(client) || client <= 0) {
		return Plugin_Continue;
	}

	Event event = CreateEvent("cs_win_panel_round");
	event.SetString("funfact_token", "");
	event.FireToClient(client);
	event.Cancel();

	return Plugin_Continue;
}
