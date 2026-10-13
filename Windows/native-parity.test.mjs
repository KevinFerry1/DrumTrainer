import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import {exercises,makePattern} from './core.mjs';
import {nativeScore} from './native-scoring.mjs';
import {extractFeatures,makeSignature,soundSimilarity,analyzeNoise,makeCalibrationProfile,CalibrationHitCollector,CrosstalkGuard} from './audio-core.mjs';
const fixtures=JSON.parse(fs.readFileSync(new URL('./validation/native-fixtures.json',import.meta.url),'utf8'));
function compareNative(expected,actual,path='value') {
  if (expected==null) { assert.ok(actual==null,`${path}: expected unavailable, got ${actual}`); return; }
  if(typeof expected==='number') { assert.ok(typeof actual==='number' && Math.abs(expected-actual)<=1e-8+Math.abs(expected)*1e-11,`${path}: native ${expected}, Windows ${actual}`); return; }
  if(Array.isArray(expected)) { assert.ok(Array.isArray(actual),path); assert.equal(actual.length,expected.length,`${path}.length`); expected.forEach((v,i)=>compareNative(v,actual[i],`${path}[${i}]`)); return; }
  if(typeof expected==='object') { assert.ok(actual && typeof actual==='object',path); for(const key of Object.keys(expected))compareNative(expected[key],actual[key],`${path}.${key}`); return; }
  assert.equal(actual,expected,path);
}
for(const fixture of fixtures.scoring) test(`Swift scoring parity: ${fixture.name}`,()=>{
  const actual=fixture.actual.map(a=>({...a,velocityNormalized:a.velocity ?? null}));
  const result=nativeScore({expectedEvents:fixture.expected},actual,{gradeKicks:fixture.gradeKicks,corrections:fixture.corrections,voiceCorrections:fixture.voiceCorrections});
  compareNative(fixture.matchResults,result.results,'matches');
  compareNative(fixture.metrics,result,'metrics');
  compareNative(fixture.accents,result.accents,'accents'); compareNative(fixture.ghosts,result.ghosts,'ghosts');
  compareNative(fixture.stableTiming,result.stableTiming,'stableTiming'); assert.equal(result.clean,fixture.clean,'clean qualification');
});
for(const fixture of fixtures.patterns) test(`Swift pattern parity: ${fixture.exercise} at ${fixture.pattern.bpm} BPM`,()=>{
  const native=fixture.pattern,definition=exercises.find(e=>e.id===fixture.exercise),pattern=makePattern(definition,native.bpm,native.measures);
  const expected=[...native.expectedEvents].sort((a,b)=>a.sessionTimeNanoseconds-b.sessionTimeNanoseconds||(a.voice<b.voice?-1:a.voice>b.voice?1:0));
  assert.equal(pattern.durationNanoseconds,native.durationNanoseconds);
  assert.equal(pattern.notes.length,expected.length);
  expected.forEach((n,i)=>{
    const w=pattern.notes[i]; assert.equal(w.timeNanoseconds,n.sessionTimeNanoseconds); assert.equal(w.voice,n.voice);
    assert.deepEqual([...(w.allowedVoices ?? [])].sort(),[...n.allowedVoices].sort());
    assert.equal(w.measure,n.measure);assert.equal(w.beat,n.beat);assert.equal(w.subdivision,n.subdivision);
    assert.equal(w.simultaneousGroupID!=null,n.simultaneousGroupID!=null);
  });
  compareNative(native.referenceBeats.map(b=>({time:b.offsetNanoseconds/1e6,measure:b.measure,beat:b.beat,isAccent:b.isAccent})),pattern.referenceBeats,'reference clicks');
});
for(const [i,fixture]of fixtures.audio.entries())test(`Swift kick feature parity ${i+1}`,()=>compareNative(fixture.features,extractFeatures(fixture.samples,fixture.sampleRate),'audio features'));
test('Swift kick signature parity',()=>compareNative(fixtures.signature,makeSignature(fixtures.audio.map(f=>extractFeatures(f.samples,f.sampleRate))),'signature'));
test('classifier separates unlike kicks and accepts the same learned signature',()=>{
  const low=extractFeatures(fixtures.audio[0].samples,fixtures.audio[0].sampleRate),high=extractFeatures(fixtures.audio.at(-1).samples,fixtures.audio.at(-1).sampleRate),signature=makeSignature(Array(10).fill(low));
  assert.equal(soundSimilarity(low,signature),1);assert.ok(soundSimilarity(high,signature)<.2);
});
test('native calibration collection rejects duplicate ringing and bounds lockout suggestion',()=>{
  const c=new CalibrationHitCollector(40);assert.ok(c.record(.5,null,0));assert.equal(c.record(.4,null,35),false);assert.equal(c.suggestedLockoutMilliseconds,43);assert.equal(c.record(.4,null,90),false);assert.equal(c.suggestedLockoutMilliseconds,60);assert.ok(c.record(.6,null,200));assert.equal(c.amplitudes.length,2);
});
test('native crosstalk guard permits learned simultaneous kicks and vetoes weak pad noise',()=>{
  const c=new CrosstalkGuard();c.observeMIDIHit('snare',100);
  assert.ok(c.shouldSuppress({amplitude:.15,threshold:.1,time:110}));
  assert.equal(c.shouldSuppress({amplitude:.15,threshold:.1,time:110,similarity:.25}),false);
  assert.equal(c.shouldSuppress({amplitude:.7,threshold:.1,time:110}),false);
  assert.equal(c.shouldSuppress({amplitude:.15,threshold:.1,time:180}),false);
  c.enabled=false;assert.equal(c.shouldSuppress({amplitude:.15,threshold:.1,time:110}),false);
});
test('guided calibration retains learned fingerprint and native noise/separation rules',()=>{
  const noise=analyzeNoise(Array(100).fill(.01));assert.equal(noise.collectionThreshold,.05);
  const profile=makeCalibrationProfile({deviceUID:'synthetic',deviceName:'Synthetic',noise,hitAmplitudes:Array(20).fill(.6),hitSoundFeatures:Array(20).fill(fixtures.audio[0].features),retriggerLockoutMilliseconds:40});
  assert.equal(profile.quality,'good');assert.ok(Math.abs(profile.suggestedThreshold-(.01+.59*.35))<1e-12);assert.equal(profile.kickSoundSignature.sampleCount,20);
});
