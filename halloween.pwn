/*
    Skyline Roleplay - Halloween Night Event (filterscript)

    Features
      - Night mode (forced midnight + fog) while the event is active
      - Collectable pumpkins around the map (respawn after a delay)
      - Rupee payout per pumpkin, 5% chance of a Lucky Pumpkin (x3)
      - Milestone bonuses (10 / 25 / 50 / 100 pumpkins)
      - Live HUD, /pumpkins, /pumpkintop leaderboard
      - Event survives server restarts (end time saved in file)
      - Top 3 grand prizes when the event ends

    Install
      1. Save as  filterscripts/halloween.pwn  and compile to halloween.amx
      2. server.cfg:  filterscripts halloween
      3. Make sure the  scriptfiles  folder exists on the server
      4. In game (admin):  /halloween start
      5. Stand where you want a pumpkin and type  /addpumpkin  (saved to file)

    Commands
      /halloween            - event info
      /halloween start      - admin: start event
      /halloween stop       - admin: stop event and pay winners
      /addpumpkin           - admin: add pumpkin at your position
      /pumpkins             - your pumpkin count
      /pumpkintop           - top 5 collectors
*/

#include <a_samp>

// ---------------------------------------------------------------- settings
#define EVENT_NAME          "Skyline Halloween Night"
#define EVENT_DAYS          7
#define MAX_PUMPKINS        100
#define MAX_SCORES          500
#define PUMPKIN_MODEL       19320       // pumpkin object (use 1274 if your client lacks it)
#define PUMPKIN_RESPAWN_MS  120000      // 2 minutes
#define REWARD_MIN          500         // rupees per pumpkin
#define REWARD_MAX          1500
#define LUCKY_CHANCE        5           // percent
#define NIGHT_HOUR          0
#define NIGHT_WEATHER       9           // foggy
#define PUMPKIN_FILE        "pumpkins.txt"
#define SCORE_FILE          "halloween_scores.txt"

#define COLOR_EVENT         0xFF8C00FF
#define COLOR_ERROR         0xFF4444FF
#define COLOR_WHITE         0xFFFFFFFF

// Milestone rewards (rupees)
new const gMilestone[4]       = {10, 25, 50, 100};
new const gMilestoneReward[4] = {5000, 15000, 40000, 100000};

// Grand prizes (rupees) for 1st / 2nd / 3rd
new const gGrandPrize[3] = {100000, 50000, 25000};

// Used only if pumpkins.txt does not exist yet. Replace with /addpumpkin
new const Float:gDefaultPos[][3] =
{
    {2495.4, -1688.5, 13.8},
    {1481.2, -1747.9, 13.5},
    {1958.9, -1761.0, 13.5},
    {1177.6, -1323.5, 14.0},
    {2065.4, -1700.1, 13.5},
    {1544.0, -1675.6, 13.5},
    {2226.4, -1160.1, 25.8},
    {1832.8, -1682.3, 13.4}
};

// ------------------------------------------------------------------ state
new bool:gEventActive = false;
new bool:gDirty = false;
new gEventEnd = 0;

new gPumpkinCount = 0;
new Float:gPumpkinPos[MAX_PUMPKINS][3];
new gPumpkinPickup[MAX_PUMPKINS];

new gScoreCount = 0;
new gScoreName[MAX_SCORES][MAX_PLAYER_NAME + 1];
new gScoreVal[MAX_SCORES];

new gPlayerScore[MAX_PLAYERS];
new PlayerText:gHud[MAX_PLAYERS];

new gNightTimer = -1;
new gCheckTimer = -1;

forward NightTick();
forward EventCheck();
forward RespawnPumpkin(idx);

// ------------------------------------------------- money (edit if needed)
// If Sindhra.pwn has its own money system, change this one function.
stock GiveRupees(playerid, amount)
{
    GivePlayerMoney(playerid, amount);
    return 1;
}

// Replace with your own admin-level check if you have one.
stock IsEventAdmin(playerid)
{
    return IsPlayerAdmin(playerid);
}

