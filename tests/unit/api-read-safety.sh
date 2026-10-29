#!/usr/bin/env bash
# Behavioral matrix: unknown API state never authorizes a dependent write.
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$REPO_ROOT/tests/lib/assert.sh"
scenario_begin api-read-safety
if python3 -I - "$REPO_ROOT" <<'PY'; then
import json, os, pathlib, subprocess, sys, tempfile, unittest
ROOT = pathlib.Path(sys.argv.pop())
CURL = r'''#!/usr/bin/env python3
import json, os, pathlib, re, sys
args=sys.argv[1:]; root=pathlib.Path(os.environ["FIXTURE"])
config=sys.stdin.read() if "-K" in args or "@-" in args else ""
urls=[x for x in args if x.startswith("http")]
match=re.search(r'^url = "(.*)"$', config, re.M)
url=urls[-1] if urls else match[1] if match else ""
path=re.sub(r'^https?://[^/]+', '', url)
method=args[args.index("-X")+1] if "-X" in args else "POST" if any(x.startswith(("-d","--data")) for x in args) or "data-raw =" in config else "GET"
with (root/"requests").open("a") as out: out.write(method+" "+path+"\n")
settings=json.loads((root/"response").read_text())
body,code="{}",200
if path==settings["path"] and method=="GET": body,code=settings["body"],settings["code"]
elif path.endswith("/auth/login"): body="Ok."
elif path.endswith("/api/users/admin/check"): body,code="",204
elif "/indexers/fixture/config" in path: body='[{"id":"fixture","type":"info","value":""}]'
elif path.endswith("/api/users/1/tokens"): body='{"rawAPIKey":"fixture-token"}'
elif path.endswith("/api/auth"): body='{"jwt":"fixture"}'
elif path.endswith("/api/v1/settings/public"): body='{"mediaServerType":2,"initialized":true}'
elif path.endswith("/api/v1/settings/jellyfin"): body='{"apiKey":"fixture"}'
elif path.endswith("/Library/MediaFolders"): body='{"Items":[{"Name":"Movies"},{"Name":"TV Shows"}]}'
elif path.endswith("/api/v1/settings/jellyfin/library/sync"): body='[{"id":"library"}]'
elif path.endswith("/api/v1/settings/main"): body='{"apiKey":"fixture","defaultPermissions":32,"defaultQuotas":{"movie":{"quotaLimit":0},"tv":{"quotaLimit":0}}}'
elif path.endswith("/api/v1/settings/radarr"): body='[]'
elif path.endswith("/customformat"): body='[{"id":1,"name":"x265 (HD)"}]'
elif path.endswith("/api/nginx/certificates"): body='[{"id":1,"domain_names":["jellyfin.fixture.test","seerr.fixture.test"]}]'
elif path.endswith("/qualityprofile"): body='[{"id":1,"name":"Fixture"}]'
elif path.endswith("/languageprofile"): body='[{"id":1}]'
elif path.endswith("/api/v1/settings/sonarr"): body="[]"
elif path.endswith("/api/v2/app/preferences"): body='{"bypass_auth_subnet_whitelist":"","bypass_auth_subnet_whitelist_enabled":false}'
elif path.endswith("/api/client") and method=="POST": body='{"id":"peer","name":"fixture"}'
elif path.endswith("/api/client"): body="[]"
if "-o" in args: pathlib.Path(args[args.index("-o")+1]).write_text(body)
else:
    if any(x in args for x in ("-f","-sf","-fsS")) and code>=400: sys.exit(22)
    sys.stdout.write(body)
if "-w" in args:
    fmt=args[args.index("-w")+1]; sys.stdout.write(fmt.replace("%{http_code}",str(code)).replace(chr(92)+"n",chr(10)))
'''
DRIVER = r'''
set -uo pipefail
REPO_ROOT="$1" ACTION="$2"
SCRIPT_DIR="$FIXTURE/tree"
mkdir -p "$SCRIPT_DIR/config/jackett/Jackett" "$SCRIPT_DIR/config/bazarr/config"
printf '%s' '{"FlareSolverrUrl":"http://fixture:8191","AdminPassword":"already-set"}' >"$SCRIPT_DIR/config/jackett/Jackett/ServerConfig.json"
printf 'auth:\n  apikey: fixture\nsonarr: {}\nradarr: {}\ngeneral: {}\n' >"$SCRIPT_DIR/config/bazarr/config/config.yaml"
source "$REPO_ROOT/scripts/lib/http.sh"
source "$REPO_ROOT/scripts/lib/arr/main.sh"
source "$REPO_ROOT/scripts/lib/npm-remote.sh"
for svc in sonarr radarr jellyfin seerr jackett qbittorrent wireguard portainer bazarr; do source "$REPO_ROOT/scripts/services/$svc/main.sh"; done
sleep(){ :; }
docker(){ printf 'DOCKER %s\n' "$*" >>"$FIXTURE/requests"; return 0; }
env_save_api_key(){ :; }
post_restart_wait(){ :; }
wait_for_service(){ :; }
api_get_key(){ echo fixture; }
api_get_jackett_key(){ echo fixture; }
service_container_running(){ return 0; }
service_local_url(){ echo http://fixture; }
service_internal_url(){ echo http://fixture; }
cfg_indexers(){ echo fixture:general; }
cfg_qbt_categories(){ echo fixture:/data/fixture; }
cfg_jf_libraries(){ echo Movies:movies:/data/movies; }
cfg_quality_ids(){ echo '[1]'; }
cfg_custom_format_scores(){ echo '{"x265 (HD)":30}'; }
cfg_quality_definitions(){ echo '{"Fixture":{"min":1,"preferred":2,"max":3}}'; }
cfg_field(){
 case "$1" in
    quality_profile.name | jellyfin.server_name) echo Fixture ;;
    quality_profile.upgrade_allowed) echo true ;;
    jellyfin.remote_bitrate_limit) echo 10 ;;
    min_free_space_gb) echo 20 ;;
    seerr.quotas.*) echo 0 ;;
    *root_folder | qbittorrent.*path) echo /data/fixture ;;
    *) echo 1 ;;
 esac
}
JELLYFIN_ADMIN_PASSWORD=fixture-password JELLYFIN_ADMIN_USER=fixture NPM_ADMIN_EMAIL=fixture@example.test
JELLYFIN_GPU=nvidia WG_PER_CLIENT_FIREWALL=false MEDIASTACK_NETWORK_PREFIX=172.28.0
case "$ACTION" in
 root) configure_arr_root_folder sonarr http://fixture/api/v3 fixture ;;
 download) configure_arr_download_client sonarr http://fixture/api/v3 fixture tvCategory ;;
 auth) configure_arr_auth sonarr http://fixture/api/v3 fixture ;;
 disk) configure_arr_disk_threshold sonarr http://fixture/api/v3 fixture ;;
 quality) configure_quality_profile sonarr http://fixture/api/v3 fixture '[1]' ;;
 definitions) configure_quality_definitions sonarr http://fixture/api/v3 fixture ;;
 formats) configure_arr_custom_formats sonarr http://fixture/api/v3 fixture ;;
 scores) configure_arr_format_scores sonarr http://fixture/api/v3 fixture ;;
 indexers) configure_arr_indexers sonarr http://fixture/api/v3 fixture 5000 ;;
 sonarr | radarr)
    configure_arr_root_folder(){ :; }; configure_arr_disk_threshold(){ :; }; configure_arr_download_client(){ :; }
    configure_quality_profile(){ :; }; configure_quality_definitions(){ :; }; configure_arr_custom_formats(){ :; }; configure_arr_format_scores(){ :; }; configure_arr_auth(){ :; }
    "configure_$ACTION" ;;
 libraries) configure_jellyfin_libraries http://fixture fixture ;;
 jellyfin-public) configure_jellyfin ;;
 keys) save_jellyfin_api_key http://fixture fixture fixture ;;
 server) configure_jellyfin_server_name http://fixture fixture ;;
 streaming) configure_jellyfin_streaming http://fixture fixture ;;
 encoding) configure_jellyfin_encoding http://fixture fixture ;;
 network) configure_jellyfin_networking http://fixture fixture ;;
 seerr) connect_arr_to_seerr sonarr 8989 http://fixture "$FIXTURE/cookies" ;;
 seerr-public | seerr-main) configure_seerr ;;
 seerr-network) REMOTE_WEB_STATE=ready DOMAIN=fixture.test configure_seerr ;;
 npm-hosts)
    NPM_CERT_WAIT_MAX_POLLS=1 NPM_PROXY_CONF_WAIT_MAX_POLLS=1 NPM_HOST_IDLE_MAX_POLLS=1
    SCRIPT_DIR="$REPO_ROOT" source "$REPO_ROOT/scripts/services/npm/main.sh"
    npm_api=http://fixture/api npm_token=fixture rate_enabled=false rate_burst=1 http_top_created=false
    DOMAIN=fixture.test REMOTE_WEB_STATE=ready NPM_LE_SERVER=https://fixture _npm_configure_publication ;;
 categories) configure_qbittorrent ;;
 jackett) configure_jackett ;;
 bazarr) configure_bazarr ;;
 portainer) configure_portainer ;;
 peers) configure_wireguard ;;
 interface) _wg_ensure_firewall_enabled http://fixture fixture fixture ;;
 peer-ips) _wg_set_peer_firewall_ips http://fixture fixture fixture peer 192.168.1.0/24 ;;
 certificates) npm_remote_api_cert_ids_by_fqdn fixture http://fixture/api jellyfin.fixture ;;
 *) exit 2 ;;
esac
'''
# Each case names the read, valid response and the write it authorizes.
CASES = [
 ("root","/api/v3/rootfolder","[]","POST /api/v3/rootfolder"),
 ("download","/api/v3/downloadclient","[]","POST /api/v3/downloadclient"),
 ("auth","/api/v3/config/host",'{"authenticationMethod":"none"}',"PUT /api/v3/config/host"),
 ("disk","/api/v3/config/mediamanagement",'{"minimumFreeSpaceWhenImporting":100}',"PUT /api/v3/config/mediamanagement"),
 ("sonarr","/api/v3/config/naming",'{"renameEpisodes":false}',"PUT /api/v3/config/naming"),
 ("radarr","/api/v3/config/naming",'{"renameMovies":false}',"PUT /api/v3/config/naming"),
 ("indexers","/api/v3/indexer","[]","POST /api/v3/indexer"),
 ("libraries","/Library/VirtualFolders","[]","POST /Library/VirtualFolders"),
 ("jellyfin-public","/System/Info/Public",'{"StartupWizardCompleted":false}',"POST /Startup/Configuration"),
 ("keys","/Auth/Keys",'{"Items":[]}',"POST /Auth/Keys"),
 ("server","/System/Configuration",'{"ServerName":""}',"POST /System/Configuration"),
 ("streaming","/System/Configuration",'{"RemoteClientBitrateLimit":0}',"POST /System/Configuration"),
 ("encoding","/System/Configuration/encoding",'{"HardwareAccelerationType":"none"}',"POST /System/Configuration/encoding"),
 ("network","/System/Configuration/network",'{"AutoDiscovery":true,"KnownProxies":[],"PublishedServerUriBySubnet":[]}',"POST /System/Configuration/network"),
 ("seerr","/api/v1/settings/sonarr","[]","POST /api/v1/settings/sonarr"),
 ("seerr-public","/api/v1/settings/public",'{"mediaServerType":2,"initialized":true}',"POST /api/v1/auth/jellyfin"),
 ("categories","/api/v2/torrents/categories","{}","POST /api/v2/torrents/createCategory"),
 ("jackett","/api/v2.0/indexers?configured=true&apikey=fixture","[]","POST /api/v2.0/indexers/fixture/config"),
 ("portainer","/api/endpoints","[]","POST /api/endpoints"),
 ("peers","/api/client","[]","POST /api/client"),
 ("interface","/api/admin/interface",'{"firewallEnabled":false}',"POST /api/admin/interface"),
 ("peer-ips","/api/client/peer",'{"firewallIps":[]}',"POST /api/client/peer"),
]
CASES += [
 ("quality","/api/v3/qualityprofile",'[{"id":1,"name":"Default","cutoff":1,"upgradeAllowed":true,"items":[{"quality":{"id":1},"allowed":true}],"formatItems":[]}]',"POST /api/v3/qualityprofile"),
 ("definitions","/api/v3/qualitydefinition",'[{"id":1,"quality":{"name":"Fixture"},"minSize":0}]',"PUT /api/v3/qualitydefinition/1"),
 ("formats","/api/v3/customformat","[]","POST /api/v3/customformat"),
 ("scores","/api/v3/qualityprofile",'[{"id":1,"name":"Fixture","formatItems":[]}]',"PUT /api/v3/qualityprofile/1"),
 ("seerr-network","/api/v1/settings/network",'{"trustProxy":false}',"POST /api/v1/settings/network"),
 ("seerr-main","/api/v1/settings/main",'{"apiKey":"fixture","defaultPermissions":0,"defaultQuotas":{"movie":{},"tv":{}}}',"POST /api/v1/settings/main"),
 ("npm-hosts","/api/nginx/proxy-hosts","[]","POST /api/nginx/proxy-hosts"),
]

