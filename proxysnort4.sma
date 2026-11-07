#include <amxmodx>
#include <amxmisc>
#include <http>
#include <json>
#include <fakemeta>
#include <hamsandwich>
#include <fun>

#define PLUGIN "ProxySnort"
#define VERSION "4.0.0"
#define AUTHOR "SPiNX"

#define MAX_HUD_ENTRIES 3
#define MAX_PROXY_USERS 6
#define TASK_PROXY_HUD 41001

new g_cvar_token;
new g_cvar_risk_kick;
new g_cvar_troll;
new g_cvar_prune;
new g_hud_sync;
new g_log_path[MAX_RESOURCE_PATH_LENGTH];
new g_ok_path[MAX_RESOURCE_PATH_LENGTH];
new g_whitelist_path[MAX_RESOURCE_PATH_LENGTH];
new g_names[MAX_HUD_ENTRIES][MAX_NAME_LENGTH];
new g_risks[MAX_HUD_ENTRIES];
new g_info[MAX_HUD_ENTRIES][MAX_NAME_LENGTH * 2];
new g_entry_count;

new bool:g_is_proxy[MAX_PLAYERS + 1];
new bool:g_is_checking[MAX_PLAYERS + 1];
new bool:g_half_damage[MAX_PLAYERS + 1];
new bool:g_is_whitelisted[MAX_PLAYERS + 1];
new bool:g_is_in_server[MAX_PLAYERS + 1];
new bool:g_proxy_handled[MAX_PLAYERS + 1];
new bool:g_is_clean_cached[MAX_PLAYERS + 1];
new g_active_troll[MAX_PLAYERS + 1];
new g_http_request[MAX_PLAYERS + 1];
new g_userid[MAX_PLAYERS + 1];
new g_troll_userid[MAX_PLAYERS + 1];
new g_proxy_risk[MAX_PLAYERS + 1];
new g_proxy_cached_time[MAX_PLAYERS + 1];
new g_clean_cached_time[MAX_PLAYERS + 1];
new g_authid[MAX_PLAYERS + 1][MAX_AUTHID_LENGTH];
new g_ip[MAX_PLAYERS + 1][MAX_IP_LENGTH];
new g_name[MAX_PLAYERS + 1][MAX_NAME_LENGTH];
new g_proxy_reason[MAX_PLAYERS + 1][MAX_NAME_LENGTH];
new g_country[MAX_PLAYERS + 1][MAX_NAME_LENGTH];
new g_provider[MAX_PLAYERS + 1][MAX_NAME_LENGTH];
new g_manual_request;
new g_manual_admin;
new g_manual_userid;
new g_manual_ip[MAX_IP_LENGTH];
new g_original_name[MAX_PLAYERS + 1][MAX_NAME_LENGTH];
new g_sound_index;

new const g_alert_sound[] = "buttons/button10.wav";
new g_modname[MAX_NAME_LENGTH];

public plugin_precache()
{
	g_sound_index = precache_sound(g_alert_sound);
}

public plugin_init()
{
	register_plugin(PLUGIN, VERSION, AUTHOR);

	g_cvar_token = register_cvar("sv_proxycheckio-key", "null", FCVAR_PROTECTED | FCVAR_SPONLY);
	g_cvar_risk_kick = register_cvar("ps_risk_kick", "55");
	g_cvar_troll = register_cvar("ps_discombobulate", "1");
	g_cvar_prune = register_cvar("ps_log_prune_days", "7");

	g_hud_sync = CreateHudSyncObj();
	register_clcmd("say /proxies", "cmd_show_proxies");
	register_clcmd("!proxy", "cmd_proxytest", ADMIN_SLAY, "<IPv4 address>");
	register_concmd("amx_proxy_whitelist", "cmd_whitelist_add", ADMIN_RCON, "<name or #userid>");
	register_concmd("amx_proxytest", "cmd_proxytest", ADMIN_RCON, "<IPv4 address>");

	register_forward(FM_ClientUserInfoChanged, "fwd_ClientUserInfoChanged");
	RegisterHam(Ham_TakeDamage, "player", "fwd_TakeDamage");
	RegisterHam(Ham_Spawn, "player", "fwd_PlayerSpawn", 1);

	static config_dir[MAX_RESOURCE_PATH_LENGTH];
	get_configsdir(config_dir, charsmax(config_dir));
	formatex(g_log_path, charsmax(g_log_path), "%s/proxy_logs.json", config_dir);
	formatex(g_ok_path, charsmax(g_ok_path), "%s/proxyfree_logs.json", config_dir);
	formatex(g_whitelist_path, charsmax(g_whitelist_path), "%s/proxy_whitelist.ini", config_dir);
	get_modname(g_modname, charsmax(g_modname));

	set_task(10.0, "display_proxy_hud", TASK_PROXY_HUD, .flags = "b");
}