// --------------------------------------------------------------- helpers
stock ParseXYZ(const src[], &Float:x, &Float:y, &Float:z)
{
    new a = strfind(src, " ");
    if (a == -1) return 0;
    new b = strfind(src, " ", false, a + 1);
    if (b == -1) return 0;
    new tmp[32];
    strmid(tmp, src, 0, a, sizeof(tmp));
    x = floatstr(tmp);
    strmid(tmp, src, a + 1, b, sizeof(tmp));
    y = floatstr(tmp);
    strmid(tmp, src, b + 1, strlen(src), sizeof(tmp));
    z = floatstr(tmp);
    return 1;
}

stock TrimLine(line[])
{
    new len = strlen(line);
    while (len > 0 && (line[len - 1] == '\n' || line[len - 1] == '\r'))
    {
        line[len - 1] = '\0';
        len--;
    }
}

stock FindScore(const name[])
{
    for (new i = 0; i < gScoreCount; i++)
    {
        if (!strcmp(gScoreName[i], name, true)) return i;
    }
    return -1;
}

stock GetOrCreateScore(playerid)
{
    if (gPlayerScore[playerid] != -1) return gPlayerScore[playerid];
    new name[MAX_PLAYER_NAME + 1];
    GetPlayerName(playerid, name, sizeof(name));
    new s = FindScore(name);
    if (s == -1)
    {
        if (gScoreCount >= MAX_SCORES) return -1;
        s = gScoreCount++;
        format(gScoreName[s], MAX_PLAYER_NAME + 1, "%s", name);
        gScoreVal[s] = 0;
    }
    gPlayerScore[playerid] = s;
    return s;
}

stock GetPlayerPumpkins(playerid)
{
    if (gPlayerScore[playerid] == -1) return 0;
    return gScoreVal[gPlayerScore[playerid]];
}

// ----------------------------------------------------------- persistence
stock SaveScores()
{
    new File:f = fopen(SCORE_FILE, io_write);
    if (!f) return 0;
    new line[64];
    format(line, sizeof(line), "%d\r\n", gEventActive ? gEventEnd : 0);
    fwrite(f, line);
    for (new i = 0; i < gScoreCount; i++)
    {
        format(line, sizeof(line), "%s %d\r\n", gScoreName[i], gScoreVal[i]);
        fwrite(f, line);
    }
    fclose(f);
    gDirty = false;
    return 1;
}

stock LoadScores()
{
    gScoreCount = 0;
    gEventEnd = 0;
    if (!fexist(SCORE_FILE)) return 0;
    new File:f = fopen(SCORE_FILE, io_read);
    if (!f) return 0;
    new line[96];
    if (fread(f, line))
    {
        TrimLine(line);
        gEventEnd = strval(line);
    }
    while (fread(f, line) && gScoreCount < MAX_SCORES)
    {
        TrimLine(line);
        new sp = strfind(line, " ");
        if (sp < 1) continue;
        strmid(gScoreName[gScoreCount], line, 0, sp, MAX_PLAYER_NAME + 1);
        gScoreVal[gScoreCount] = strval(line[sp + 1]);
        gScoreCount++;
    }
    fclose(f);
    return 1;
}

stock AddPumpkinPos(Float:x, Float:y, Float:z)
{
    if (gPumpkinCount >= MAX_PUMPKINS) return -1;
    new i = gPumpkinCount++;
    gPumpkinPos[i][0] = x;
    gPumpkinPos[i][1] = y;
    gPumpkinPos[i][2] = z;
    gPumpkinPickup[i] = -1;
    return i;
}

stock LoadPumpkins()
{
    gPumpkinCount = 0;
    if (fexist(PUMPKIN_FILE))
    {
        new File:f = fopen(PUMPKIN_FILE, io_read);
        if (f)
        {
            new line[96], Float:x, Float:y, Float:z;
            while (fread(f, line) && gPumpkinCount < MAX_PUMPKINS)
            {
                if (ParseXYZ(line, x, y, z)) AddPumpkinPos(x, y, z);
            }
            fclose(f);
        }
    }
    if (gPumpkinCount == 0)
    {
        for (new i = 0; i < sizeof(gDefaultPos); i++)
        {
            AddPumpkinPos(gDefaultPos[i][0], gDefaultPos[i][1], gDefaultPos[i][2]);
        }
    }
}

