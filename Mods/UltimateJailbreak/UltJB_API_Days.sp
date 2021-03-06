#include <sourcemod>
#include <sdkhooks>
#include <cstrike>
#include <hls_color_chat>
#include <sdktools_functions>
#include <sdktools_entinput>
#include <emitsoundany>
#include "Includes/ultjb_last_request"
#include "Includes/ultjb_days"
#include "Includes/ultjb_warden"
#include "Includes/ultjb_cell_doors"
#include "Includes/ultjb_settings"
#include "Includes/ultjb_logger"
#include "Includes/ultjb_jihad"
#include "Includes/ultjb_weapon_selection"
#include "../../Libraries/PathPoints/path_points"

#undef REQUIRE_PLUGIN
#include "../../Libraries/EntityHooker/entity_hooker"
#define REQUIRE_PLUGIN

#pragma semicolon 1

new const String:PLUGIN_NAME[] = "[UltJB] Days API";
new const String:PLUGIN_VERSION[] = "1.33";

public Plugin:myinfo =
{
	name = PLUGIN_NAME,
	author = "hlstriker",
	description = "The days API for Ultimate Jailbreak.",
	version = PLUGIN_VERSION,
	url = "www.swoobles.com"
}

#define ROUND_DAY_ENABLED	-1
#define INVALID_DAY_INDEX	-1
#define MAX_DAYS	64

new Handle:g_aDays;
new g_iDayIDToIndex[MAX_DAYS+1];
enum _:Day
{
	Day_ID,
	String:Day_Name[DAY_MAX_NAME_LENGTH],
	Handle:Day_ForwardStart,
	Handle:Day_ForwardEnd,
	Handle:Day_ForwardFreezeEnd,
	Day_Flags,
	DayType:Day_Type,
	Day_FreezeTime,
	Day_FreezeTeamBits,
	bool:Day_Enabled,
	bool:Day_AllowFreeForAll
};

new Handle:g_hFwd_OnRegisterReady;
new Handle:g_hFwd_OnStart;
new Handle:g_hFwd_OnWardayStart;
new Handle:g_hFwd_OnWardayFreezeEnd;

new g_iCurrentDayID = 0;
new DayType:g_iCurrentDayType = DAY_TYPE_NONE;

new bool:g_bIsDayInFreeForAll;

new g_iWardenCountForRound;
new Float:g_fWardenSelectedTime;

new Handle:cvar_mp_teammates_are_enemies;
new Handle:cvar_force_allow_override;
new Handle:cvar_select_time;
new Handle:cvar_warday_freeze_time;
new g_iTimerCountdown;

new g_iWardayFreezeTime;
new Handle:g_hTimer_WardayFreeze;

new g_iRoundsAfterDay[DayType];
new Handle:g_aUsedSteamIDs;

new Handle:g_hFwd_OnSpawnPost;
new g_iSpawnedTick[MAXPLAYERS+1];

new bool:g_bInDaysSpawnPostForward[MAXPLAYERS+1];

new g_iOffset_CCSPlayer_m_bSpotted = -1;

#define FFADE_STAYOUT	0x0008
#define FFADE_PURGE		0x0010

new UserMsg:g_msgFade;

new const String:SZ_SOUND_ALARM[] = "sound/survival/rocketalarmclose.wav";

#if defined _entity_hooker_included
new Handle:g_aEntRefsToRemoveOnFFA;
#endif

new bool:g_bStartedAsJihad[MAXPLAYERS+1];

#define GetSpawnedByDay(%1)			GetEntProp(%1, Prop_Send, "m_bIsAutoaimTarget")
#define SetSpawnedByDay(%1,%2)		SetEntProp(%1, Prop_Send, "m_bIsAutoaimTarget", %2)

new bool:g_bIsCheckingPointTemplates;
new Handle:g_aPointTemplateEntities;


public OnPluginStart()
{
	CreateConVar("ultjb_api_days_ver", PLUGIN_VERSION, PLUGIN_NAME, FCVAR_PLUGIN|FCVAR_SPONLY|FCVAR_NOTIFY|FCVAR_PRINTABLEONLY);
	
	cvar_select_time = CreateConVar("ultjb_day_select_time", "15", "The number of seconds a day can be selected after the warden is selected.", _, true, 1.0);
	cvar_warday_freeze_time = CreateConVar("ultjb_warday_freeze_time", "30", "The number of seconds the players should be frozen before warday starts.", _, true, 1.0);
	cvar_force_allow_override = CreateConVar("ultjb_day_force_allow_override", "0", "Set to 1 to allow days every round.", _, true, 0.0, true, 1.0);
	
	g_hFwd_OnSpawnPost = CreateGlobalForward("UltJB_Day_OnSpawnPost", ET_Ignore, Param_Cell);
	
	g_aDays = CreateArray(Day);
	g_hFwd_OnRegisterReady = CreateGlobalForward("UltJB_Day_OnRegisterReady", ET_Ignore);
	g_hFwd_OnStart = CreateGlobalForward("UltJB_Day_OnStart", ET_Ignore, Param_Cell, Param_Cell, Param_Cell);
	g_hFwd_OnWardayStart = CreateGlobalForward("UltJB_Day_OnWardayStart", ET_Ignore, Param_Cell);
	g_hFwd_OnWardayFreezeEnd = CreateGlobalForward("UltJB_Day_OnWardayFreezeEnd", ET_Ignore);
	
	g_aUsedSteamIDs = CreateArray(48);
	
	g_aPointTemplateEntities = CreateArray();
	
	#if defined _entity_hooker_included
	g_aEntRefsToRemoveOnFFA = CreateArray();
	#endif
	
	HookEvent("round_end", Event_RoundEnd_Post, EventHookMode_PostNoCopy);
	HookEvent("cs_match_end_restart", Event_RoundEnd_Post, EventHookMode_PostNoCopy);
	HookEvent("cs_pre_restart", Event_RoundEnd_Post, EventHookMode_PostNoCopy);
	HookEvent("round_start", Event_RoundStart_Post, EventHookMode_PostNoCopy);
	HookEvent("player_death", Event_PlayerDeath_Post, EventHookMode_PostNoCopy);
	
	AddCommandListener(OnWeaponDrop, "drop");
	
	//RegConsoleCmd("sm_d", OnDaysMenu, "Opens the days menu."); - removed because of donator
	RegConsoleCmd("sm_day", OnDaysMenu, "Opens the days menu.");
	RegConsoleCmd("sm_warday", OnDaysMenu_Warday, "Opens the warday menu.");
	RegConsoleCmd("sm_freeday", OnDaysMenu_Freeday, "Opens the freeday menu.");
	RegAdminCmd("sm_de", OnDaysEdit, ADMFLAG_UNBAN, "Edits the day configuration for the current map.");
	RegAdminCmd("sm_daysedit", OnDaysEdit, ADMFLAG_UNBAN, "Edits the day configuration for the current map.");
	
	g_iOffset_CCSPlayer_m_bSpotted = FindSendPropInfo("CCSPlayer", "m_bSpotted");
	
	g_msgFade = GetUserMessageId("Fade");
}

public OnConfigsExecuted()
{
	cvar_mp_teammates_are_enemies = FindConVar("mp_teammates_are_enemies");
	
	/*
	if(cvar_mp_teammates_are_enemies != INVALID_HANDLE)
	{
		new iCvarFlags = GetConVarFlags(cvar_mp_teammates_are_enemies);
		iCvarFlags &= ~FCVAR_NOTIFY;
		SetConVarFlags(cvar_mp_teammates_are_enemies, iCvarFlags);
	}
	*/
}

public OnClientPutInServer(iClient)
{
	SDKHook(iClient, SDKHook_Spawn, OnSpawn);
	SDKHook(iClient, SDKHook_WeaponCanUse, OnWeaponCanUse);
}

public OnEntityCreated(iEnt, const String:szClassName[])
{
	if(g_bIsCheckingPointTemplates)
	{
		// WARNING:	Do not store ent references since we can't get a reference to edictless entities (negative indexes).
		// 			We are retrieving them in the same frame so it shouldn't be an issue.
		PushArrayCell(g_aPointTemplateEntities, iEnt);
		return;
	}
	
	if(strlen(szClassName) < 8)
		return;
	
	if(StrContains(szClassName, "weapon_") == -1)
		return;
	
	if(StrContains(szClassName, "upgrade") != -1)
		return;
	
	if(StrEqual(szClassName[7], "hegrenade")
	|| StrEqual(szClassName[7], "smokegrenade")
	|| StrEqual(szClassName[7], "incgrenade")
	|| StrEqual(szClassName[7], "decoy")
	|| StrEqual(szClassName[7], "molotov")
	|| StrEqual(szClassName[7], "tagrenade")
	|| StrEqual(szClassName[7], "flashbang")
	|| StrEqual(szClassName[7], "apon_manager"))	// Catches game_weapon_manager
		return;
	
	SDKHook(iEnt, SDKHook_ReloadPost, OnWeaponReload);
}