public client_connect(id)
{
	reset_player_state(id);
}

public client_authorized(id, const authid[])
{
	g_userid[id] = get_user_userid(id);
	copy(g_authid[id], charsmax(g_authid[]), authid);
	get_user_name(id, g_name[id], charsmax(g_name[]));
	copy(g_original_name[id], charsmax(g_original_name[]), g_name[id]);
	get_user_ip(id, g_ip[id], charsmax(g_ip[]), 1);
	g_is_whitelisted[id] = check_file_whitelist(authid);

	if (is_user_bot(id) || equal(authid, "BOT") || g_is_whitelisted[id])
		return;

	new has_proxy_cache = check_proxy_cache(id);
	new has_clean_cache = check_ok_cache(id);
	if (has_proxy_cache && (!has_clean_cache
		|| g_proxy_cached_time[id] > g_clean_cached_time[id]))
	{
		if (!g_is_proxy[id])
			g_is_clean_cached[id] = true;
		return;
	}

	if (has_clean_cache)
	{
		g_is_proxy[id] = false;
		g_is_clean_cached[id] = true;
		server_print("[ProxySnort] %s has a cached clean IP.", g_name[id]);
		return;
	}

	start_proxy_check(id);
	server_print("%s %s by %s checking %N/%s",
		PLUGIN, VERSION, AUTHOR, id, g_ip[id]);
}

public client_putinserver(id)
{
	g_is_in_server[id] = true;
	if (g_is_proxy[id])
		apply_proxy_policy(id);
	else if (g_is_clean_cached[id])
		server_print("[ProxySnort] %s is clean (cached).", g_name[id]);
}

public client_disconnected(id)
{
	remove_task(id);
	reset_player_state(id);
}

reset_player_state(id)
{
	g_is_proxy[id] = false;
	g_is_checking[id] = false;
	g_half_damage[id] = false;
	g_is_whitelisted[id] = false;
	g_is_in_server[id] = false;
	g_proxy_handled[id] = false;
	g_is_clean_cached[id] = false;
	g_active_troll[id] = 0;
	g_http_request[id] = 0;
	g_userid[id] = 0;
	g_troll_userid[id] = 0;
	g_proxy_risk[id] = 0;
	g_proxy_cached_time[id] = 0;
	g_clean_cached_time[id] = 0;
	g_authid[id][0] = 0;
	g_ip[id][0] = 0;
	g_name[id][0] = 0;
	g_proxy_reason[id][0] = 0;
	g_country[id][0] = 0;
	g_provider[id][0] = 0;
	g_original_name[id][0] = 0;
}

start_proxy_check(id)
{
	if (!g_ip[id][0] || equal(g_ip[id], "127.0.0.1") || equal(g_ip[id], "loopback"))
		return;

	static tag[128], url[1024];
	formatex(tag, charsmax(tag), "%s-%s", g_modname, g_authid[id]);
	if (!build_proxy_url(g_ip[id], tag, url, charsmax(url)))
	{
		server_print("[ProxySnort] Could not build request URL; check the API key.");
		return;
	}

	g_is_checking[id] = true;
	g_http_request[id] = http_get(url, "Http_OnComplete", id, 10);
	if (!g_http_request[id])
	{
		g_is_checking[id] = false;
		server_print("[ProxySnort] Could not queue the proxy check for player slot %d.", id);
	}
}