stock AppendPumpkinToFile(Float:x, Float:y, Float:z)
{
    new File:f = fopen(PUMPKIN_FILE, io_append);
    if (!f) return 0;
    new line[96];
    format(line, sizeof(line), "%.4f %.4f %.4f\r\n", x, y, z);
    fwrite(f, line);
    fclose(f);
    return 1;
}

// --------------------------------------------------------------- pumpkins
stock SpawnPumpkin(idx)
{
    if (gPumpkinPickup[idx] != -1) return 0;
    gPumpkinPickup[idx] = CreatePickup(PUMPKIN_MODEL, 1,
        gPumpkinPos[idx][0], gPumpkinPos[idx][1], gPumpkinPos[idx][2], 0);
    return 1;
}

stock SpawnAllPumpkins()
{
    for (new i = 0; i < gPumpkinCount; i++) SpawnPumpkin(i);
}

stock DestroyAllPumpkins()
{
    for (new i = 0; i < gPumpkinCount; i++)
    {
        if (gPumpkinPickup[i] != -1)
        {
            DestroyPickup(gPumpkinPickup[i]);
            gPumpkinPickup[i] = -1;
        }
    }
}

public RespawnPumpkin(idx)
{
    if (!gEventActive) return 1;
    if (idx < 0 || idx >= gPumpkinCount) return 1;
    SpawnPumpkin(idx);
    return 1;
}

// -------------------------------------------------------------------- HUD
stock UpdateHud(playerid)
{
    if (!IsPlayerConnected(playerid)) return 0;
    if (!gEventActive)
    {
        PlayerTextDrawHide(playerid, gHud[playerid]);
        return 1;
    }
    new left = gEventEnd - gettime();
    if (left < 0) left = 0;
    new str[96];
    format(str, sizeof(str), "~y~Pumpkins: ~w~%d    ~p~Ends in: ~w~%dd %dh",
        GetPlayerPumpkins(playerid), left / 86400, (left % 86400) / 3600);
    PlayerTextDrawSetString(playerid, gHud[playerid], str);
    PlayerTextDrawShow(playerid, gHud[playerid]);
    return 1;
}

stock CreateHud(playerid)
{
    gHud[playerid] = CreatePlayerTextDraw(playerid, 320.0, 424.0, " ");
    PlayerTextDrawAlignment(playerid, gHud[playerid], 2);
    PlayerTextDrawFont(playerid, gHud[playerid], 1);
    PlayerTextDrawLetterSize(playerid, gHud[playerid], 0.3, 1.3);
    PlayerTextDrawColor(playerid, gHud[playerid], -1);
    PlayerTextDrawSetOutline(playerid, gHud[playerid], 1);
    PlayerTextDrawSetShadow(playerid, gHud[playerid], 0);
}

// -------------------------------------------------------------- night mode
stock ApplyNight(playerid)
{
    SetPlayerTime(playerid, NIGHT_HOUR, 0);
    SetPlayerWeather(playerid, NIGHT_WEATHER);
}

public NightTick()
{
    if (!gEventActive) return 1;
    SetWorldTime(NIGHT_HOUR);
    SetWeather(NIGHT_WEATHER);
    for (new i = 0; i < MAX_PLAYERS; i++)
    {
        if (IsPlayerConnected(i)) ApplyNight(i);
    }
    return 1;
}

stock RestoreDay()
{
    SetWorldTime(12);
    SetWeather(10);
    for (new i = 0; i < MAX_PLAYERS; i++)
    {
        if (!IsPlayerConnected(i)) continue;
        SetPlayerTime(i, 12, 0);
        SetPlayerWeather(i, 10);
    }
}