public OnWeaponReload(iWeapon, bool:bSuccess)
{
	if(!bSuccess)
		return;
	
	if(!IsDayInProgress())
		return;
	
	decl eDay[Day];
	GetArrayArray(g_aDays, g_iDayIDToIndex[g_iCurrentDayID], eDay);
	
	new iClient = GetEntPropEnt(iWeapon, Prop_Data, "m_hOwnerEntity");
	if(!(1 <= iClient <= MaxClients))
		return;
	
	switch(GetClientTeam(iClient))
	{
		case TEAM_GUARDS:
		{
			if(eDay[Day_Flags] & DAY_FLAG_GIVE_GUARDS_INFINITE_AMMO)
				GivePlayerAmmo(iClient, 500, GetEntProp(iWeapon, Prop_Data, "m_iPrimaryAmmoType"), true);
		}
		case TEAM_PRISONERS:
		{
			if(eDay[Day_Flags] & DAY_FLAG_GIVE_PRISONERS_INFINITE_AMMO)
				GivePlayerAmmo(iClient, 500, GetEntProp(iWeapon, Prop_Data, "m_iPrimaryAmmoType"), true);
		}
	}
}

public OnSpawn(iClient)
{
	g_iSpawnedTick[iClient] = GetGameTickCount();
}

public UltJB_Settings_OnSpawnPost(iClient)
{
	if(g_iCurrentDayType == DAY_TYPE_NONE)
		return;
	
	if(ShouldHookPostThinkPost())
		SDKHook(iClient, SDKHook_PostThinkPost, OnPostThinkPost);
	
	switch(GetClientTeam(iClient))
	{
		case TEAM_PRISONERS:
		{
			decl eDay[Day];
			GetArrayArray(g_aDays, g_iDayIDToIndex[g_iCurrentDayID], eDay);
			
			if(eDay[Day_Flags] & DAY_FLAG_STRIP_PRISONERS_WEAPONS)
				UltJB_LR_StripClientsWeapons(iClient);
			
			if(g_hTimer_WardayFreeze != INVALID_HANDLE)
				SetEntityMoveType(iClient, MOVETYPE_NONE);
		}
		case TEAM_GUARDS:
		{
			decl eDay[Day];
			GetArrayArray(g_aDays, g_iDayIDToIndex[g_iCurrentDayID], eDay);
			
			if(eDay[Day_Flags] & DAY_FLAG_STRIP_GUARDS_WEAPONS)
				UltJB_LR_StripClientsWeapons(iClient);
		}
	}
	
	if(g_iCurrentDayType != DAY_TYPE_NONE)
		Forward_OnSpawnPost(iClient);
}

Forward_OnSpawnPost(iClient)
{
	g_bInDaysSpawnPostForward[iClient] = true;
	
	new result;
	Call_StartForward(g_hFwd_OnSpawnPost);
	Call_PushCell(iClient);
	Call_Finish(result);
	
	g_bInDaysSpawnPostForward[iClient] = false;
}

public Action:OnWeaponCanUse(iClient, iWeapon)
{
	if(!IsDayInProgress())
		return Plugin_Continue;
	
	if(ShouldBlockWeaponGain(iClient, iWeapon))
		return Plugin_Handled;
	
	// Only call ShouldBlockWeaponPickup if it's a weapon not givin by the plugin.
	if(!UltJB_Weapons_IsGettingItem(iClient) && ShouldBlockWeaponPickup(iWeapon))
	{
		// If this weapon isn't allowed to be picked up, go ahead and kill it so weapons aren't infinitely spawned in some situations.
		AcceptEntityInput(iWeapon, "KillHierarchy");
		return Plugin_Handled;
	}
	
	return Plugin_Continue;
}

public Action:CS_OnBuyCommand(iClient, const String:szWeaponName[])
{
	if(!IsDayInProgress())
		return Plugin_Continue;
	
	if(ShouldBlockWeaponGain(iClient, 0))
		return Plugin_Handled;
	
	if(ShouldBlockWeaponPickup(0))
		return Plugin_Handled;
	
	if(ShouldBlockWeaponBuy())
		return Plugin_Handled;
	
	return Plugin_Continue;
}

bool:ShouldBlockWeaponGain(iClient, iWeapon)
{
	if(!g_bInDaysSpawnPostForward[iClient] && iWeapon > 0 && g_iSpawnedTick[iClient] == GetGameTickCount())
	{
		UltJB_Settings_StripWeaponFromOwner(iWeapon);
		return true;
	}
	
	// Block if frozen.
	if(GetEntityMoveType(iClient) == MOVETYPE_NONE)
		return true;
	
	return false;
}

bool:ShouldBlockWeaponPickup(iWeapon)
{
	static eDay[Day];
	GetArrayArray(g_aDays, g_iDayIDToIndex[g_iCurrentDayID], eDay);
	
	if(eDay[Day_Flags] & DAY_FLAG_ALLOW_WEAPON_PICKUPS)
		return false;
	
	if((eDay[Day_Flags] & DAY_FLAG_ALLOW_WEAPON_PICKUPS_FROM_DAY) && GetSpawnedByDay(iWeapon))
		return false;
	
	return true;
}

bool:ShouldBlockWeaponBuy()
{
	static eDay[Day];
	GetArrayArray(g_aDays, g_iDayIDToIndex[g_iCurrentDayID], eDay);
	
	if(eDay[Day_Flags] & DAY_FLAG_DISABLE_WEAPON_BUYING)
		return true;
	
	if(g_bIsDayInFreeForAll)
		return true;
	
	return false;
}

public Action:OnWeaponDrop(iClient, const String:szCommand[], iArgCount)
{
	if(!IsClientInGame(iClient))
		return Plugin_Continue;
	
	if(CanDropWeapon())
		return Plugin_Continue;
	
	return Plugin_Handled;
}

public Action:CS_OnCSWeaponDrop(iClient, iWeapon)
{
	if(!IsClientInGame(iClient))
		return Plugin_Continue;
	
	if(CanDropWeapon())
		return Plugin_Continue;
	
	return Plugin_Handled;
}

CanDropWeapon()
{
	if(!IsDayInProgress())
		return true;
	
	decl eDay[Day];
	GetArrayArray(g_aDays, g_iDayIDToIndex[g_iCurrentDayID], eDay);
	
	if(eDay[Day_Flags] & DAY_FLAG_ALLOW_WEAPON_DROPS)
		return true;
	
	return false;
}

public Event_RoundStart_Post(Handle:hEvent, const String:szName[], bool:bDontBroadcast)
{
	g_bIsCheckingPointTemplates = false;
	ClearArray(g_aPointTemplateEntities);
	
	g_iWardenCountForRound = 0;
	
	for(new i=0; i<sizeof(g_iRoundsAfterDay); i++)
	{
		if(g_iRoundsAfterDay[i] == ROUND_DAY_ENABLED)
			continue;
		
		g_iRoundsAfterDay[i]++;
		if(g_iRoundsAfterDay[i] >= 3)
			g_iRoundsAfterDay[i] = ROUND_DAY_ENABLED;
	}
}

public Event_PlayerDeath_Post(Handle:event, const String:name[], bool:bDontBroadcast)
{
	CheckSlayRemainingFreedayPrisoners();
}

CheckSlayRemainingFreedayPrisoners()
{
	decl iClient, iFreeDayClients[MAXPLAYERS];
	new iNumGuards, iNumPrisoners, iNumFreedays;
	
	for(iClient=1; iClient<=MaxClients; iClient++)
	{
		if(!IsClientInGame(iClient) || !IsPlayerAlive(iClient))
			continue;
		
		switch(GetClientTeam(iClient))
		{
			case TEAM_PRISONERS:
			{
				if(UltJB_LR_GetLastRequestFlags(iClient) & LR_FLAG_FREEDAY)
					iFreeDayClients[iNumFreedays++] = iClient;
				
				iNumPrisoners++;
			}
			case TEAM_GUARDS:
			{
				iNumGuards++;
			}
		}
	}
	
	// Return if no prisoner is in a freeday LR.
	if(!iNumFreedays)
		return;
	
	// Return if it's not a FFA and there are still prisoners not in a freeday.
	new iNotInFreeday = iNumPrisoners - iNumFreedays;
	if(!g_bIsDayInFreeForAll && iNotInFreeday > 0)
		return;
	
	// Return if it is a FFA and there are 2 or more total players not in a freeday.
	iNotInFreeday += iNumGuards;
	if(g_bIsDayInFreeForAll && iNotInFreeday >= 2)
		return;
	
	PrintToChatAll("Slaying the remaining prisoners in a freeday.");
	
	for(new i=0; i<iNumFreedays; i++)
		ForcePlayerSuicide(iFreeDayClients[i]);
}

public Action:OnDaysMenu(iClient, iArgNum)
{
	if(!iClient)
		return Plugin_Handled;
	
	if(!CanUseDayMenu(iClient))
		return Plugin_Handled;
	
	DisplayMenu_DayTypeSelect(iClient);
	
	return Plugin_Handled;
}

public Action:OnDaysMenu_Warday(iClient, iArgNum)
{
	if(!iClient)
		return Plugin_Handled;
	
	if(!CanUseDayMenu(iClient))
		return Plugin_Handled;
	
	if(!CanSelectWarday(iClient))
		return Plugin_Handled;
	
	DisplayMenu_DaySelect(iClient, DAY_TYPE_WARDAY);
	
	return Plugin_Handled;
}

public Action:OnDaysMenu_Freeday(iClient, iArgNum)
{
	if(!iClient)
		return Plugin_Handled;
	
	if(!CanUseDayMenu(iClient))
		return Plugin_Handled;
	
	if(!CanSelectFreeday(iClient))
		return Plugin_Handled;
	
	DisplayMenu_DaySelect(iClient, DAY_TYPE_FREEDAY);
	
	return Plugin_Handled;
}