bool:build_proxy_url(const ip[], const tag[], url[], url_max)
{
	static token[128], encoded_token[384], encoded_tag[384];
	get_pcvar_string(g_cvar_token, token, charsmax(token));
	if (!token[0] || equal(token, "null")
		|| !http_urlencode(token, encoded_token, charsmax(encoded_token))
		|| !http_urlencode(tag, encoded_tag, charsmax(encoded_tag)))
		return false;

	formatex(url, url_max,
		"https://proxycheck.io/v2/%s?key=%s&inf=1&vpn=1&risk=2&asn=1&tag=%s",
		ip, encoded_token, encoded_tag);
	return strlen(url) < url_max;
}

public cmd_proxytest(id, level, cid)
{
	if (!cmd_access(id, level, cid, 2))
		return PLUGIN_HANDLED;
	if (g_manual_request)
	{
		console_print(id, "[ProxySnort] Another manual lookup is still pending.");
		return PLUGIN_HANDLED;
	}

	static ip[MAX_IP_LENGTH], tag[MAX_NAME_LENGTH], url[1024];
	read_argv(1, ip, charsmax(ip));
	if (!is_valid_ipv4(ip))
	{
		console_print(id, "[ProxySnort] Enter a valid IPv4 address.");
		return PLUGIN_HANDLED;
	}

	formatex(tag, charsmax(tag), "%s-manual", g_modname);
	if (!build_proxy_url(ip, tag, url, charsmax(url)))
	{
		console_print(id, "[ProxySnort] Could not build request URL; check the API key.");
		return PLUGIN_HANDLED;
	}

	copy(g_manual_ip, charsmax(g_manual_ip), ip);
	g_manual_admin = id;
	g_manual_userid = id ? get_user_userid(id) : 0;
	g_manual_request = http_get(url, "Http_OnComplete", 0, 10);
	if (!g_manual_request)
	{
		clear_manual_request();
		console_print(id, "[ProxySnort] HTTP request was rejected.");
		return PLUGIN_HANDLED;
	}

	console_print(id, "[ProxySnort] Queued IP lookup %d for %s.",
		g_manual_request, ip);
	return PLUGIN_HANDLED;
}

bool:is_valid_ipv4(const ip[])
{
	new octets;
	new digits;
	new value;
	for (new i = 0; ip[i]; i++)
	{
		new ch = ip[i];
		if (ch == '.')
		{
			if (!digits || value > 255 || octets >= 3)
				return false;
			octets++;
			digits = 0;
			value = 0;
			continue;
		}

		if (ch < '0' || ch > '9' || ++digits > 3)
			return false;
		value = value * 10 + (ch - '0');
		if (value > 255)
			return false;
	}

	return octets == 3 && digits > 0;
}

clear_manual_request()
{
	g_manual_request = 0;
	g_manual_admin = 0;
	g_manual_userid = 0;
	g_manual_ip[0] = 0;
}

handle_manual_result(request_id, status, error, const body[])
{
	if (request_id != g_manual_request)
		return;

	new admin = g_manual_admin;
	if (admin > 0 && (admin > MaxClients || !is_user_connected(admin)
		|| get_user_userid(admin) != g_manual_userid))
	{
		clear_manual_request();
		return;
	}

	if (error != 0 || status < 200 || status >= 300)
	{
		console_print(admin, "[ProxySnort] Lookup failed (HTTP %d, curl %d).",
			status, error);
		clear_manual_request();
		return;
	}

	new JSON:root = json_parse(body);
	if (root == Invalid_JSON)
	{
		console_print(admin, "[ProxySnort] Service returned invalid JSON.");
		clear_manual_request();
		return;
	}

	static api_status[16], proxy[8], type[MAX_NAME_LENGTH];
	static country[MAX_NAME_LENGTH], provider[MAX_NAME_LENGTH];
	json_object_get_string(root, "status", api_status, charsmax(api_status));
	new JSON:ip_obj = json_object_get_value(root, g_manual_ip);
	if (!equal(api_status, "ok") || ip_obj == Invalid_JSON)
	{
		console_print(admin, "[ProxySnort] No result for %s (service status: %s).",
			g_manual_ip, api_status);
		if (ip_obj != Invalid_JSON)
			json_free(ip_obj);
		json_free(root);
		clear_manual_request();
		return;
	}

	new risk = json_object_get_number(ip_obj, "risk");
	json_object_get_string(ip_obj, "proxy", proxy, charsmax(proxy));
	json_object_get_string(ip_obj, "type", type, charsmax(type));
	json_object_get_string(ip_obj, "country", country, charsmax(country));
	json_object_get_string(ip_obj, "provider", provider, charsmax(provider));
	if (!provider[0])
		json_object_get_string(ip_obj, "isp", provider, charsmax(provider));

	console_print(admin,
		"[ProxySnort] %s: proxy=%s, risk=%d, type=%s, country=%s, provider=%s",
		g_manual_ip, proxy, risk, type, country, provider);
	json_free(ip_obj);
	json_free(root);
	clear_manual_request();
}