// -------------------------------------------------------- start / stop
stock StartEvent(bool:resume = false)
{
    if (gEventActive) return 0;
    gEventActive = true;

    if (!resume)
    {
        gEventEnd = gettime() + (EVENT_DAYS * 86400);
        gScoreCount = 0;
        for (new i = 0; i < MAX_PLAYERS; i++) gPlayerScore[i] = -1;
        SaveScores();
    }

    SpawnAllPumpkins();
    if (gNightTimer == -1) gNightTimer = SetTimer("NightTick", 10000, true);
    NightTick();

    for (new i = 0; i < MAX_PLAYERS; i++)
    {
        if (IsPlayerConnected(i)) UpdateHud(i);
    }

    if (!resume)
    {
        SendClientMessageToAll(COLOR_EVENT, "[HALLOWEEN] "EVENT_NAME" has begun! The city is dark... find the pumpkins and earn rupees!");
        SendClientMessageToAll(COLOR_EVENT, "[HALLOWEEN] Use /halloween for info and /pumpkintop for the leaderboard.");
    }
    return 1;
}

stock EndEvent()
{
    if (!gEventActive) return 0;
    gEventActive = false;

    DestroyAllPumpkins();
    if (gNightTimer != -1)
    {
        KillTimer(gNightTimer);
        gNightTimer = -1;
    }
    RestoreDay();

    // Rank all collectors
    new bool:taken[MAX_SCORES];
    new top[3] = {-1, -1, -1};
    for (new r = 0; r < 3; r++)
    {
        new best = -1;
        for (new i = 0; i < gScoreCount; i++)
        {
            if (taken[i] || gScoreVal[i] <= 0) continue;
            if (best == -1 || gScoreVal[i] > gScoreVal[best]) best = i;
        }
        if (best == -1) break;
        taken[best] = true;
        top[r] = best;
    }

    SendClientMessageToAll(COLOR_EVENT, "[HALLOWEEN] The event is over! Thanks for playing. Final results:");
    new str[128];
    for (new r = 0; r < 3; r++)
    {
        if (top[r] == -1) break;
        new s = top[r];
        format(str, sizeof(str), "[HALLOWEEN] #%d  %s - %d pumpkins (prize Rs.%d)",
            r + 1, gScoreName[s], gScoreVal[s], gGrandPrize[r]);
        SendClientMessageToAll(COLOR_EVENT, str);
        print(str);

        // Pay if online right now
        for (new p = 0; p < MAX_PLAYERS; p++)
        {
            if (!IsPlayerConnected(p)) continue;
            new nm[MAX_PLAYER_NAME + 1];
            GetPlayerName(p, nm, sizeof(nm));
            if (!strcmp(nm, gScoreName[s], true))
            {
                GiveRupees(p, gGrandPrize[r]);
                SendClientMessage(p, COLOR_EVENT, "[HALLOWEEN] Your grand prize has been paid. Congratulations!");
            }
        }
    }

    // Full table to server log so admins can pay offline winners
    print("---- Halloween final scores ----");
    for (new i = 0; i < gScoreCount; i++)
    {
        format(str, sizeof(str), "%s: %d", gScoreName[i], gScoreVal[i]);
        print(str);
    }

    SaveScores();
    for (new i = 0; i < MAX_PLAYERS; i++)
    {
        if (IsPlayerConnected(i)) UpdateHud(i);
    }
    return 1;
}

public EventCheck()
{
    if (gEventActive)
    {
        if (gettime() >= gEventEnd)
        {
            EndEvent();
            return 1;
        }
        for (new i = 0; i < MAX_PLAYERS; i++)
        {
            if (IsPlayerConnected(i)) UpdateHud(i);
        }
    }
    if (gDirty) SaveScores();
    return 1;
}