bool:CanUseDayMenu(iClient)
{
	if(iClient != UltJB_Warden_GetWarden())
	{
		CPrintToChat(iClient, "{green}[{lightred}SM{green}] {olive}You must be the warden to use the days menu.");
		PrintToConsole(iClient, "[SM] You must be the warden to use the days menu.");
		return false;
	}
	
	if(IsDayInProgress())
	{
		CPrintToChat(iClient, "{green}[{lightred}SM{green}] {olive}A day is already in progress.");
		PrintToConsole(iClient, "[SM] A day is already in progress.");
		return false;
	}
	
	if(HasSelectTimeExpired())
	{
		ShowSelectTimeExpiredMessage(iClient);
		return false;
	}
	
	return true;
}

ShowSelectTimeExpiredMessage(iClient)
{
	CPrintToChat(iClient, "{green}[{lightred}SM{green}] {olive}The time to select a day has expired.");
	PrintToConsole(iClient, "[SM] The time to select a day has expired.");
}

public UltJB_Warden_OnSelected(iClient)
{
	g_iWardenCountForRound++;
	if(g_iWardenCountForRound != 1)
		return;
	
	g_fWardenSelectedTime = GetGameTime();
}

bool:HasSelectTimeExpired()
{
	if(!UltJB_Warden_GetWarden())
		return true;
	
	if(GetGameTime() > (g_fWardenSelectedTime + GetConVarFloat(cvar_select_time)))
		return true;
	
	return false;
}

public Event_RoundEnd_Post(Handle:hEvent, const String:szName[], bool:bDontBroadcast)
{
	EndDay();
}

public OnMapEnd()
{
	EndDay();
}

public APLRes:AskPluginLoad2(Handle:hMyself, bool:bLate, String:szError[], iErrLen)
{
	RegPluginLibrary("ultjb_days");
	
	CreateNative("UltJB_Day_RegisterDay", _UltJB_Day_RegisterDay);
	CreateNative("UltJB_Day_SetEnabled", _UltJB_Day_SetEnabled);
	CreateNative("UltJB_Day_IsInProgress", _UltJB_Day_IsInProgress);
	CreateNative("UltJB_Day_SetFlags", _UltJB_Day_SetFlags);
	CreateNative("UltJB_Day_SetFreezeTime", _UltJB_Day_SetFreezeTime);
	CreateNative("UltJB_Day_SetFreezeTeams", _UltJB_Day_SetFreezeTeams);
	CreateNative("UltJB_Day_FreezeTimeForceEnd", _UltJB_Day_FreezeTimeForceEnd);
	CreateNative("UltJB_Day_GetFreezeTimeRemaining", _UltJB_Day_GetFreezeTimeRemaining);
	CreateNative("UltJB_Day_GetCurrentDayType", _UltJB_Day_GetCurrentDayType);
	CreateNative("UltJB_Day_GetCurrentDayID", _UltJB_Day_GetCurrentDayID);
	CreateNative("UltJB_Day_AllowFreeForAll", _UltJB_Day_AllowFreeForAll);
	CreateNative("UltJB_Day_IsFreeForAll", _UltJB_Day_IsFreeForAll);
	CreateNative("UltJB_Day_SetEntityAsSpawnedByDay", _UltJB_Day_SetEntityAsSpawnedByDay);
	
	return APLRes_Success;
}

public OnMapStart()
{
	PrecacheSound(SZ_SOUND_ALARM[6]);
	
	ClearArray(g_aUsedSteamIDs);
	
	g_iWardenCountForRound = 0;
	
	decl i;
	for(i=0; i<sizeof(g_iRoundsAfterDay); i++)
		g_iRoundsAfterDay[i] = ROUND_DAY_ENABLED;
	
	for(i=0; i<sizeof(g_iDayIDToIndex); i++)
		g_iDayIDToIndex[i] = INVALID_DAY_INDEX;
	
	decl eDay[Day];
	for(i=0; i<GetArraySize(g_aDays); i++)
	{
		GetArrayArray(g_aDays, i, eDay);
		
		if(eDay[Day_ForwardStart] != INVALID_HANDLE)
			CloseHandle(eDay[Day_ForwardStart]);
		
		if(eDay[Day_ForwardEnd] != INVALID_HANDLE)
			CloseHandle(eDay[Day_ForwardEnd]);
		
		if(eDay[Day_ForwardFreezeEnd] != INVALID_HANDLE)
			CloseHandle(eDay[Day_ForwardFreezeEnd]);
	}
	
	ClearArray(g_aDays);
	
	new result;
	Call_StartForward(g_hFwd_OnRegisterReady);
	Call_Finish(result);
	
	LoadDayConfig();
	SortDaysByName();
}

SortDaysByName()
{
	new iArraySize = GetArraySize(g_aDays);
	decl String:szName[DAY_MAX_NAME_LENGTH], eDay[Day], j, iIndex, iID, iID2;
	
	for(new i=0; i<iArraySize; i++)
	{
		GetArrayArray(g_aDays, i, eDay);
		strcopy(szName, sizeof(szName), eDay[Day_Name]);
		iIndex = 0;
		iID = eDay[Day_ID];
		
		for(j=i+1; j<iArraySize; j++)
		{
			GetArrayArray(g_aDays, j, eDay);
			if(strcmp(szName, eDay[Day_Name], false) < 0)
				continue;
			
			iIndex = j;
			iID2 = eDay[Day_ID];
			strcopy(szName, sizeof(szName), eDay[Day_Name]);
		}
		
		if(!iIndex)
			continue;
		
		SwapArrayItems(g_aDays, i, iIndex);
		
		// We must swap the IDtoIndex too.
		g_iDayIDToIndex[iID] = iIndex;
		g_iDayIDToIndex[iID2] = i;
	}
}

public _UltJB_Day_SetFlags(Handle:hPlugin, iNumParams)
{
	if(iNumParams != 2)
	{
		LogError("Invalid number of parameters.");
		return false;
	}
	
	new iDayID = GetNativeCell(1);
	new iFlags = GetNativeCell(2);
	
	decl eDay[Day];
	for(new i=0; i<GetArraySize(g_aDays); i++)
	{
		GetArrayArray(g_aDays, i, eDay);
		
		if(eDay[Day_ID] != iDayID)
			continue;
		
		eDay[Day_Flags] = iFlags;
		SetArrayArray(g_aDays, i, eDay);
		
		return true;
	}
	
	return false;
}

public _UltJB_Day_SetFreezeTime(Handle:hPlugin, iNumParams)
{
	if(iNumParams != 2)
	{
		LogError("Invalid number of parameters.");
		return false;
	}
	
	new iDayID = GetNativeCell(1);
	new iTime = GetNativeCell(2);
	
	decl eDay[Day];
	for(new i=0; i<GetArraySize(g_aDays); i++)
	{
		GetArrayArray(g_aDays, i, eDay);
		
		if(eDay[Day_ID] != iDayID)
			continue;
		
		eDay[Day_FreezeTime] = iTime;
		SetArrayArray(g_aDays, i, eDay);
		
		return true;
	}
	
	return false;
}

public _UltJB_Day_SetFreezeTeams(Handle:hPlugin, iNumParams)
{
	if(iNumParams != 2)
	{
		LogError("Invalid number of parameters.");
		return false;
	}
	
	new iDayID = GetNativeCell(1);
	
	decl eDay[Day];
	for(new i=0; i<GetArraySize(g_aDays); i++)
	{
		GetArrayArray(g_aDays, i, eDay);
		
		if(eDay[Day_ID] != iDayID)
			continue;
		
		eDay[Day_FreezeTeamBits] = GetNativeCell(2);
		SetArrayArray(g_aDays, i, eDay);
		
		return true;
	}
	
	return false;
}

public _UltJB_Day_IsInProgress(Handle:hPlugin, iNumParams)
{
	if(IsDayInProgress())
		return true;
	
	return false;
}

public _UltJB_Day_GetCurrentDayID(Handle:hPlugin, iNumParams)
{
	return g_iCurrentDayID;
}

public _UltJB_Day_GetCurrentDayType(Handle:hPlugin, iNumParams)
{
	return _:g_iCurrentDayType;
}

public _UltJB_Day_AllowFreeForAll(Handle:hPlugin, iNumParams)
{
	if(iNumParams != 2)
	{
		LogError("Invalid number of parameters.");
		return false;
	}
	
	new iDayID = GetNativeCell(1);
	
	decl eDay[Day];
	GetArrayArray(g_aDays, g_iDayIDToIndex[iDayID], eDay);
	eDay[Day_AllowFreeForAll] = GetNativeCell(2);
	SetArrayArray(g_aDays, g_iDayIDToIndex[iDayID], eDay);
	
	return true;
}

public _UltJB_Day_SetEntityAsSpawnedByDay(Handle:hPlugin, iNumParams)
{
	SetSpawnedByDay(GetNativeCell(1), GetNativeCell(2));
}

public _UltJB_Day_IsFreeForAll(Handle:hPlugin, iNumParams)
{
	return g_bIsDayInFreeForAll;
}

public _UltJB_Day_SetEnabled(Handle:hPlugin, iNumParams)
{
	if(iNumParams != 2)
	{
		LogError("Invalid number of parameters.");
		return false;
	}
	
	new iDayID = GetNativeCell(1);
	
	decl eDay[Day];
	GetArrayArray(g_aDays, g_iDayIDToIndex[iDayID], eDay);
	eDay[Day_Enabled] = GetNativeCell(2);
	SetArrayArray(g_aDays, g_iDayIDToIndex[iDayID], eDay);
	
	return true;
}