public Http_OnComplete(request_id, status, error, const body[], data)
{
	if (data == 0)
	{
		handle_manual_result(request_id, status, error, body);
		return;
	}

	new id = data;
	if (id < 1 || id > MaxClients || !is_user_connected(id)
		|| request_id != g_http_request[id] || get_user_userid(id) != g_userid[id])
		return;

	g_http_request[id] = 0;
	g_is_checking[id] = false;

	if (error != 0 || status < 200 || status >= 300)
	{
		server_print("[ProxySnort] Proxy check failed for slot %d (HTTP %d, curl %d).",
			id, status, error);
		return;
	}

	new JSON:root = json_parse(body);
	if (root == Invalid_JSON)
	{
		server_print("[ProxySnort] Invalid JSON response for player slot %d.", id);
		return;
	}

	static api_status[16];
	json_object_get_string(root, "status", api_status, charsmax(api_status));
	if (!equal(api_status, "ok"))
	{
		json_free(root);
		server_print("[ProxySnort] Proxy check service returned a non-ok status.");
		return;
	}

	new JSON:ip_obj = json_object_get_value(root, g_ip[id]);
	if (ip_obj == Invalid_JSON)
	{
		json_free(root);
		server_print("[ProxySnort] Proxy check response omitted the player's IP.");
		return;
	}

	new risk_score = json_object_get_number(ip_obj, "risk");
	static proxy[8], reason[MAX_NAME_LENGTH];
	json_object_get_string(ip_obj, "proxy", proxy, charsmax(proxy));
	json_object_get_string(ip_obj, "country", g_country[id], charsmax(g_country[]));
	json_object_get_string(ip_obj, "provider", g_provider[id], charsmax(g_provider[]));
	if (!g_provider[id][0])
		json_object_get_string(ip_obj, "isp", g_provider[id], charsmax(g_provider[]));
	determine_reason(ip_obj, reason, charsmax(reason));

	if (equal(proxy, "yes"))
	{
		if (risk_score >= get_pcvar_num(g_cvar_risk_kick))
		{
			g_is_proxy[id] = true;
			g_proxy_risk[id] = risk_score;
			copy(g_proxy_reason[id], charsmax(g_proxy_reason[]), reason);
			log_to_json(id, risk_score, reason);
		}
		else
		{
			server_print("[ProxySnort] %s is a proxy below the risk threshold.", g_name[id]);
			log_to_cache(id);
			g_is_clean_cached[id] = true;
		}
	}
	else if (equal(proxy, "no"))
	{
		server_print("[ProxySnort] %s has a clean IP.", g_name[id]);
		log_to_cache(id);
		g_is_clean_cached[id] = true;
	}
	else
	{
		server_print("[ProxySnort] Proxy check response omitted the proxy status for %s.",
			g_name[id]);
	}

	json_free(ip_obj);
	json_free(root);

	if (g_is_proxy[id] && g_is_in_server[id])
		apply_proxy_policy(id);
}

determine_reason(JSON:ip_obj, dest[], len)
{
	copy(dest, len, "Proxy/VPN");
	static type[MAX_NAME_LENGTH];
	json_object_get_string(ip_obj, "type", type, charsmax(type));
	if (type[0])
	{
		copy(dest, len, type);
		return;
	}

	new JSON:history = json_object_get_value(ip_obj, "attack history");
	if (history != Invalid_JSON)
	{
		if (json_object_has_value(history, "Vulnerability Probing"))
			copy(dest, len, "Vulnerability");
		else if (json_object_has_value(history, "Login Attempt"))
			copy(dest, len, "Brute Force");
		json_free(history);
	}
}