// ------------------------------------------------------------- collecting
stock CollectPumpkin(playerid, idx)
{
    new s = GetOrCreateScore(playerid);
    if (s == -1)
    {
        SendClientMessage(playerid, COLOR_ERROR, "[HALLOWEEN] Score table is full, contact an admin.");
        return 0;
    }

    DestroyPickup(gPumpkinPickup[idx]);
    gPumpkinPickup[idx] = -1;
    SetTimerEx("RespawnPumpkin", PUMPKIN_RESPAWN_MS, false, "i", idx);

    gScoreVal[s]++;
    gDirty = true;

    new reward = REWARD_MIN + random(REWARD_MAX - REWARD_MIN + 1);
    new bool:lucky = (random(100) < LUCKY_CHANCE);
    if (lucky) reward *= 3;
    GiveRupees(playerid, reward);

    new str[128];
    if (lucky)
    {
        format(str, sizeof(str), "[HALLOWEEN] LUCKY PUMPKIN! You found Rs.%d inside! (Total: %d)", reward, gScoreVal[s]);
    }
    else
    {
        format(str, sizeof(str), "[HALLOWEEN] You collected a pumpkin and found Rs.%d. (Total: %d)", reward, gScoreVal[s]);
    }
    SendClientMessage(playerid, COLOR_EVENT, str);

    format(str, sizeof(str), "~y~+Rs.%d", reward);
    GameTextForPlayer(playerid, str, 2000, 3);
    PlayerPlaySound(playerid, 1056, 0.0, 0.0, 0.0);

    // Milestones
    for (new m = 0; m < sizeof(gMilestone); m++)
    {
        if (gScoreVal[s] == gMilestone[m])
        {
            GiveRupees(playerid, gMilestoneReward[m]);
            format(str, sizeof(str), "[HALLOWEEN] MILESTONE! %d pumpkins collected - bonus Rs.%d!",
                gMilestone[m], gMilestoneReward[m]);
            SendClientMessage(playerid, 0xFFD700FF, str);

            new nm[MAX_PLAYER_NAME + 1];
            GetPlayerName(playerid, nm, sizeof(nm));
            format(str, sizeof(str), "[HALLOWEEN] %s has collected %d pumpkins!", nm, gMilestone[m]);
            SendClientMessageToAll(COLOR_EVENT, str);
        }
    }

    UpdateHud(playerid);
    return 1;
}

public OnPlayerPickUpPickup(playerid, pickupid)
{
    if (!gEventActive) return 1;
    for (new i = 0; i < gPumpkinCount; i++)
    {
        if (gPumpkinPickup[i] == pickupid)
        {
            CollectPumpkin(playerid, i);
            return 1;
        }
    }
    return 1;
}

// ----------------------------------------------------------------- hooks
public OnFilterScriptInit()
{
    for (new i = 0; i < MAX_PLAYERS; i++) gPlayerScore[i] = -1;

    LoadPumpkins();
    LoadScores();

    gCheckTimer = SetTimer("EventCheck", 30000, true);

    for (new i = 0; i < MAX_PLAYERS; i++)
    {
        if (IsPlayerConnected(i)) OnPlayerConnect(i);
    }

    // Resume after restart if the event is still running
    if (gEventEnd > gettime()) StartEvent(true);

    print("[Halloween] Filterscript loaded.");
    return 1;
}

public OnFilterScriptExit()
{
    if (gCheckTimer != -1) KillTimer(gCheckTimer);
    if (gNightTimer != -1) KillTimer(gNightTimer);
    DestroyAllPumpkins();
    SaveScores();
    return 1;
}

public OnPlayerConnect(playerid)
{
    gPlayerScore[playerid] = -1;
    new name[MAX_PLAYER_NAME + 1];
    GetPlayerName(playerid, name, sizeof(name));
    gPlayerScore[playerid] = FindScore(name);

    CreateHud(playerid);
    if (gEventActive)
    {
        ApplyNight(playerid);
        UpdateHud(playerid);
        SendClientMessage(playerid, COLOR_EVENT, "[HALLOWEEN] "EVENT_NAME" is running! Type /halloween for details.");
    }
    return 1;
}

public OnPlayerDisconnect(playerid, reason)
{
    gPlayerScore[playerid] = -1;
    return 1;
}

