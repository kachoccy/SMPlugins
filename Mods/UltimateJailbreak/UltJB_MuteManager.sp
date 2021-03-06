#include <sourcemod>
#include <sdkhooks>
#include <sdktools_voice>
#include <dhooks>
#include <basecomm>
#include <sdktools_functions>
#include <hls_color_chat>
#include "Includes/ultjb_warden"
#include "Includes/ultjb_last_request"

#undef REQUIRE_PLUGIN
#include "../../Libraries/SquelchManager/squelch_manager"
#include "../../Libraries/ModelSkinManager/model_skin_manager"
#define REQUIRE_PLUGIN

#pragma semicolon 1

new const String:PLUGIN_NAME[] = "[UltJB] Mute Manager";
new const String:PLUGIN_VERSION[] = "1.21";

public Plugin:myinfo =
{
	name = PLUGIN_NAME,
	author = "hlstriker",
	description = "The mute manager plugin for Ultimate Jailbreak.",
	version = PLUGIN_VERSION,
	url = "www.swoobles.com"
}

#define VOICE_HOLD_TIME			0.15	// How long to wait after the warden stops talking to unmute everyone.
#define VOICE_MAX_SPEAK_TIME	15.0	// How long the warden can talk in the mic before everyone is unmuted.
#define VOICE_MIN_SPEAK_TIME	9.0
#define VOICE_MIN_PLAYERS		10.0

new Float:g_fVoiceHoldTime;
new Float:g_fTotalSpeakTime;
new Float:g_fStoppedSpeakingTime;
new Float:g_fLastCheckTime[MAXPLAYERS+1];

new bool:g_bIsWardenSpeaking;
new bool:g_bArePlayersMuted;
new bool:g_bWardenMuteActive;

new Handle:g_hOnVoiceTransmit;
new Handle:g_hTimer_MuteHUD;

new bool:g_bLibLoaded_SquelchManager;
new bool:g_bLibLoaded_ModelSkinManager;

new g_iHookedVoiceTransmit[MAXPLAYERS+1];

public OnPluginStart()
{
	CreateConVar("ultjb_mute_manager_ver", PLUGIN_VERSION, PLUGIN_NAME, FCVAR_PLUGIN|FCVAR_SPONLY|FCVAR_NOTIFY|FCVAR_PRINTABLEONLY);
	
	new Handle:hGameConf = LoadGameConfigFile("voicehook.csgo");
	if(hGameConf == INVALID_HANDLE)
		SetFailState("Could not load gamedata voicehook.csgo");
	
	new iOffset = GameConfGetOffset(hGameConf, "OnVoiceTransmit");
	CloseHandle(hGameConf);
	
	if(iOffset == -1)
		SetFailState("Could not get offset for OnVoiceTransmit");
	
	g_hOnVoiceTransmit = DHookCreate(iOffset, HookType_Entity, ReturnType_Void, ThisPointer_CBaseEntity, OnVoiceTransmit);
	
	RegConsoleCmd("sm_wmute", OnWardenMute, "Toggle Warden mute powers.");
	
	HookEvent("player_death", Event_PlayerDeath_Post, EventHookMode_Post);
	HookEvent("player_team", Event_PlayerTeam_Post, EventHookMode_Post);
}

public OnAllPluginsLoaded()
{
	g_bLibLoaded_SquelchManager = LibraryExists("squelch_manager");
	g_bLibLoaded_ModelSkinManager = LibraryExists("model_skin_manager");
}

public OnLibraryAdded(const String:szName[])
{
	if(StrEqual(szName, "squelch_manager"))
	{
		g_bLibLoaded_SquelchManager = true;
	}
	else if(StrEqual(szName, "model_skin_manager"))
	{
		g_bLibLoaded_ModelSkinManager = true;
	}
}