bool:check_proxy_cache(id)
{
	if (!file_exists(g_log_path))
		return false;

	new JSON:root = read_json_array(g_log_path);
	new cutoff = get_systime() - (get_pcvar_num(g_cvar_prune) * 86400);
	new found;
	static cached_ip[MAX_IP_LENGTH], reason[MAX_NAME_LENGTH];

	for (new i = json_array_get_count(root) - 1; i >= 0; i--)
	{
		new JSON:entry = json_array_get_value(root, i);
		if (json_is_object(entry))
		{
			json_object_get_string(entry, "ip", cached_ip, charsmax(cached_ip));
			json_object_get_string(entry, "reason", reason, charsmax(reason));
			new timestamp = json_object_get_number(entry, "timestamp");
			new risk = json_object_get_number(entry, "risk");
			if (equal(cached_ip, g_ip[id]) && timestamp >= cutoff)
			{
				g_proxy_risk[id] = risk;
				g_proxy_cached_time[id] = timestamp;
				copy(g_proxy_reason[id], charsmax(g_proxy_reason[]), reason);
				json_object_get_string(entry, "country", g_country[id], charsmax(g_country[]));
				json_object_get_string(entry, "provider", g_provider[id], charsmax(g_provider[]));
				g_is_proxy[id] = risk >= get_pcvar_num(g_cvar_risk_kick)
					&& contain(reason, "No Proxy") == -1
					&& contain(reason, "below risk threshold") == -1;
				found = true;
			}
		}
		json_free(entry);
		if (found)
			break;
	}

	json_free(root);
	return found != 0;
}

bool:check_ok_cache(id)
{
	if (!file_exists(g_ok_path))
		return false;

	new JSON:root = read_json_array(g_ok_path);
	new cutoff = get_systime() - (get_pcvar_num(g_cvar_prune) * 86400);
	new found;
	static cached_ip[MAX_IP_LENGTH];

	for (new i = json_array_get_count(root) - 1; i >= 0; i--)
	{
		new JSON:entry = json_array_get_value(root, i);
		if (json_is_object(entry))
		{
			json_object_get_string(entry, "ip", cached_ip, charsmax(cached_ip));
			new timestamp = json_object_get_number(entry, "timestamp");
			if (equal(cached_ip, g_ip[id]) && timestamp >= cutoff)
			{
				found = true;
				g_clean_cached_time[id] = timestamp;
			}
		}
		json_free(entry);
		if (found)
			break;
	}

	json_free(root);
	return found != 0;
}

JSON:read_json_array(const path[])
{
	if (!file_exists(path))
		return json_init_array();

	new JSON:root = json_parse(path, true);
	if (root == Invalid_JSON || !json_is_array(root))
	{
		if (root != Invalid_JSON)
			json_free(root);
		server_print("[ProxySnort] Could not read JSON array: %s", path);
		return json_init_array();
	}
	return root;
}

prune_json_array(JSON:root)
{
	new cutoff = get_systime() - (get_pcvar_num(g_cvar_prune) * 86400);
	for (new i = json_array_get_count(root) - 1; i >= 0; i--)
	{
		new JSON:entry = json_array_get_value(root, i);
		if (!json_is_object(entry)
			|| json_object_get_number(entry, "timestamp") < cutoff)
			json_array_remove(root, i);
		json_free(entry);
	}
	while (json_array_get_count(root) > 100)
	{
		new JSON:entry = json_array_get_value(root, 0);
		json_array_remove(root, 0);
		json_free(entry);
	}
}

log_to_cache(id)
{
	new JSON:root = read_json_array(g_ok_path);
	prune_json_array(root);

	new JSON:entry = json_init_object();
	json_object_set_number(entry, "timestamp", get_systime());
	json_object_set_string(entry, "ip", g_ip[id]);
	json_object_set_string(entry, "proxy", "no");
	json_array_append_value(root, entry);
	json_free(entry);
	prune_json_array(root);

	json_serial_to_file(root, g_ok_path, true);
	json_free(root);
}

apply_proxy_policy(id)
{
	if (!is_user_connected(id) || !g_is_in_server[id] || !g_is_proxy[id]
		|| g_is_whitelisted[id] || g_proxy_handled[id])
		return;

	g_proxy_handled[id] = true;
	if (get_pcvar_num(g_cvar_troll))
		execute_troll(id, g_proxy_risk[id], g_country[id], g_provider[id],
			g_proxy_reason[id]);
	else
		enforce_reserved_slots(id);
}

