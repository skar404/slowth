const test = require('node:test');
const assert = require('node:assert/strict');
const vm = require('node:vm');
const fs = require('node:fs');
const path = require('node:path');
const source = fs.readFileSync(path.join(__dirname, '../../iOS/WebPause/pause-policy.js'), 'utf8');
function harness() {
  let wall = 1000, mono = 0;
  const context = {Unscroll:{}, Date:{now:()=>wall*1000}, performance:{now:()=>mono*1000}};
  vm.runInNewContext(source, context);
  return {ns:context.Unscroll, time(w,m){ wall=w; mono=m; }};
}
const state = () => ({pause:{id:'a',phase:'active',target:'youtube',startedAt:1000,expiresAt:1180}});
test('temporary settings are not persisted or shared with other targets', () => {
  const {ns} = harness();
  const base={all:true,shorts:true,feed:false};
  const effective=ns.pauseSettings('youtube',state(),base);
  assert.equal(effective.all,false); assert.equal(effective.shorts,false);
  assert.equal(base.all,true);
  assert.equal(ns.pauseSettings('instagram',state(),base),base);
});
test('expired cache restores current base settings without background execution', () => {
  const h=harness(), s=state(); const current={all:false,shorts:false,feed:true};
  assert.equal(h.ns.pauseSettings('youtube',s,current).feed,false);
  h.time(1180,180);
  assert.equal(h.ns.pauseSettings('youtube',s,current),current);
});
test('Instagram Stories follows the pause deadline without changing saved preferences', () => {
  const h = harness(), s = state();
  s.pause.target = 'instagram';
  const saved = { all: false, shorts: false, feed: false, stories: true };
  assert.equal(h.ns.pauseSettings('instagram', s, saved).stories, false);
  assert.equal(saved.stories, true);
  assert.equal(h.ns.pauseSettings('youtube', s, saved), saved);
  h.time(1180, 180);
  assert.equal(h.ns.pauseSettings('instagram', s, saved).stories, true);
});
test('unconfirmed grant or clock discontinuity cannot authorize', () => {
  const h=harness(), s=state(); s.pause.phase='preparing';
  assert.equal(h.ns.pauseValid(s,'youtube'),false);
  s.pause.phase='active'; assert.equal(h.ns.pauseValid(s,'youtube'),true);
  h.time(1100,1); assert.equal(h.ns.pauseValid(s,'youtube'),false);
});
test('ended or mismatched lease never permits a target', () => {
  const h=harness();
  assert.equal(h.ns.pauseValid({pause:null},'youtube'),false);
  const s=state();s.pause.phase='ending';assert.equal(h.ns.pauseValid(s,'youtube'),false);
});

test('three-minute boundary and oversized grants', () => {
  const h = harness(), s = state();
  assert.equal(h.ns.pauseValid(s, 'youtube'), true);
  h.time(1179.9, 179.9);
  assert.equal(h.ns.pauseValid(s, 'youtube'), true);
  h.time(1180, 180);
  assert.equal(h.ns.pauseValid(s, 'youtube'), false);
  const old = state(); old.pause.expiresAt = 1301;
  assert.equal(h.ns.pauseValid(old, 'youtube'), false);
});

for (const seconds of [30, 60, 180, 300]) {
  test(`configured ${seconds}-second pause expires at its own deadline`, () => {
    const h = harness(), s = state();
    s.pause.expiresAt = 1000 + seconds;
    assert.equal(h.ns.pauseValid(s, 'youtube'), true);
    h.time(1000 + seconds - 0.1, seconds - 0.1);
    assert.equal(h.ns.pauseValid(s, 'youtube'), true);
    h.time(1000 + seconds, seconds);
    assert.equal(h.ns.pauseValid(s, 'youtube'), false);
  });
}

test('YouTube home hiding suspends only for its active pause and restores at expiry', () => {
  const h = harness(), s = state();
  const saved = { all: false, shorts: true, feed: true, hideHomeFeed: true };
  assert.equal(h.ns.pauseSettings('youtube', s, saved).hideHomeFeed, false);
  assert.equal(saved.hideHomeFeed, true);
  h.time(1180, 180);
  assert.equal(h.ns.pauseSettings('youtube', s, saved).hideHomeFeed, true);
});