public _UltJB_Day_RegisterDay(Handle:hPlugin, iNumParams)
{
	if(iNumParams != 6)
	{
		LogError("Invalid number of parameters.");
		return 0;
	}
	
	new Function:start_callback = GetNativeCell(4);
	if(start_callback == INVALID_FUNCTION)
		return 0;
	
	new iLength;
	if(GetNativeStringLength(1, iLength) != SP_ERROR_NONE)
		return 0;
	
	iLength++;
	decl String:szName[iLength];
	GetNativeString(1, szName, iLength);
	
	decl eDay[Day];
	new iArraySize = GetArraySize(g_aDays);
	
	new DayType:iDayType = GetNativeCell(2);
	
	for(new i=0; i<iArraySize; i++)
	{
		GetArrayArray(g_aDays, i, eDay);
		
		if(eDay[Day_Type] != iDayType)
			continue;
		
		if(StrEqual(szName, eDay[Day_Name], false))
		{
			LogError("Day [%s] is already registered.", szName);
			return 0;
		}
	}
	
	if(iArraySize >= MAX_DAYS)
	{
		LogError("Cannot add [%s]. Please increase MAX_DAYS and recompile.", szName);
		return 0;
	}
	
	eDay[Day_ID] = iArraySize + 1;
	
	eDay[Day_ForwardStart] = CreateForward(ET_Ignore, Param_Cell);
	AddToForward(eDay[Day_ForwardStart], hPlugin, start_callback);
	
	new Function:end_callback = GetNativeCell(5);
	if(end_callback != INVALID_FUNCTION)
	{
		eDay[Day_ForwardEnd] = CreateForward(ET_Ignore, Param_Cell);
		AddToForward(eDay[Day_ForwardEnd], hPlugin, end_callback);
	}
	else
	{
		eDay[Day_ForwardEnd] = INVALID_HANDLE;
	}
	
	new Function:freeze_end_callback = GetNativeCell(6);
	if(freeze_end_callback != INVALID_FUNCTION)
	{
		eDay[Day_ForwardFreezeEnd] = CreateForward(ET_Ignore);
		AddToForward(eDay[Day_ForwardFreezeEnd], hPlugin, freeze_end_callback);
	}
	else
	{
		eDay[Day_ForwardFreezeEnd] = INVALID_HANDLE;
	}
	
	strcopy(eDay[Day_Name], DAY_MAX_NAME_LENGTH, szName);
	eDay[Day_Type] = iDayType;
	eDay[Day_Flags] = GetNativeCell(3);
	eDay[Day_FreezeTime] = GetConVarInt(cvar_warday_freeze_time);
	eDay[Day_FreezeTeamBits] = FREEZE_TEAM_PRISONERS;
	eDay[Day_AllowFreeForAll] = bool:(eDay[Day_Flags] & DAY_FLAG_FORCE_FREE_FOR_ALL);
	eDay[Day_Enabled] = true;
	
	g_iDayIDToIndex[eDay[Day_ID]] = PushArrayArray(g_aDays, eDay);
	
	return eDay[Day_ID];
}

bool:CanDayBeFreeForAll(iDayID)
{
	if(!HasEnoughRebelPointsForFreeForAll())
		return false;
	
	if(g_iDayIDToIndex[iDayID] == INVALID_DAY_INDEX)
		return false;
	
	decl eDay[Day];
	GetArrayArray(g_aDays, g_iDayIDToIndex[iDayID], eDay);
	
	if(eDay[Day_Flags] & DAY_FLAG_FORCE_FREE_FOR_ALL)
		return true;
	
	return eDay[Day_AllowFreeForAll];
}

bool:HasEnoughRebelPointsForFreeForAll()
{
	return (PathPoints_GetPointCount("rebels") >= 90);
}

GetDayFlags(iDayID)
{
	if(g_iDayIDToIndex[iDayID] == INVALID_DAY_INDEX)
		return 0;
	
	decl eDay[Day];
	GetArrayArray(g_aDays, g_iDayIDToIndex[iDayID], eDay);
	
	return eDay[Day_Flags];
}

bool:StartDay(iClient, iDayID, bool:bUseFreeForAll=false)
{
	if(IsDayInProgress())
	{
		PrintToChat(iClient, "[SM] A day is already in progress.");
		return false;
	}
	
	if(g_iDayIDToIndex[iDayID] == INVALID_DAY_INDEX)
		return false;
	
	decl eDay[Day];
	GetArrayArray(g_aDays, g_iDayIDToIndex[iDayID], eDay);
	
	if(!CanDayBeFreeForAll(iDayID))
	{
		if(eDay[Day_Flags] & DAY_FLAG_FORCE_FREE_FOR_ALL)
		{
			PrintToChat(iClient, "[SM] WARNING: This day is a forced free-for-all, but it can't load probably due to not enough rebel points.");
			return false;
		}
		
		if(bUseFreeForAll)
		{
			PrintToChat(iClient, "[SM] WARNING: This day tried to be free-for-all but it isn't allowed to be.");
			bUseFreeForAll = false;
		}
	}
	
	if(UltJB_CellDoors_HaveOpened() && eDay[Day_Type] == DAY_TYPE_WARDAY)
	{
		PrintToChat(iClient, "[SM] Cells are open, you cannot do a warday.");
		return false;
	}
	
	decl String:szDayType[9];
	DayTypeToName(_:eDay[Day_Type], szDayType, sizeof(szDayType));
	CPrintToChatAll("{green}[{lightred}SM{green}] {lightred}%N {olive}has started {lightred}%s {olive}- {lightred}%s{olive}.", iClient, szDayType, eDay[Day_Name]);
	
	g_iCurrentDayID = iDayID;
	g_iCurrentDayType = eDay[Day_Type];
	g_iRoundsAfterDay[eDay[Day_Type]] = 0;
	
	g_bIsDayInFreeForAll = bUseFreeForAll;
	
	if(bUseFreeForAll)
	{
		if(cvar_mp_teammates_are_enemies != INVALID_HANDLE)
			SetConVarBool(cvar_mp_teammates_are_enemies, true, true);
		
		CPrintToChatAll("{red}WARNING: {lightred}Free for all activated. Kill teammates too!");
		
		EmitSoundToAll(SZ_SOUND_ALARM[6], _, _, SNDLEVEL_NONE);
	}
	
	new bool:bHookPostThink = ShouldHookPostThinkPost();
	
	for(new iPlayer=1; iPlayer<=MaxClients; iPlayer++)
	{
		if(!IsClientInGame(iPlayer))
			continue;
		
		if(!IsPlayerAlive(iPlayer) && GetClientTeam(iPlayer) >= TEAM_PRISONERS)
			CS_RespawnPlayer(iPlayer);
		
		if(bHookPostThink)
			SDKHook(iPlayer, SDKHook_PostThinkPost, OnPostThinkPost);
		
		UltJB_LR_SetClientsHealth(iPlayer, GetEntProp(iPlayer, Prop_Data, "m_iMaxHealth"));
		SetEntProp(iPlayer, Prop_Send, "m_ArmorValue", 0);
		SetEntProp(iPlayer, Prop_Send, "m_bHasHelmet", 0);
		
		g_bStartedAsJihad[iPlayer] = UltJB_Jihad_IsJihad(iPlayer);
		UltJB_Jihad_ClearJihad(iPlayer);
	}
	
	Call_StartForward(eDay[Day_ForwardStart]);
	Call_PushCell(iClient);
	
	new result;
	if(Call_Finish(result) != SP_ERROR_NONE)
	{
		PrintToChat(iClient, "[SM] There was an error loading this day.");
		EndDay();
		return false;
	}
	
	Forward_OnStart(iClient, eDay[Day_Type], bUseFreeForAll);
	InitDayType(iClient, eDay);
	SetDayUsed(iClient);
	
	decl String:szMessage[256];
	Format(szMessage, sizeof(szMessage), "%N has started %s - %s.", iClient, szDayType, eDay[Day_Name]);
	UltJB_Logger_LogEvent(szMessage, iClient, 0, LOGTYPE_ANY);
	
	return true;
}

bool:ShouldHookPostThinkPost()
{
	if(!IsDayInProgress())
		return false;
	
	decl eDay[Day];
	GetArrayArray(g_aDays, g_iDayIDToIndex[g_iCurrentDayID], eDay);
	
	if(eDay[Day_Flags] & DAY_FLAG_DISABLE_PRISONERS_RADAR)
		return true;
	
	if(eDay[Day_Flags] & DAY_FLAG_DISABLE_GUARDS_RADAR)
		return true;
	
	if(g_bIsDayInFreeForAll)
		return true;
	
	return false;
}

public OnPostThinkPost(iClient)
{
	if(!IsDayInProgress())
	{
		SDKUnhook(iClient, SDKHook_PostThinkPost, OnPostThinkPost);
		return;
	}
	
	if(g_bIsDayInFreeForAll)
	{
		RadarUnspot(iClient);
		return;
	}
	
	decl eDay[Day];
	GetArrayArray(g_aDays, g_iDayIDToIndex[g_iCurrentDayID], eDay);
	
	switch(GetClientTeam(iClient))
	{
		case TEAM_GUARDS:
		{
			if(eDay[Day_Flags] & DAY_FLAG_DISABLE_PRISONERS_RADAR)
				RadarUnspot(iClient);
		}
		case TEAM_PRISONERS:
		{
			if(eDay[Day_Flags] & DAY_FLAG_DISABLE_GUARDS_RADAR)
				RadarUnspot(iClient);
		}
	}
}