class ReadSafety(unittest.TestCase):
    def run_case(self, action, path, body, code=200):
        with tempfile.TemporaryDirectory(prefix="ms-read-safety-") as name:
            folder=pathlib.Path(name); (folder/"bin").mkdir()
            curl=folder/"bin/curl"; curl.write_text(CURL); curl.chmod(0o755)
            (folder/"response").write_text(json.dumps({"path":path,"body":body,"code":code}))
            (folder/"requests").touch()
            result=subprocess.run(["bash","-c",DRIVER,"read-safety",str(ROOT),action],
                env=dict(os.environ,FIXTURE=name,PATH=str(folder/"bin")+os.pathsep+os.environ["PATH"]),
                text=True,capture_output=True,timeout=25)
            requests=(folder/"requests").read_text().splitlines()
            yaml_path=folder/"tree/config/bazarr/config/config.yaml"
            return result, requests, yaml_path.read_text() if yaml_path.exists() else ""

    def test_unknown_reads_do_not_authorize_writes(self):
        for action,path,valid,write in CASES:
            incomplete = '[{}]' if isinstance(json.loads(valid),list) else '{"fixture":{}}'
            for body,code in [("not JSON",200),("null",200),('{"unexpected":[]}',200),(incomplete,200),(valid,503)]:
                with self.subTest(action=action,body=body,code=code):
                    # Given a failed, malformed or incomplete read of existing state

                    # When the real configurator and shared request helpers run
                    result,requests,_=self.run_case(action,path,body,code)

                    # Then the read is reached and its dependent write never occurs
                    self.assertTrue(any(path in line for line in requests),result.stderr)
                    self.assertFalse(any(line.startswith(write) for line in requests),(requests,result.stderr))
                    self.assertTrue(result.stderr.strip() or result.returncode, "failure must be visible")

    def test_known_empty_or_default_state_allows_setup(self):
        for action,path,valid,write in CASES:
            with self.subTest(action=action):
                # Given a valid response that authorizes first-run setup

                # When the same configurator runs
                result,requests,_=self.run_case(action,path,valid)

                # Then the dependent write is actually attempted as a positive control
                self.assertTrue(any(line.startswith(write) for line in requests),(requests,result.stderr))

    def test_unreadable_bazarr_settings_preserve_yaml(self):
        # Given an incomplete settings response

        # When Bazarr is configured
        result,requests,yaml=self.run_case("bazarr","/api/system/settings",'{}')

        # Then the live YAML remains byte-identical and no restart occurs
        self.assertEqual(yaml,'auth:\n  apikey: fixture\nsonarr: {}\nradarr: {}\ngeneral: {}\n')
        self.assertNotIn("DOCKER compose restart bazarr",requests)
        self.assertNotEqual(result.returncode,0)

    def test_invalid_certificates_are_unknown_not_absent(self):
        for body in ('{}','[{}]','not JSON'):
            with self.subTest(body=body):
                # Given an unreadable certificate inventory

                # When certificate IDs are selected
                result,_,_=self.run_case("certificates","/api/nginx/certificates",body)

                # Then the caller receives the unknown-state status that blocks issuance
                self.assertEqual(result.returncode,2,result.stderr)

    def test_unknown_portainer_admin_state_does_not_restart_or_create(self):
        for code in (0,403,500,503):
            with self.subTest(code=code):
                # Given an admin check that cannot establish whether an admin exists

                # When Portainer setup runs
                result,requests,_=self.run_case("portainer","/api/users/admin/check","",code)

                # Then no container restart or API write is authorized
                self.assertNotEqual(result.returncode,0)
                self.assertFalse(any(line.startswith(("POST ","PUT ","DOCKER ")) for line in requests),requests)

    def test_missing_seerr_quota_buckets_do_not_authorize_updates(self):
        # Given settings with a renamed or missing nested quota object

        # When Seerr setup runs
        result,requests,_=self.run_case("seerr-main","/api/v1/settings/main",
            '{"apiKey":"fixture","defaultPermissions":0,"defaultQuotas":{}}')

        # Then unknown quotas do not become unlimited defaults for an update
        self.assertNotEqual(result.returncode,0)
        self.assertNotIn("POST /api/v1/settings/main",requests)

    def test_unreadable_npm_preserved_fields_block_host_updates(self):
        host={"id":1,"domain_names":["jellyfin.fixture.test"],"certificate_id":1,"enabled":True,
              "meta":{"fixture":True},"locations":[]}
        for field in ("meta","locations"):
            for missing in (True,False):
                with self.subTest(field=field,missing=missing):
                    # Given a host whose preserved state is missing or has the wrong type
                    incomplete=dict(host)
                    if missing: del incomplete[field]
                    else: incomplete[field]=False

                    # When publication would otherwise update that host
                    result,requests,_=self.run_case("npm-hosts","/api/nginx/proxy-hosts",json.dumps([incomplete]))

                    # Then no update may replace unknown state with an empty container
                    self.assertNotIn("PUT /api/nginx/proxy-hosts/1",requests,(requests,result.stderr))
        # Given the same host with its preserved fields present

        # When publication runs
        result,requests,_=self.run_case("npm-hosts","/api/nginx/proxy-hosts",json.dumps([host]))

        # Then the valid state still permits the update as a positive control
        self.assertIn("PUT /api/nginx/proxy-hosts/1",requests,(requests,result.stderr))

unittest.main(verbosity=2)
PY
    pass "failed and incomplete reads block dependent writes across services"
else
    fail "failed and incomplete reads block dependent writes across services"
fi
scenario_end api-read-safety
summary
