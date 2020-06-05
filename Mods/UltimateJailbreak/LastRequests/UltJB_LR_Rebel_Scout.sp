#include <sourcemod>
#include <sdktools_functions>
#include "../Includes/ultjb_last_request"
#include "../Includes/ultjb_weapon_selection"

#pragma semicolon 1

new const String:PLUGIN_NAME[] = "[UltJB] LR: Rebel - Scout";
new const String:PLUGIN_VERSION[] = "1.1";

public Plugin:myinfo =
{
	name = PLUGIN_NAME,
	author = "RussianLightning",
	description = "Last Request: Rebel - Scout",
	version = PLUGIN_VERSION,
	url = "www.swoobles.com"
}

#define LR_NAME			"Scout"
#define LR_CATEGORY		"Rebel"
#define LR_DESCRIPTION	""

new const HEALTH_BASE = 200;


public OnPluginStart()
{
	CreateConVar("lr_rebel_scout_ver", PLUGIN_VERSION, PLUGIN_NAME, FCVAR_PLUGIN|FCVAR_SPONLY|FCVAR_NOTIFY|FCVAR_PRINTABLEONLY);
}

public UltJB_LR_OnRegisterReady()
{
	new iLastRequestID = UltJB_LR_RegisterLastRequest(LR_NAME, LR_FLAG_REBEL | LR_FLAG_TEMP_INVINCIBLE | LR_FLAG_NORADAR | LR_FLAG_RANDOM_TELEPORT_LOCATION, OnLastRequestStart, OnLastRequestEnd);
	UltJB_LR_SetLastRequestData(iLastRequestID, LR_CATEGORY, LR_DESCRIPTION);
}

public OnLastRequestStart(iClient)
{
	UltJB_LR_SetClientsHealth(iClient, HEALTH_BASE);
	PrepareWeapons(iClient);
}

public OnLastRequestEnd(iClient, iOpponent)
{
	RestoreWeaponsIfNeeded(iClient);
}

PrepareWeapons(iClient)
{
	UltJB_LR_StripClientsWeapons(iClient, true);
	UltJB_Weapons_GivePlayerWeapon(iClient, _:CSWeapon_KNIFE_T);
	UltJB_Weapons_GivePlayerWeapon(iClient, _:CSWeapon_SSG08);
	
	SetEntProp(iClient, Prop_Send, "m_ArmorValue", 100);
	SetEntProp(iClient, Prop_Send, "m_bHasHelmet", 1);
}

RestoreWeaponsIfNeeded(iClient)
{
	if(!iClient || !IsClientInGame(iClient))
		return;
	
	if(IsPlayerAlive(iClient))
		UltJB_LR_RestoreClientsWeapons(iClient);
}