RadarUnspot(iClient)
{
	SetEntProp(iClient, Prop_Send, "m_bSpotted", 0);
	SetEntProp(iClient, Prop_Send, "m_bSpottedByMask", 0, 4, 0);
	SetEntProp(iClient, Prop_Send, "m_bSpottedByMask", 0, 4, 1);
	
	if(g_iOffset_CCSPlayer_m_bSpotted > 0)
		SetEntData(iClient, g_iOffset_CCSPlayer_m_bSpotted - 4, 0); // m_bCanBeSpotted address = m_bSpotted - 4
}

InitDayType(iClient, const eDay[Day])
{
	if(eDay[Day_Flags] & DAY_FLAG_KILL_WORLD_WEAPONS)
		KillWorldWeapons();
	
	if(eDay[Day_Flags] & DAY_FLAG_STRIP_PRISONERS_WEAPONS)
		StripTeamsWeapons(TEAM_PRISONERS);
	
	if(eDay[Day_Flags] & DAY_FLAG_STRIP_GUARDS_WEAPONS)
		StripTeamsWeapons(TEAM_GUARDS);
	
	if(eDay[Day_Type] == DAY_TYPE_WARDAY)
	{
		new iFreezeTime = g_bIsDayInFreeForAll ? 5 : eDay[Day_FreezeTime];
		new iFreezeTeamBits = g_bIsDayInFreeForAll ? (FREEZE_TEAM_GUARDS | FREEZE_TEAM_PRISONERS) : eDay[Day_FreezeTeamBits];
		InitWarday(iClient, iFreezeTime, eDay[Day_ForwardFreezeEnd], iFreezeTeamBits);
	}
}

DayTypeToName(iDayType, String:szDayType[], iMaxLen)
{
	switch(iDayType)
	{
		case DAY_TYPE_FREEDAY:
		{
			strcopy(szDayType, iMaxLen, "Freeday");
		}
		case DAY_TYPE_WARDAY:
		{
			strcopy(szDayType, iMaxLen, "Warday");
		}
		default:
		{
			strcopy(szDayType, iMaxLen, "ErrorDay");
		}
	}
}

InitWarday(iClient, iFreezeTime, Handle:hForwardFreezeEnd, iFreezeTeamBits)
{
	if(!UltJB_CellDoors_HaveOpened())
		UltJB_CellDoors_ForceOpen();
	
	g_iWardayFreezeTime = iFreezeTime;
	g_iTimerCountdown = 0;
	
	if(iFreezeTeamBits && iFreezeTime > 0)
	{
		FreezePlayers(true, bool:(iFreezeTeamBits & FREEZE_TEAM_PRISONERS), bool:(iFreezeTeamBits & FREEZE_TEAM_GUARDS));
		
		Forward_OnWardayStart(iClient);
		StartTimer_WardayFreeze();
	}
	else
	{
		Forward_OnWardayStart(iClient);
		Forward_FreezeEnd(hForwardFreezeEnd);
	}
	
	if(g_bIsDayInFreeForAll)
	{
		#if defined _entity_hooker_included
		RemoveHookedEntitiesForFFA();
		#endif
		
		TeleportPlayersToFreeForAllPoints();
	}
}

TeleportPlayersToFreeForAllPoints()
{
	new iPointIndex1, iPointIndex2;
	if(!PathPoints_GetFurthestTwoPoints("rebels", iPointIndex1, iPointIndex2))
	{
		EndDay();
		return;
	}
	
	decl Float:fOrigin[3], Float:fAngles[3];
	
	decl iClient;
	new Handle:hClients = CreateArray();
	for(iClient=1; iClient<=MaxClients; iClient++)
	{
		if(!IsClientInGame(iClient) || !IsPlayerAlive(iClient))
			continue;
		
		PushArrayCell(hClients, iClient);
	}
	
	new iNumClientsSet = 0;
	new iNumClientsInArray = GetArraySize(hClients);
	decl iIndex;
	
	while((iNumClientsInArray = GetArraySize(hClients)))
	{
		iIndex = GetRandomInt(0, iNumClientsInArray-1);
		iClient = GetArrayCell(hClients, iIndex);
		RemoveFromArray(hClients, iIndex);
		
		iNumClientsSet++;
		
		switch(iNumClientsSet)
		{
			case 1:
			{
				if(!PathPoints_GetPoint("rebels", iPointIndex1, fOrigin, fAngles))
					continue;
			}
			case 2:
			{
				if(!PathPoints_GetPoint("rebels", iPointIndex2, fOrigin, fAngles))
					continue;
			}
			default:
			{
				if(!PathPoints_GetNextFurthestPoint("rebels", iPointIndex1))
					continue;
				
				if(!PathPoints_GetPoint("rebels", iPointIndex1, fOrigin, fAngles))
					continue;
			}
		}
		
		GetClientEyeAngles(iClient, fAngles);
		fAngles[1] += GetRandomFloat(0.0, 360.0);
		TeleportEntity(iClient, fOrigin, fAngles, Float:{0.0, 0.0, 0.0});
	}
	
	CloseHandle(hClients);
}

bool:DoesPointTemplateContainName(iPointTemplate, const String:szName[])
{
	static String:szString[1024];
	
	GetEntPropString(iPointTemplate, Prop_Data, "m_iszTemplateEntityNames[0]", szString, sizeof(szString));
	if(StrEqual(szName, szString, false))
		return true;
	
	GetEntPropString(iPointTemplate, Prop_Data, "m_iszTemplateEntityNames[1]", szString, sizeof(szString));
	if(StrEqual(szName, szString, false))
		return true;
	
	GetEntPropString(iPointTemplate, Prop_Data, "m_iszTemplateEntityNames[2]", szString, sizeof(szString));
	if(StrEqual(szName, szString, false))
		return true;
	
	GetEntPropString(iPointTemplate, Prop_Data, "m_iszTemplateEntityNames[3]", szString, sizeof(szString));
	if(StrEqual(szName, szString, false))
		return true;
	
	GetEntPropString(iPointTemplate, Prop_Data, "m_iszTemplateEntityNames[4]", szString, sizeof(szString));
	if(StrEqual(szName, szString, false))
		return true;
	
	GetEntPropString(iPointTemplate, Prop_Data, "m_iszTemplateEntityNames[5]", szString, sizeof(szString));
	if(StrEqual(szName, szString, false))
		return true;
	
	GetEntPropString(iPointTemplate, Prop_Data, "m_iszTemplateEntityNames[6]", szString, sizeof(szString));
	if(StrEqual(szName, szString, false))
		return true;
	
	GetEntPropString(iPointTemplate, Prop_Data, "m_iszTemplateEntityNames[7]", szString, sizeof(szString));
	if(StrEqual(szName, szString, false))
		return true;
	
	GetEntPropString(iPointTemplate, Prop_Data, "m_iszTemplateEntityNames[8]", szString, sizeof(szString));
	if(StrEqual(szName, szString, false))
		return true;
	
	GetEntPropString(iPointTemplate, Prop_Data, "m_iszTemplateEntityNames[9]", szString, sizeof(szString));
	if(StrEqual(szName, szString, false))
		return true;
	
	GetEntPropString(iPointTemplate, Prop_Data, "m_iszTemplateEntityNames[10]", szString, sizeof(szString));
	if(StrEqual(szName, szString, false))
		return true;
	
	GetEntPropString(iPointTemplate, Prop_Data, "m_iszTemplateEntityNames[11]", szString, sizeof(szString));
	if(StrEqual(szName, szString, false))
		return true;
	
	GetEntPropString(iPointTemplate, Prop_Data, "m_iszTemplateEntityNames[12]", szString, sizeof(szString));
	if(StrEqual(szName, szString, false))
		return true;
	
	GetEntPropString(iPointTemplate, Prop_Data, "m_iszTemplateEntityNames[13]", szString, sizeof(szString));
	if(StrEqual(szName, szString, false))
		return true;
	
	GetEntPropString(iPointTemplate, Prop_Data, "m_iszTemplateEntityNames[14]", szString, sizeof(szString));
	if(StrEqual(szName, szString, false))
		return true;
	
	GetEntPropString(iPointTemplate, Prop_Data, "m_iszTemplateEntityNames[15]", szString, sizeof(szString));
	if(StrEqual(szName, szString, false))
		return true;
	
	return false;
}