public OnPlayerSpawn(playerid)
{
    if (gEventActive) ApplyNight(playerid);
    return 1;
}

// --------------------------------------------------------------- commands
public OnPlayerCommandText(playerid, cmdtext[])
{
    if (!strcmp(cmdtext, "/halloween start", true))
    {
        if (!IsEventAdmin(playerid)) return SendClientMessage(playerid, COLOR_ERROR, "You are not allowed to use this command."), 1;
        if (gEventActive) return SendClientMessage(playerid, COLOR_ERROR, "The event is already running."), 1;
        StartEvent();
        return 1;
    }

    if (!strcmp(cmdtext, "/halloween stop", true))
    {
        if (!IsEventAdmin(playerid)) return SendClientMessage(playerid, COLOR_ERROR, "You are not allowed to use this command."), 1;
        if (!gEventActive) return SendClientMessage(playerid, COLOR_ERROR, "The event is not running."), 1;
        EndEvent();
        return 1;
    }

    if (!strcmp(cmdtext, "/halloween", true))
    {
        SendClientMessage(playerid, COLOR_EVENT, "---- "EVENT_NAME" ----");
        if (!gEventActive)
        {
            SendClientMessage(playerid, COLOR_WHITE, "The Halloween event is not running right now.");
            return 1;
        }
        SendClientMessage(playerid, COLOR_WHITE, "The city is cursed! Pumpkins are hidden around the map. Walk over them to collect.");
        SendClientMessage(playerid, COLOR_WHITE, "Every pumpkin pays rupees. 5% are Lucky Pumpkins that pay triple.");
        SendClientMessage(playerid, COLOR_WHITE, "Bonuses at 10, 25, 50 and 100 pumpkins. Top 3 collectors win grand prizes.");
        SendClientMessage(playerid, COLOR_WHITE, "Commands: /pumpkins  /pumpkintop");
        return 1;
    }

    if (!strcmp(cmdtext, "/pumpkins", true))
    {
        if (!gEventActive) return SendClientMessage(playerid, COLOR_ERROR, "The Halloween event is not running."), 1;
        new str[64];
        format(str, sizeof(str), "[HALLOWEEN] You have collected %d pumpkins.", GetPlayerPumpkins(playerid));
        SendClientMessage(playerid, COLOR_EVENT, str);
        return 1;
    }

    if (!strcmp(cmdtext, "/pumpkintop", true))
    {
        new bool:taken[MAX_SCORES];
        new str[96];
        SendClientMessage(playerid, COLOR_EVENT, "---- Top Pumpkin Collectors ----");
        for (new r = 0; r < 5; r++)
        {
            new best = -1;
            for (new i = 0; i < gScoreCount; i++)
            {
                if (taken[i] || gScoreVal[i] <= 0) continue;
                if (best == -1 || gScoreVal[i] > gScoreVal[best]) best = i;
            }
            if (best == -1) break;
            taken[best] = true;
            format(str, sizeof(str), "#%d  %s - %d pumpkins", r + 1, gScoreName[best], gScoreVal[best]);
            SendClientMessage(playerid, COLOR_WHITE, str);
        }
        return 1;
    }

    if (!strcmp(cmdtext, "/addpumpkin", true))
    {
        if (!IsEventAdmin(playerid)) return SendClientMessage(playerid, COLOR_ERROR, "You are not allowed to use this command."), 1;
        new Float:x, Float:y, Float:z;
        GetPlayerPos(playerid, x, y, z);
        new i = AddPumpkinPos(x, y, z - 0.5);
        if (i == -1) return SendClientMessage(playerid, COLOR_ERROR, "Pumpkin limit reached (MAX_PUMPKINS)."), 1;
        AppendPumpkinToFile(x, y, z - 0.5);
        if (gEventActive) SpawnPumpkin(i);
        new str[64];
        format(str, sizeof(str), "Pumpkin #%d added at your position.", i + 1);
        SendClientMessage(playerid, COLOR_EVENT, str);
        return 1;
    }

    return 0;
}
