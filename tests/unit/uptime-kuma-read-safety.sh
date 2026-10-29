#!/usr/bin/env bash
# Execute the shipped Socket.IO client against a deterministic event fixture.
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$REPO_ROOT/tests/lib/assert.sh"
scenario_begin uptime-kuma-read-safety
if python3 -I - "$REPO_ROOT" <<'PY'; then
import json, pathlib, shutil, subprocess, sys, unittest
root=pathlib.Path(sys.argv.pop())
source=(root/"scripts/services/uptime-kuma/main.sh").read_text()
program=source.split('node -e "\n',1)[1].split('\n"\n',1)[0].replace('\\"','"')
runner=[shutil.which("node"),"-"] if shutil.which("node") else ["docker","run","--rm","-i","--network","none","node:22-slim","node","-"]
HARNESS=r'''
const vm=require('node:vm');
const scenario=SCENARIO;
const events=[]; let listener=null, status=0, finish;
const done=new Promise(resolve => finish=resolve);
let monitors=scenario==='empty' ? {} : {1:{id:1,type:'http',name:'Fixture',url:'http://fixture'}};
if(scenario==='bad-record') monitors={1:{id:1,name:'Fixture',type:'http'}};
if(scenario==='bad-list') monitors=[];
const socket={
 on(event,callback){if(event==='connect') queueMicrotask(callback);},
 once(event,callback){listener=callback;},
 disconnect(){},
 emit(event,...args){
  events.push(event); const ack=args.pop();
  if(event==='needSetup') return queueMicrotask(()=>ack(scenario==='bad-setup' ? {} : false));
  queueMicrotask(()=>{
   ack({ok:true});
   if(event==='add') monitors[2]={id:2,type:'http',name:'Fixture',url:'http://fixture'};
   if(event==='login' && scenario!=='timeout' && listener){const cb=listener;listener=null;cb(monitors);}
   if(event==='getMonitorList' && scenario!=='refresh-timeout' && listener){const cb=listener;listener=null;cb(scenario==='refresh-bad' ? null : monitors);}
  });
 }
};
const sandbox={
 require(name){if(name==='socket.io-client') return {io:()=>socket};throw new Error(name);},
 process:{env:{KUMA_USER:'fixture',KUMA_PW:'fixture',MONITORS_JSON:JSON.stringify([{name:'Fixture',url:'http://fixture'}])},exit(code){status=code;}},
 console:{log(line){finish(JSON.parse(line));}},
 setTimeout(callback){return setTimeout(callback,5);},clearTimeout, setImmediate
};
vm.runInNewContext(PROGRAM,sandbox);
done.then(result=>{process.stdout.write(JSON.stringify({result,status,events}));});
'''
class KumaReadSafety(unittest.TestCase):
 def run_scenario(self,scenario):
  script=HARNESS.replace('SCENARIO',json.dumps(scenario)).replace('PROGRAM',json.dumps(program))
  result=subprocess.run(runner,input=script,text=True,capture_output=True,timeout=60)
  self.assertEqual(result.returncode,0,result.stderr)
  return json.loads(result.stdout)
 def test_unknown_monitor_state_blocks_every_dependent_write(self):
  for scenario in ('timeout','bad-record','bad-list','bad-setup'):
   with self.subTest(scenario=scenario):
    # Given an unavailable or incomplete monitor inventory or setup state

    # When the real shipped Socket.IO program runs
    out=self.run_scenario(scenario)

    # Then it reports failure before changing settings, monitors or status pages
    self.assertEqual(out['status'],1,out)
    self.assertIn('error',out['result'])
    self.assertFalse(set(out['events']) & {'setup','setSettings','add','addStatusPage','saveStatusPage'},out)
 def test_known_empty_inventory_allows_one_monitor(self):
  # Given an explicitly empty valid inventory

  # When setup runs
  out=self.run_scenario('empty')

  # Then one monitor is created and the status page is saved
  self.assertEqual(out['status'],0,out)
  self.assertEqual(out['events'].count('add'),1,out)
  self.assertIn('saveStatusPage',out['events'])
 def test_existing_inventory_is_preserved(self):
  # Given an existing matching monitor

  # When setup is repeated
  out=self.run_scenario('existing')

  # Then it skips monitor creation and still completes the status page
  self.assertEqual(out['status'],0,out)
  self.assertNotIn('add',out['events'])
  self.assertIn('saveStatusPage',out['events'])
 def test_failed_refresh_preserves_the_status_page(self):
  for scenario in ('refresh-timeout','refresh-bad'):
   with self.subTest(scenario=scenario):
    # Given a successful initial inventory followed by an unusable refresh

    # When the status-page inventory is requested
    out=self.run_scenario(scenario)

    # Then no empty replacement status page is written
    self.assertEqual(out['status'],1,out)
    self.assertNotIn('addStatusPage',out['events'])
    self.assertNotIn('saveStatusPage',out['events'])
unittest.main(verbosity=2)
PY
    pass "Socket.IO read failures preserve monitors and status pages"
else
    fail "Socket.IO read failures preserve monitors and status pages"
fi
scenario_end uptime-kuma-read-safety
summary