KillWorldWeapons()
{
	// First we need to force spawn all point_template entities so we know they exist, they might spawn a game_player_equip.
	ClearArray(g_aPointTemplateEntities);
	g_bIsCheckingPointTemplates = true;
	
	new iPointTemplate = -1;
	while((iPointTemplate = FindEntityByClassname(iPointTemplate, "point_template")) != -1)
	{
		AcceptEntityInput(iPointTemplate, "ForceSpawn");
	}
	
	g_bIsCheckingPointTemplates = false;
	
	// Kill game_player_equips.
	new iEnt = -1;
	static String:szString[1024];
	while((iEnt = FindEntityByClassname(iEnt, "game_player_equip")) != -1)
	{
		// Before killing the game_player_equip we need to kill any point_templates that might be referencing it as well.
		GetEntPropString(iEnt, Prop_Data, "m_iName", szString, sizeof(szString));
		
		iPointTemplate = -1;
		while((iPointTemplate = FindEntityByClassname(iPointTemplate, "point_template")) != -1)
		{
			if(DoesPointTemplateContainName(iPointTemplate, szString))
			{
				AcceptEntityInput(iPointTemplate, "KillHierarchy");
			}
		}
		
		AcceptEntityInput(iEnt, "KillHierarchy");
	}
	
	// Clean up the force spawned point_template entities.
	new iArraySize = GetArraySize(g_aPointTemplateEntities);
	for(new i=0; i<iArraySize; i++)
	{
		iEnt = GetArrayCell(g_aPointTemplateEntities, i);
		if(iEnt)
			AcceptEntityInput(iEnt, "KillHierarchy");
	}
	
	ClearArray(g_aPointTemplateEntities);
	
	// Kill weapons on the ground.
	new iCount = GetEntityCount();
	for(iEnt=1; iEnt<=iCount; iEnt++)
	{
		if(!IsValidEntity(iEnt))
			continue;
		
		if(!GetEntityClassname(iEnt, szString, sizeof(szString)))
			continue;
		
		szString[7] = '\x0';
		if(!StrEqual(szString, "weapon_"))
			continue;
		
		if(GetEntPropEnt(iEnt, Prop_Data, "m_hOwnerEntity") != -1)
			continue;
		
		AcceptEntityInput(iEnt, "KillHierarchy");
	}
}

StripTeamsWeapons(iTeam)
{
	for(new iClient=1; iClient<=MaxClients; iClient++)
	{
		if(!IsClientInGame(iClient) || !IsPlayerAlive(iClient))
			continue;
		
		if(GetClientTeam(iClient) != iTeam)
			continue;
		
		UltJB_LR_StripClientsWeapons(iClient);
	}
}

StartTimer_WardayFreeze()
{
	g_iTimerCountdown = 0;
	ShowCountdown_Unfreeze();
	
	StopTimer_WardayFreeze();
	g_hTimer_WardayFreeze = CreateTimer(1.0, Timer_WardayFreeze, _, TIMER_REPEAT);
}

public _UltJB_Day_GetFreezeTimeRemaining(Handle:hPlugin, iNumParams)
{
	return (g_iWardayFreezeTime - g_iTimerCountdown);
}

ShowCountdown_Unfreeze()
{
	PrintHintTextToAll("<font color='#6FC41A'>Unfreezing players in:</font>\n<font color='#DE2626'>%i</font> <font color='#6FC41A'>seconds.</font>", g_iWardayFreezeTime - g_iTimerCountdown);
}

StopTimer_WardayFreeze()
{
	if(g_hTimer_WardayFreeze == INVALID_HANDLE)
		return;
	
	KillTimer(g_hTimer_WardayFreeze);
	g_hTimer_WardayFreeze = INVALID_HANDLE;
}

public Action:Timer_WardayFreeze(Handle:hTimer)
{
	g_iTimerCountdown++;
	if(g_iTimerCountdown < g_iWardayFreezeTime)
	{
		ShowCountdown_Unfreeze();
		return Plugin_Continue;
	}
	
	EndFreezeTimer(true);
	return Plugin_Stop;
}

public _UltJB_Day_FreezeTimeForceEnd(Handle:hPlugin, iNumParams)
{
	EndFreezeTimer(false);
}

EndFreezeTimer(bool:bFromTimerFunc)
{
	g_iTimerCountdown = g_iWardayFreezeTime;
	
	if(g_hTimer_WardayFreeze == INVALID_HANDLE)
		return;
	
	if(bFromTimerFunc)
		g_hTimer_WardayFreeze = INVALID_HANDLE;
	else
		StopTimer_WardayFreeze();
	
	FreezePlayers(false);
	
	if(!IsDayInProgress())
		return;
	
	if(g_iDayIDToIndex[g_iCurrentDayID] == INVALID_DAY_INDEX)
		return;
	
	decl eDay[Day];
	GetArrayArray(g_aDays, g_iDayIDToIndex[g_iCurrentDayID], eDay);
	Forward_FreezeEnd(eDay[Day_ForwardFreezeEnd]);
	
	PrintHintTextToAll("<font color='#6FC41A'>Players have been unfrozen!</font>");
}

Forward_FreezeEnd(Handle:hForwardFreezeEnd)
{
	new result;
	if(hForwardFreezeEnd != INVALID_HANDLE)
	{
		Call_StartForward(hForwardFreezeEnd);
		Call_Finish(result);
	}
	
	Call_StartForward(g_hFwd_OnWardayFreezeEnd);
	Call_Finish(result);
}

Forward_OnStart(iClient, DayType:iDayType, bool:bIsFreeForAll)
{
	new result;
	Call_StartForward(g_hFwd_OnStart);
	Call_PushCell(iClient);
	Call_PushCell(iDayType);
	Call_PushCell(bIsFreeForAll);
	Call_Finish(result);
}

Forward_OnWardayStart(iClient)
{
	new result;
	Call_StartForward(g_hFwd_OnWardayStart);
	Call_PushCell(iClient);
	Call_Finish(result);
}

FreezePlayers(bool:bFreeze=true, bool:bTargetPrisoners=true, bool:bTargetGuards=true)
{
	decl iTeam;
	for(new iClient=1; iClient<=MaxClients; iClient++)
	{
		if(!IsClientInGame(iClient) || !IsPlayerAlive(iClient))
			continue;
		
		iTeam = GetClientTeam(iClient);
		
		if((bTargetPrisoners && iTeam == TEAM_PRISONERS)
		|| (bTargetGuards && iTeam == TEAM_GUARDS))
		{
			if(bFreeze)
			{
				FadeScreen(iClient, 0, 0, {0, 0, 0, 255}, FFADE_STAYOUT | FFADE_PURGE);
				SetEntityMoveType(iClient, MOVETYPE_NONE);
			}
			else
			{
				FadeScreen(iClient, 0, 0, {0, 0, 0, 255}, FFADE_PURGE);
				SetEntityMoveType(iClient, MOVETYPE_WALK);
			}
		}
	}
}

bool:EndDay(iClient=0)
{
	if(!IsDayInProgress())
		return false;
	
	if(g_iDayIDToIndex[g_iCurrentDayID] == INVALID_DAY_INDEX)
		return false;
	
	g_bIsCheckingPointTemplates = false;
	ClearArray(g_aPointTemplateEntities);
	
	if(cvar_mp_teammates_are_enemies != INVALID_HANDLE)
		SetConVarBool(cvar_mp_teammates_are_enemies, false, true);
	
	g_iWardayFreezeTime = 0;
	FreezePlayers(false);
	StopTimer_WardayFreeze();
	
	decl eDay[Day];
	GetArrayArray(g_aDays, g_iDayIDToIndex[g_iCurrentDayID], eDay);
	
	if(eDay[Day_ForwardEnd] != INVALID_HANDLE)
	{
		Call_StartForward(eDay[Day_ForwardEnd]);
		Call_PushCell(iClient);
		
		new result;
		if(Call_Finish(result) != SP_ERROR_NONE)
		{
			LogError("There was an error ending day [%s].", eDay[Day_Name]);
			PrintToChatAll("[SM] There was an error ending day [%s].", eDay[Day_Name]);
			return false;
		}
	}
	
	g_iCurrentDayID = 0;
	g_iCurrentDayType = DAY_TYPE_NONE;
	
	for(new iPlayer=1; iPlayer<=MaxClients; iPlayer++)
	{
		if(!IsClientInGame(iPlayer))
			continue;
		
		SDKUnhook(iPlayer, SDKHook_PostThinkPost, OnPostThinkPost);
		
		if(g_iOffset_CCSPlayer_m_bSpotted > 0)
			SetEntData(iPlayer, g_iOffset_CCSPlayer_m_bSpotted - 4, 1); // m_bCanBeSpotted address = m_bSpotted - 4
		
		if(g_bStartedAsJihad[iPlayer])
			UltJB_Jihad_SetJihad(iPlayer);
	}
	
	return true;
}

bool:IsDayInProgress()
{
	if(g_iCurrentDayID > 0)
		return true;
	
	return false;
}

DisplayMenu_DayTypeSelect(iClient)
{
	if(UltJB_Warden_GetWarden() != iClient)
		return;
	
	/*
	if(HasUsedDay(iClient))
	{
		CPrintToChat(iClient, "{green}[{lightred}SM{green}] {olive}You already used your day for this map.");
		PrintToConsole(iClient, "[SM] You already used your day for this map.");
		
		return;
	}
	*/
	
	new Handle:hMenu = CreateMenu(MenuHandle_DayTypeSelect);
	SetMenuTitle(hMenu, "Custom Day");
	
	decl String:szInfo[6];
	
	// Freeday check.
	IntToString(_:DAY_TYPE_FREEDAY, szInfo, sizeof(szInfo));
	if(CanSelectFreeday(iClient))
	{
		AddMenuItem(hMenu, szInfo, "Freeday");
	}
	else
	{
		AddMenuItem(hMenu, szInfo, "Freeday [Wait a round]", ITEMDRAW_DISABLED);
	}
	
	// Warday check.
	IntToString(_:DAY_TYPE_WARDAY, szInfo, sizeof(szInfo));
	if(CanSelectWarday(iClient))
	{
		AddMenuItem(hMenu, szInfo, "Warday");
	}
	else
	{
		AddMenuItem(hMenu, szInfo, "Warday [Wait a round]", ITEMDRAW_DISABLED);
	}
	
	if(!DisplayMenu(hMenu, iClient, 0))
		PrintToChat(iClient, "[SM] There are no day types.");
}

