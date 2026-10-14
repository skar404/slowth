const {test} = require('node:test');
const assert = require('node:assert/strict');
const vm = require('node:vm');
const fs = require('node:fs');
const source = fs.readFileSync('iOS/WebPause/pause-background.js', 'utf8');
function setup({alarmFails = false, lostAck = false} = {}) {
  let lease = {id:'one', target:'youtube', phase:'preparing', expiresAt:2000};
  const calls = []; const alarms = new Map();
  const ns = {getStateFresh: async () => ({toggles:{youtube:{shorts:true},instagram:{reels:true}}})};
  const api = {
    runtime:{sendNativeMessage(_, payload, cb) {
      calls.push(payload.action);
      if(payload.action==='activatePause') {
        lease = {...lease, phase:'active'};
        if(lostAck) return cb(null);
      }
      if(payload.action==='cancelPausePreparation' && lease?.phase==='preparing') lease=null;
      cb({ok:true,state:{pause:lease}});
    }},
    alarms:{create(name, options) {if(!alarmFails) alarms.set(name,{scheduledTime:options.when});},
      get(name, cb) {cb(alarms.get(name));}, clear(name) {alarms.delete(name);}, onAlarm:{addListener(){}}},
    tabs:{query(_,cb){cb([]);}}
  };
  vm.runInNewContext(source,{Unscroll:ns,browser:api,setTimeout,clearTimeout});
  return {ns,calls,alarms};
}
test('activation requires verified return alarm and preserves base preferences',async()=>{
  const {ns,calls,alarms}=setup();const result=await ns.getStateFresh('youtube');
  assert.equal(result.pause.phase,'active'); assert.equal(result.toggles.youtube.shorts,true);
  assert.deepEqual(calls,['getState','activatePause']);assert.equal(alarms.size,1);
});
test('alarm failure cancels preparation without activating',async()=>{
 const {ns,calls}=setup({alarmFails:true});assert.equal((await ns.getStateFresh('youtube')).pause,null);
 assert.ok(!calls.includes('activatePause'));assert.ok(calls.includes('cancelPausePreparation'));
});
test('lost activation response retains return alarm',async()=>{
 const {ns,alarms}=setup({lostAck:true});assert.equal((await ns.getStateFresh('youtube')).pause,null);
 assert.equal(alarms.size,1);
});
test('other sites cannot activate pending pause; duplicate requests share activation',async()=>{
 const {ns,calls}=setup();await ns.getStateFresh('instagram');assert.ok(!calls.includes('activatePause'));
 await Promise.all([ns.getStateFresh('youtube'),ns.getStateFresh('youtube')]);
 assert.equal(calls.filter(x=>x==='activatePause').length,1);
});