public OnLibraryRemoved(const String:szName[])
{
	if(StrEqual(szName, "squelch_manager"))
	{
		g_bLibLoaded_SquelchManager = false;
	}
	else if(StrEqual(szName, "model_skin_manager"))
	{
		g_bLibLoaded_ModelSkinManager = false;
	}
}

public OnMapStart()
{
	g_hTimer_MuteHUD = INVALID_HANDLE;
	g_fStoppedSpeakingTime = GetGameTime();
	g_bWardenMuteActive = true;
}

public Event_PlayerTeam_Post(Handle:hEvent, const String:szName[], bool:bDontBroadcast)
{
	if(GetEventInt(hEvent, "team") == GetEventInt(hEvent, "oldteam"))
		return;
	
	new iClient = GetClientOfUserId(GetEventInt(hEvent, "userid"));
	if(!IsClientInGame(iClient))
		return;
	
	new bool:bIsClientJoiningCT;
	
	if(GetEventInt(hEvent, "team") == TEAM_GUARDS)
		bIsClientJoiningCT = true;
	
	for(new iPlayer=1; iPlayer<=MaxClients; iPlayer++)
	{
		if(iPlayer == iClient)
			continue;
		
		if(!IsClientInGame(iPlayer) || IsFakeClient(iPlayer))
			continue;
		
		if(g_bLibLoaded_SquelchManager)
		{
			#if defined _squelch_manager_included
			
			// Set who can hear iClient.
			if(bIsClientJoiningCT)
				SetListenOverride(iPlayer, iClient, Listen_Yes);
			else
				SquelchManager_ReapplyListeningState(iPlayer, iClient, false);
			
			// Set who iClient can hear.
			if(GetClientTeam(iPlayer) == TEAM_GUARDS)
				SetListenOverride(iClient, iPlayer, Listen_Yes);
			else
				SquelchManager_ReapplyListeningState(iClient, iPlayer, false);
			
			#else
			
			if(bIsClientJoiningCT)
			{
				// Suppress warning if define check failed.
			}
			
			#endif
		}
	}
}

SetWhoCanHearGuardOnSpawnAndDeath(iGuard)
{
	if(GetClientTeam(iGuard) != TEAM_GUARDS)
		return;
	
	new bool:bIsGuardAlive = IsPlayerAlive(iGuard);
	
	for(new iPlayer=1; iPlayer<=MaxClients; iPlayer++)
	{
		if(iPlayer == iGuard)
			continue;
		
		if(!IsClientInGame(iPlayer) || IsFakeClient(iPlayer))
			continue;
		
		if(g_bLibLoaded_SquelchManager)
		{
			#if defined _squelch_manager_included
			
			if(bIsGuardAlive)
				SetListenOverride(iPlayer, iGuard, Listen_Yes);
			else
				SquelchManager_ReapplyListeningState(iPlayer, iGuard, false);
			
			#else
			
			if(bIsGuardAlive)
			{
				// Suppress warning if define check failed.
			}
			
			#endif
		}
	}
}

public Event_PlayerDeath_Post(Handle:hEvent, const String:szName[], bool:bDontBroadcast)
{
	new iClient = GetClientOfUserId(GetEventInt(hEvent, "userid"));
	UnmuteClient(iClient);
	SetWhoCanHearGuardOnSpawnAndDeath(iClient);
}

public OnClientConnected(iClient)
{
	g_iHookedVoiceTransmit[iClient] = -1;
}

public OnClientPutInServer(iClient)
{
	if(!IsFakeClient(iClient))
		g_iHookedVoiceTransmit[iClient] = DHookEntity(g_hOnVoiceTransmit, true, iClient);
	
	SDKHook(iClient, SDKHook_SpawnPost, OnSpawnPost);
}

public OnClientDisconnect(iClient)
{
	if(g_iHookedVoiceTransmit[iClient] != -1)
	{
		DHookRemoveHookID(g_iHookedVoiceTransmit[iClient]);
		g_iHookedVoiceTransmit[iClient] = -1;
	}
}