stock bool:HasUsedDay(iClient)
{
	decl String:szAuthID[48];
	if(!GetClientAuthId(iClient, AuthId_Steam2, szAuthID, sizeof(szAuthID), false))
		return true;
	
	if(FindStringInArray(g_aUsedSteamIDs, szAuthID) != -1)
		return true;
	
	return false;
}

SetDayUsed(iClient)
{
	decl String:szAuthID[48];
	if(!GetClientAuthId(iClient, AuthId_Steam2, szAuthID, sizeof(szAuthID), false))
		return;
	
	if(FindStringInArray(g_aUsedSteamIDs, szAuthID) != -1)
		return;
	
	PushArrayString(g_aUsedSteamIDs, szAuthID);
}

bool:CanSelectFreeday(iClient)
{
	if(GetConVarBool(cvar_force_allow_override))
		return true;
	
	if(UltJB_Warden_GetClientWardenCount(iClient) < 2)
		return false;
	
	if(g_iRoundsAfterDay[DAY_TYPE_FREEDAY] != ROUND_DAY_ENABLED || g_iRoundsAfterDay[DAY_TYPE_WARDAY] == 1)
		return false;
	
	return true;
}

bool:CanSelectWarday(iClient)
{
	if(GetConVarBool(cvar_force_allow_override))
		return true;
	
	if(UltJB_Warden_GetClientWardenCount(iClient) < 2)
		return false;
	
	if(g_iRoundsAfterDay[DAY_TYPE_WARDAY] != ROUND_DAY_ENABLED || g_iRoundsAfterDay[DAY_TYPE_FREEDAY] == 1)
		return false;
	
	return true;
}

public MenuHandle_DayTypeSelect(Handle:hMenu, MenuAction:action, iParam1, iParam2)
{
	if(action == MenuAction_End)
	{
		CloseHandle(hMenu);
		return;
	}
	
	if(action != MenuAction_Select)
		return;
	
	if(UltJB_Warden_GetWarden() != iParam1)
		return;
	
	if(HasSelectTimeExpired())
	{
		ShowSelectTimeExpiredMessage(iParam1);
		return;
	}
	
	decl String:szInfo[6];
	GetMenuItem(hMenu, iParam2, szInfo, sizeof(szInfo));
	
	DisplayMenu_DaySelect(iParam1, DayType:StringToInt(szInfo));
}

DisplayMenu_DaySelect(iClient, DayType:iDayType)
{
	if(UltJB_Warden_GetWarden() != iClient)
		return;
	
	new Handle:hMenu = CreateMenu(MenuHandle_DaySelect);
	
	switch(iDayType)
	{
		case DAY_TYPE_WARDAY:
		{
			if(!UltJB_CellDoors_DoExist())
			{
				PrintToChat(iClient, "[SM] Cannot select warday because the cell doors are not set.");
				DisplayMenu_DayTypeSelect(iClient);
				return;
			}
			
			SetMenuTitle(hMenu, "Wardays");
		}
		case DAY_TYPE_FREEDAY: SetMenuTitle(hMenu, "Freedays");
		default: return;
	}
	
	decl eDay[Day], String:szInfo[6], bool:bForcedFFA;
	for(new i=0; i<GetArraySize(g_aDays); i++)
	{
		GetArrayArray(g_aDays, i, eDay);
		
		if(eDay[Day_Type] != iDayType)
			continue;
		
		IntToString(eDay[Day_ID], szInfo, sizeof(szInfo));
		
		bForcedFFA = bool:(eDay[Day_Flags] & DAY_FLAG_FORCE_FREE_FOR_ALL);
		
		if(eDay[Day_Enabled] && (!bForcedFFA || (bForcedFFA && HasEnoughRebelPointsForFreeForAll())))
			AddMenuItem(hMenu, szInfo, eDay[Day_Name]);
		else
			AddMenuItem(hMenu, szInfo, eDay[Day_Name], ITEMDRAW_DISABLED);
	}
	
	SetMenuExitBackButton(hMenu, true);
	if(!DisplayMenu(hMenu, iClient, 0))
	{
		PrintToChat(iClient, "[SM] There are no days.");
		DisplayMenu_DayTypeSelect(iClient);
	}
}

public MenuHandle_DaySelect(Handle:hMenu, MenuAction:action, iParam1, iParam2)
{
	if(action == MenuAction_End)
	{
		CloseHandle(hMenu);
		return;
	}
	
	if(action == MenuAction_Cancel)
	{
		if(iParam2 == MenuCancel_ExitBack)
			DisplayMenu_DayTypeSelect(iParam1);
		
		return;
	}
	
	if(action != MenuAction_Select)
		return;
	
	if(UltJB_Warden_GetWarden() != iParam1)
		return;
	
	if(HasSelectTimeExpired())
	{
		ShowSelectTimeExpiredMessage(iParam1);
		return;
	}
	
	decl String:szInfo[6];
	GetMenuItem(hMenu, iParam2, szInfo, sizeof(szInfo));
	
	new iDayID = StringToInt(szInfo);
	
	new bool:bForceFFA = bool:(GetDayFlags(iDayID) & DAY_FLAG_FORCE_FREE_FOR_ALL);
	if(!bForceFFA && CanDayBeFreeForAll(iDayID))
	{
		DisplayMenu_DaySelectFreeForAll(iParam1, iDayID);
		return;
	}
	
	StartDay(iParam1, iDayID, bForceFFA);
}

DisplayMenu_DaySelectFreeForAll(iClient, iDayID)
{
	if(UltJB_Warden_GetWarden() != iClient)
		return;
	
	new Handle:hMenu = CreateMenu(MenuHandle_DaySelectFreeForAll);
	SetMenuTitle(hMenu, "Select mode");
	
	decl String:szInfo[12];
	FormatEx(szInfo, sizeof(szInfo), "%d/0", iDayID);
	AddMenuItem(hMenu, szInfo, "Team play");
	
	FormatEx(szInfo, sizeof(szInfo), "%d/1", iDayID);
	AddMenuItem(hMenu, szInfo, "Free-for-all");
	
	if(!DisplayMenu(hMenu, iClient, 0))
	{
		PrintToChat(iClient, "[SM] Error showing free for all menu.");
		DisplayMenu_DayTypeSelect(iClient);
	}
}

public MenuHandle_DaySelectFreeForAll(Handle:hMenu, MenuAction:action, iParam1, iParam2)
{
	if(action == MenuAction_End)
	{
		CloseHandle(hMenu);
		return;
	}
	
	if(action != MenuAction_Select)
		return;
	
	if(UltJB_Warden_GetWarden() != iParam1)
		return;
	
	if(HasSelectTimeExpired())
	{
		ShowSelectTimeExpiredMessage(iParam1);
		return;
	}
	
	decl String:szInfo[24];
	GetMenuItem(hMenu, iParam2, szInfo, sizeof(szInfo));
	
	decl String:szExplode[2][12];
	ExplodeString(szInfo, "/", szExplode, sizeof(szExplode), sizeof(szExplode[]));
	
	StartDay(iParam1, StringToInt(szExplode[0]), bool:StringToInt(szExplode[1]));
}

DisplayMenu_EditTypeSelect(iClient)
{
	new Handle:hMenu = CreateMenu(MenuHandle_EditTypeSelect);
	SetMenuTitle(hMenu, "Custom Day");
	
	decl String:szInfo[6];
	
	IntToString(_:DAY_TYPE_FREEDAY, szInfo, sizeof(szInfo));
	AddMenuItem(hMenu, szInfo, "Freeday");
	
	IntToString(_:DAY_TYPE_WARDAY, szInfo, sizeof(szInfo));
	AddMenuItem(hMenu, szInfo, "Warday");
	
	if(!DisplayMenu(hMenu, iClient, 0))
		PrintToChat(iClient, "[SM] There are no day types.");
}

DisplayMenu_EditDay(iClient, DayType:iDayType)
{
	new Handle:hMenu = CreateMenu(MenuHandle_DayEdit);
	
	switch(iDayType)
	{
		case DAY_TYPE_WARDAY: SetMenuTitle(hMenu, "Wardays Allowed");
		case DAY_TYPE_FREEDAY: SetMenuTitle(hMenu, "Freedays Allowed");
		default: return;
	}
	
	decl eDay[Day], String:szInfo[6], String:szLine[512];
	for(new i=0; i<GetArraySize(g_aDays); i++)
	{
		GetArrayArray(g_aDays, i, eDay);
		
		if(eDay[Day_Type] != iDayType)
			continue;
		
		IntToString(eDay[Day_ID], szInfo, sizeof(szInfo));
		Format(szLine, sizeof(szLine), "[%s] %s", (eDay[Day_Enabled] ? "Y" : "N"), eDay[Day_Name]);
		AddMenuItem(hMenu, szInfo, szLine);
	}
	
	SetMenuExitBackButton(hMenu, true);
	if(!DisplayMenu(hMenu, iClient, 0))
	{
		PrintToChat(iClient, "[SM] There are no days.");
		DisplayMenu_EditTypeSelect(iClient);
	}
}

public Action:OnDaysEdit(iClient, iArgNum)
{
	if(!iClient)
		return Plugin_Handled;
	
	DisplayMenu_EditTypeSelect(iClient);
	
	return Plugin_Handled;
}