enforce_reserved_slots(id)
{
	new kick_at = MaxClients - MAX_PROXY_USERS;
	if (kick_at < 1)
		kick_at = 1;

	new current_players = get_playersnum(0);
	if (current_players >= kick_at)
	{
		server_cmd("kick #%d ^"Security Risk: %s (%d%%)^"",
			get_user_userid(id), g_proxy_reason[id], g_proxy_risk[id]);
		return;
	}

	new free_slots = MaxClients - current_players - MAX_PROXY_USERS;
	server_print("Permitting proxy user %N due to %d slots open", id, free_slots);
	client_print(0, print_chat,
		"Permitting proxy user %n due to %d slots open!", id, free_slots);
}

public log_to_json(id, risk, const reason[])
{
	new JSON:root = read_json_array(g_log_path);
	prune_json_array(root);

	new JSON:entry = json_init_object();
	static time_text[32];
	get_time("%m/%d %H:%M", time_text, charsmax(time_text));

	json_object_set_number(entry, "timestamp", get_systime());
	json_object_set_string(entry, "time", time_text);
	json_object_set_string(entry, "user", g_name[id]);
	json_object_set_string(entry, "authid", g_authid[id]);
	json_object_set_string(entry, "ip", g_ip[id]);
	json_object_set_string(entry, "proxy", "yes");
	json_object_set_number(entry, "risk", risk);
	json_object_set_string(entry, "reason", reason);
	json_object_set_string(entry, "country", g_country[id]);
	json_object_set_string(entry, "provider", g_provider[id]);

	json_array_append_value(root, entry);
	json_free(entry);
	prune_json_array(root);
	g_proxy_cached_time[id] = get_systime();

	json_serial_to_file(root, g_log_path, true);
	json_free(root);
	server_print("[%s] Logged and pruned: %s [%d%% risk - %s]",
		PLUGIN, g_name[id], risk, reason);
}

execute_troll(id, risk, const country[], const provider[], const reason[])
{
	if (g_is_whitelisted[id] || !is_user_connected(id))
		return;

	g_is_proxy[id] = true;
	get_user_name(id, g_original_name[id], charsmax(g_original_name[]));
	g_active_troll[id] = random_num(1, 4);
	g_troll_userid[id] = get_user_userid(id);

	for (new i = MAX_HUD_ENTRIES - 1; i > 0; i--)
	{
		copy(g_names[i], charsmax(g_names[]), g_names[i - 1]);
		copy(g_info[i], charsmax(g_info[]), g_info[i - 1]);
		g_risks[i] = g_risks[i - 1];
	}

	copy(g_names[0], charsmax(g_names[]), g_original_name[id]);
	formatex(g_info[0], charsmax(g_info[]), "%s %s (%s)", country, provider, reason);
	g_risks[0] = risk;
	if (g_entry_count < MAX_HUD_ENTRIES)
		g_entry_count++;

	static Float:origin[3];
	pev(id, pev_origin, origin);
	message_begin(MSG_ONE_UNRELIABLE, SVC_SPAWNSTATICSOUND, .player = id);
	write_coord(floatround(origin[0]));
	write_coord(floatround(origin[1]));
	write_coord(floatround(origin[2]));
	write_short(g_sound_index);
	write_byte(255);
	write_byte(60);
	write_byte(0);
	write_byte(64);
	message_end();

	if (g_active_troll[id] == 3)
		g_half_damage[id] = true;
	fwd_PlayerSpawn(id);

	new kick_at = MaxClients - MAX_PROXY_USERS;
	if (kick_at < 1)
		kick_at = 1;
	if (get_playersnum(0) >= kick_at)
	{
		set_task(1.5, "delayed_kick_custom", id);
	}
	else
	{
		new free_slots = MaxClients - get_playersnum(0) - MAX_PROXY_USERS;
		server_print("Permitting proxy user %N due to %d slots open", id, free_slots);
		client_print(0, print_chat,
			"Permitting proxy user %n due to %d slots open!", id, free_slots);
	}
}

public delayed_kick_custom(id)
{
	if (is_user_connected(id) && get_user_userid(id) == g_troll_userid[id])
		server_cmd("kick #%d ^"Security Risk: %s (%d%%)^"",
			g_troll_userid[id], g_proxy_reason[id], g_proxy_risk[id]);
}