public OnSpawnPost(iClient)
{
	if(IsClientObserver(iClient) || !IsPlayerAlive(iClient))
		return;
	
	if(g_bLibLoaded_ModelSkinManager)
	{
		#if defined _model_skin_manager_included
		if(MSManager_IsBeingForceRespawned(iClient))
			return;
		#endif
	}
	
	SetWhoCanHearGuardOnSpawnAndDeath(iClient);
}

public MRESReturn:OnVoiceTransmit(iClient, Handle:hReturn)
{
	OnClientVoice(iClient);
}

public OnClientVoice(iClient)
{
	// Return if the client speaking isn't the warden.
	static iWarden;
	iWarden = UltJB_Warden_GetWarden();
	if(!iWarden || iWarden != iClient || !IsPlayerAlive(iWarden) || !g_bWardenMuteActive)
		return;
	
	// Set the time to keep everyone muted after the warden unqueues his mic.
	g_fVoiceHoldTime = GetGameTime() + VOICE_HOLD_TIME;
	
	// If the warden is already speaking just add speak time.
	if(g_bIsWardenSpeaking)
	{
		AddToSpeakTime(iWarden);
		return;
	}
	
	// Initialize the warden speaking.
	SubtractFromSpeakTime();
	WardenStartSpeaking(iWarden);
}

public Action:OnWardenMute(iClient, iArgNum)
{
	if(!iClient)
		return Plugin_Handled;
		
	if(UltJB_Warden_GetWarden() != iClient)
	{
		CPrintToChat(iClient, "{green}[{lightred}SM{green}] {red}You must be warden to use this command.");
		return Plugin_Handled;
	}
	
	if(g_bWardenMuteActive)
	{
		g_bWardenMuteActive = false;
		CPrintToChat(iClient, "{green}[{lightred}SM{green}] {yellow}Warden Mute Powers:{lightred} INACTIVE");
	} 
	else
	{
		g_bWardenMuteActive = true;
		CPrintToChat(iClient, "{green}[{lightred}SM{green}] {yellow}Warden Mute Powers:{lightgreen} ACTIVE");
	}
	
	return Plugin_Handled;
}

AddToSpeakTime(iClient)
{
	static Float:fCurTime;
	fCurTime = GetGameTime();
	
	// Only add half speak time while the players aren't muted.
	if(g_bArePlayersMuted)
		g_fTotalSpeakTime += (fCurTime - g_fLastCheckTime[iClient]);
	else
		g_fTotalSpeakTime += ((fCurTime - g_fLastCheckTime[iClient]) * 0.2);
	
	g_fLastCheckTime[iClient] = fCurTime;
}

SubtractFromSpeakTime()
{
	static Float:fTime;
	fTime = GetGameTime();
	
	g_fTotalSpeakTime -= (fTime - g_fStoppedSpeakingTime);
	g_fStoppedSpeakingTime = fTime;
	
	if(g_fTotalSpeakTime < 0.0)
		g_fTotalSpeakTime = 0.0;
}

public OnGameFrame()
{
	if(!g_bIsWardenSpeaking)
		return;
	
	if(!CanWardenMute())
	{
		// The warden can't mute right now so check to see if we need to unmute everyone.
		if(g_bArePlayersMuted)
		{
			g_bArePlayersMuted = false;
			UnmuteAllClients();
		}
	}
	
	if(GetGameTime() < g_fVoiceHoldTime)
		return;
	
	WardenStopSpeaking();
}

bool:CanWardenMute()
{
	if(g_fTotalSpeakTime < GetMaxSpeakTime())
		return true;
	
	return false;
}