public MenuHandle_EditTypeSelect(Handle:hMenu, MenuAction:action, iParam1, iParam2)
{
	if(!(1 <= iParam1 <= MaxClients))
		return;
		
	if(action == MenuAction_End)
	{
		CloseHandle(hMenu);
		return;
	}
	
	if(action != MenuAction_Select)
		return;
	
	decl String:szInfo[6];
	GetMenuItem(hMenu, iParam2, szInfo, sizeof(szInfo));
	
	DisplayMenu_EditDay(iParam1, DayType:StringToInt(szInfo));
}

public MenuHandle_DayEdit(Handle:hMenu, MenuAction:action, iParam1, iParam2)
{
	if(!(1 <= iParam1 <= MaxClients))
		return;

	if(action == MenuAction_End)
	{
		CloseHandle(hMenu);
		return;
	}
	
	if(action == MenuAction_Cancel)
	{
		if(iParam2 == MenuCancel_ExitBack)
			DisplayMenu_EditTypeSelect(iParam1);
		
		return;
	}
	
	if(action != MenuAction_Select)
		return;
	
	
	decl String:szInfo[6];
	GetMenuItem(hMenu, iParam2, szInfo, sizeof(szInfo));
	
	decl eDay[Day];
	GetArrayArray(g_aDays, g_iDayIDToIndex[StringToInt(szInfo)], eDay);
	eDay[Day_Enabled] = eDay[Day_Enabled] ? false : true;
	SetArrayArray(g_aDays, g_iDayIDToIndex[StringToInt(szInfo)], eDay);
	
	new String:szMessage[512];
	Format(szMessage, sizeof(szMessage), "[SM] %s %s.", eDay[Day_Name], (eDay[Day_Enabled] ? "enabled" : "disabled"));
	PrintToChat(iParam1, szMessage);
	SaveDayConfig(iParam1);
	DisplayMenu_EditDay(iParam1, eDay[Day_Type]);
}

SaveDayConfig(iClient)
{	
	decl String:szPath[PLATFORM_MAX_PATH];
	BuildPath(Path_SM, szPath, sizeof(szPath), "configs/day_configs");
	if(!DirExists(szPath) && !CreateDirectory(szPath, 775))
	{
		PrintToChat(iClient, "[SM] Error creating day_configs directory.");
		return;
	}
	
	decl String:szBuffer[512];
	GetLowercaseMapName(szBuffer, sizeof(szBuffer));
	Format(szPath, sizeof(szPath), "%s/%s.txt", szPath, szBuffer);
	
	new Handle:fp = OpenFile(szPath, "w");
	if(fp == INVALID_HANDLE)
	{
		PrintToChat(iClient, "[SM] Error creating save file.");
		return;
	}
	
	decl eDay[Day];
	
	for(new i=0; i<=MAX_DAYS; i++)
	{
		GetArrayArray(g_aDays, g_iDayIDToIndex[i], eDay);
		
		if(eDay[Day_Enabled])
			continue;
		
		Format(szBuffer, sizeof(szBuffer), "%d-%s", eDay[Day_Type], eDay[Day_Name]);
		WriteFileLine(fp, szBuffer);
	}
	
	CloseHandle(fp);
	
	PrintToChat(iClient, "[SM] Day configs have been saved.");
}

LoadDayConfig()
{
	new Handle:aNames = CreateArray(DAY_MAX_NAME_LENGTH);
	
	decl String:szBuffer[PLATFORM_MAX_PATH];
	GetLowercaseMapName(szBuffer, sizeof(szBuffer));
	BuildPath(Path_SM, szBuffer, sizeof(szBuffer), "configs/day_configs/%s.txt", szBuffer);
	
	new Handle:fp = OpenFile(szBuffer, "r");
	if(fp == INVALID_HANDLE)
		return;
	
	new iTypes[MAX_DAYS+1], String:szType[2];
	
	while(!IsEndOfFile(fp))
	{
		if(!ReadFileLine(fp, szBuffer, sizeof(szBuffer)))
			continue;
		
		TrimString(szBuffer);
		
		if(strlen(szBuffer) < 1)
			continue;
		
		szType[0] = szBuffer[0];
		PrintToServer("szBuffer (%s), szType (%s), iType (%d)", szBuffer, szType, StringToInt(szType));
		iTypes[GetArraySize(aNames)+1] = StringToInt(szType);
		PrintToServer("Stored name %s", szBuffer[2]);
		PushArrayString(aNames, szBuffer[2]);
	}
	
	CloseHandle(fp);
	
	decl eDay[Day];
	new iMatch;
	
	for(new i=0;i<GetArraySize(g_aDays); i++)
	{
		GetArrayArray(g_aDays, i, eDay);
		PrintToServer("Checking day %s", eDay[Day_Name]);
			
		iMatch = FindStringInArray(aNames, eDay[Day_Name]);
		
		if(iMatch == -1)
			continue;
		
		PrintToServer("Comparing %d to %d", _:eDay[Day_Type], iTypes[iMatch]);
	
		if(_:eDay[Day_Type] != iTypes[iMatch])
			continue;
		
		PrintToServer("--- Disabling day");
		eDay[Day_Enabled] = false;
		SetArrayArray(g_aDays, i, eDay);
	}
}

GetLowercaseMapName(String:szMapName[], iMaxLength)
{
	GetCurrentMap(szMapName, iMaxLength);
	StringToLower(szMapName);
}

StringToLower(String:szString[])
{
	for(new i=0; i<strlen(szString); i++)
		szString[i] = CharToLower(szString[i]);
}

FadeScreen(iClient, iDurationMilliseconds, iHoldMilliseconds, iColor[4], iFlags)
{
	decl iClients[1];
	iClients[0] = iClient;
	
	new Handle:hMessage = StartMessageEx(g_msgFade, iClients, 1);
	
	if(GetUserMessageType() == UM_Protobuf)
	{
		PbSetInt(hMessage, "duration", iDurationMilliseconds);
		PbSetInt(hMessage, "hold_time", iHoldMilliseconds);
		PbSetInt(hMessage, "flags", iFlags);
		PbSetColor(hMessage, "clr", iColor);
	}
	else
	{
		BfWriteShort(hMessage, iDurationMilliseconds);
		BfWriteShort(hMessage, iHoldMilliseconds);
		BfWriteShort(hMessage, iFlags);
		BfWriteByte(hMessage, iColor[0]);
		BfWriteByte(hMessage, iColor[1]);
		BfWriteByte(hMessage, iColor[2]);
		BfWriteByte(hMessage, iColor[3]);
	}
	
	EndMessage();
}


#if defined _entity_hooker_included
public EntityHooker_OnRegisterReady()
{
	EntityHooker_Register(EH_TYPE_JAILBREAK_FFA_REMOVE, "Free-for-all remove entities");
	
	EntityHooker_RegisterAdditional(EH_TYPE_JAILBREAK_FFA_REMOVE,
		"ambient_generic");
	
	EntityHooker_RegisterAdditional(EH_TYPE_JAILBREAK_FFA_REMOVE,
		"env_explosion", "env_fire", "env_laser", "env_spark", "env_soundscape", "env_soundscape_proxy", "env_soundscape_triggerable");
	
	EntityHooker_RegisterAdditional(EH_TYPE_JAILBREAK_FFA_REMOVE,
		"func_breakable", "func_button", "func_door", "func_door_rotating", "func_movelinear", "func_occluder", "func_physbox",
		"func_physbox_multiplayer", "func_rot_button", "func_rotating", "func_tanktrain", "func_tracktrain", "func_wall_toggle", "func_water_analog");
	
	EntityHooker_RegisterAdditional(EH_TYPE_JAILBREAK_FFA_REMOVE,
		"logic_auto", "logic_timer");
	
	EntityHooker_RegisterAdditional(EH_TYPE_JAILBREAK_FFA_REMOVE,
		"prop_door_rotating", "prop_dynamic", "prop_dynamic_override", "prop_physics", "prop_physics_multiplayer");
	
	EntityHooker_RegisterAdditional(EH_TYPE_JAILBREAK_FFA_REMOVE,
		"trigger_brush", "trigger_hurt", "trigger_multiple", "trigger_once", "trigger_push", "trigger_soundscape", "trigger_teleport");
	
	EntityHooker_RegisterProperty(EH_TYPE_JAILBREAK_FFA_REMOVE, Prop_Send, PropField_String, "m_iName");
	EntityHooker_RegisterProperty(EH_TYPE_JAILBREAK_FFA_REMOVE, Prop_Data, PropField_String, "m_target");
	EntityHooker_RegisterProperty(EH_TYPE_JAILBREAK_FFA_REMOVE, Prop_Data, PropField_String, "m_iParent");
}

public EntityHooker_OnInitialHooksPre()
{
	ClearArray(g_aEntRefsToRemoveOnFFA);
}

public EntityHooker_OnEntityHooked(iHookType, iEnt)
{
	if(iHookType != EH_TYPE_JAILBREAK_FFA_REMOVE)
		return;
	
	PushArrayCell(g_aEntRefsToRemoveOnFFA, EntIndexToEntRef(iEnt));
}

RemoveHookedEntitiesForFFA()
{
	new iArraySize = GetArraySize(g_aEntRefsToRemoveOnFFA);
	
	decl iEnt;
	for(new i=0; i<iArraySize; i++)
	{
		iEnt = EntRefToEntIndex(GetArrayCell(g_aEntRefsToRemoveOnFFA, i));
		
		if(iEnt && iEnt != INVALID_ENT_REFERENCE)
			AcceptEntityInput(iEnt, "KillHierarchy");
	}
}
#endif