bool:check_file_whitelist(const authid[])
{
	if (!file_exists(g_whitelist_path))
		return false;

	static line[MAX_AUTHID_LENGTH + 4];
	new file = fopen(g_whitelist_path, "rt");
	if (!file)
		return false;

	while (!feof(file))
	{
		fgets(file, line, charsmax(line));
		trim(line);
		if (line[0] == ';' || line[0] == '#' || !line[0])
			continue;
		if (equal(authid, line))
		{
			fclose(file);
			return true;
		}
	}

	fclose(file);
	return false;
}

public fwd_PlayerSpawn(id)
{
	if (!is_user_alive(id) || !g_is_proxy[id] || !get_pcvar_num(g_cvar_troll))
		return;

	switch (g_active_troll[id])
	{
		case 1:
		{
			message_begin(MSG_ONE_UNRELIABLE, get_user_msgid("ScreenShake"), {0, 0, 0}, id);
			write_short(1 << 14);
			write_short(1 << 14);
			write_short(1 << 14);
			message_end();
		}
		case 2: set_user_health(id, 50);
		case 4:
		{
			set_pev(id, pev_flags, pev(id, pev_flags) | FL_FROZEN);
			set_user_rendering(id, kRenderFxGlowShell, 255, 0, 0, kRenderNormal, 25);
		}
	}
}

public fwd_ClientUserInfoChanged(id, infobuffer)
{
	if (!g_is_proxy[id] || !get_pcvar_num(g_cvar_troll))
		return FMRES_IGNORED;

	static current_name[MAX_NAME_LENGTH], target_name[MAX_NAME_LENGTH];
	engfunc(EngFunc_InfoKeyValue, infobuffer, "name", current_name, charsmax(current_name));
	formatex(target_name, charsmax(target_name), "PROXY: %s", g_original_name[id]);
	if (!equal(current_name, target_name))
	{
		engfunc(EngFunc_SetClientKeyValue, id, infobuffer, "name", target_name);
		return FMRES_HANDLED;
	}
	return FMRES_IGNORED;
}

public fwd_TakeDamage(victim, inflictor, attacker, Float:damage, damage_bits)
{
	if (is_user_connected(attacker) && g_half_damage[attacker])
	{
		SetHamParamFloat(4, damage * 0.5);
		return HAM_HANDLED;
	}
	return HAM_IGNORED;
}

public cmd_show_proxies(id)
{
	if (!(get_user_flags(id) & ADMIN_KICK) || g_entry_count == 0)
		return PLUGIN_HANDLED;

	for (new i = 0; i < g_entry_count; i++)
		client_print(id, print_chat, "#%d: %s (%d%%) - %s",
			i + 1, g_names[i], g_risks[i], g_info[i]);
	return PLUGIN_HANDLED;
}

public display_proxy_hud()
{
	if (g_entry_count == 0)
		return;

	static hud_text[512];
	new len = formatex(hud_text, charsmax(hud_text), "[ Recent Proxy Blocks ]^n");
	for (new i = 0; i < g_entry_count; i++)
	{
		len += formatex(hud_text[len], charsmax(hud_text) - len, "%s (%d%%) - %s^n",
			g_names[i], g_risks[i], g_info[i]);
	}
	set_hudmessage(150, 150, 150, 0.75, 0.02, 0, 0.0, 10.1, 0.1, 0.1, -1);
	ShowSyncHudMsg(0, g_hud_sync, hud_text);
}

public cmd_whitelist_add(id, level, cid)
{
	if (!cmd_access(id, level, cid, 2))
		return PLUGIN_HANDLED;

	static arg[32];
	read_argv(1, arg, charsmax(arg));
	new target = cmd_target(id, arg, 0);
	if (target)
	{
		static authid[MAX_AUTHID_LENGTH], name[MAX_NAME_LENGTH];
		get_user_authid(target, authid, charsmax(authid));
		get_user_name(target, name, charsmax(name));
		write_file(g_whitelist_path, authid, -1);
		g_is_whitelisted[target] = true;
		console_print(id, "[ProxySnort] Whitelisted %s", name);
	}
	return PLUGIN_HANDLED;
}