Float:GetMaxSpeakTime()
{
	static Float:fNumPlayers, Float:fPercent, Float:fMaxPlayers;
	fNumPlayers = float(GetTeamClientCount(TEAM_GUARDS) + GetTeamClientCount(TEAM_PRISONERS));
	
	if(fNumPlayers < VOICE_MIN_PLAYERS)
		fNumPlayers = VOICE_MIN_PLAYERS;
	
	fMaxPlayers = float(MaxClients);
	if(fMaxPlayers <= VOICE_MIN_PLAYERS)
		fMaxPlayers = VOICE_MIN_PLAYERS + 1.0;
	
	fPercent = (fNumPlayers - VOICE_MIN_PLAYERS) / (fMaxPlayers - VOICE_MIN_PLAYERS);
	
	return (((VOICE_MAX_SPEAK_TIME - VOICE_MIN_SPEAK_TIME) * fPercent) + VOICE_MIN_SPEAK_TIME);
}

public UltJB_Warden_OnRemoved(iClient)
{
	g_fTotalSpeakTime = 0.0;
	WardenStopSpeaking();
	g_bWardenMuteActive = true;
}

public UltJB_Warden_OnDeath(iClient)
{
	g_bWardenMuteActive = true;
}

WardenStopSpeaking()
{
	g_fStoppedSpeakingTime = GetGameTime();
	g_bIsWardenSpeaking = false;
	UnmuteAllClients();
}

WardenStartSpeaking(iWarden)
{
	g_fLastCheckTime[iWarden] = GetGameTime();
	MuteAliveExcludeWarden(iWarden);
	g_bIsWardenSpeaking = true;
	g_bArePlayersMuted = true;
	
	if(g_hTimer_MuteHUD == INVALID_HANDLE)
		g_hTimer_MuteHUD = CreateTimer(0.1, Timer_MuteHUD, _, TIMER_REPEAT | TIMER_FLAG_NO_MAPCHANGE);
}

public Action:Timer_MuteHUD(Handle:hTimer)
{
	static iWarden;
	iWarden = UltJB_Warden_GetWarden();
	if(!iWarden || !DisplayMuteHUD(iWarden))
	{
		g_hTimer_MuteHUD = INVALID_HANDLE;
		return Plugin_Stop;
	}
	
	return Plugin_Continue;
}

bool:DisplayMuteHUD(iClient)
{
	if(!g_bIsWardenSpeaking)
		SubtractFromSpeakTime();
	
	static iPercent;
	iPercent = 100 - RoundFloat(g_fTotalSpeakTime / GetMaxSpeakTime() * 100.0);
	
	static String:szBuffer[255];
	Format(szBuffer, sizeof(szBuffer), "<font size='24' color='#6FC41A'>Mute power:</font> <font size='24' color='#%s'>%i</font>\n<font size='16' color='#999999'>When you speak you will mute\neveryone while power is above 0.</font>", (iPercent < 1) ? "DE2626" : "26D2DE", iPercent);
	PrintHintText(iClient, szBuffer);
	
	if(iPercent == 100)
		return false;
	
	return true;
}

MuteAliveExcludeWarden(iWarden)
{
	for(new iClient=1; iClient<=MaxClients; iClient++)
	{
		if(iWarden == iClient)
			continue;
		
		if(!IsClientInGame(iClient) || !IsPlayerAlive(iClient))
			continue;
		
		if(CheckCommandAccess(iClient, "sm_ultjb_ignore_wardenmute", ADMFLAG_BAN))
			continue;
		
		SetClientListeningFlags(iClient, GetClientListeningFlags(iClient) | VOICE_MUTED);
	}
}

UnmuteAllClients()
{
	for(new iClient=1; iClient<=MaxClients; iClient++)
	{
		if(!IsClientInGame(iClient))
			continue;
		
		UnmuteClient(iClient);
	}
}

UnmuteClient(iClient)
{
	// Return if the client is supposed to be muted.
	if(BaseComm_IsClientMuted(iClient))
		return;
	
	new iFlags = GetClientListeningFlags(iClient);
	iFlags &= ~VOICE_MUTED;
	SetClientListeningFlags(iClient, iFlags);
}