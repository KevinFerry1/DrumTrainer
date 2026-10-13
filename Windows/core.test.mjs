import test from 'node:test';
import assert from 'node:assert/strict';
import {exercises,makePattern,score,TransientDetector,importBackup,validateDefinition} from './core.mjs';

test('all native built-in note counts and subdivisions are preserved',() => {
  const counts = [8,16,12,4,12,12,12,8,12,13,26,14,24,24,16];
  assert.equal(exercises.length,15);
  exercises.forEach((e,i) => {
    const p = makePattern(e,120,4);
    assert.equal(p.notes.length,counts[i]*4,e.id);
    assert.equal(p.duration,8000);
    assert.ok(p.notes.every(n => n.time >= 0 && n.time < p.duration));
  });
});
test('60-second dense run scores 960 unique hits with no reuse',() => {
  const p = makePattern(exercises[1],240,16); // 64 beats / 240 BPM = 16 seconds, 256 hits
  const expanded = {...p,duration:60000,notes:Array.from({length:960},(_,i) => ({time:i*62.5,voice:'kick',allowedVoices:[],measure:Math.floor(i/16)+1}))};
  const hits = expanded.notes.map((n,i) => ({time:n.time+(i%3-1)*5,voice:'kick',source:'midi',velocity:90}));
  const m = score(expanded,hits);
  assert.equal(m.correct,960); assert.equal(m.extra,0); assert.equal(m.missed,0); assert.ok(m.clean);
  assert.equal(new Set(m.results.map(r => r.actual.index)).size,960);
});
test('wrong, missed, extra, alternate voices and boundary timing',() => {
  const p = {notes:[{time:0,voice:'snare',allowedVoices:['crossStick']},{time:500,voice:'kick'},{time:1000,voice:'ride'}]};
  const m = score(p,[{time:100,voice:'crossStick'},{time:510,voice:'snare'},{time:1300,voice:'highTom'}]);
  assert.equal(m.correct,1); assert.equal(m.wrong,1); assert.equal(m.missed,1); assert.equal(m.extra,1);
  assert.equal(m.results.find(r => r.status==='correct').offset,100);
});
test('simultaneous voices match once regardless of MIDI arrival order',() => {
  const p = {notes:[{time:0,voice:'snare',simultaneousGroupID:'group'},{time:0,voice:'kick',simultaneousGroupID:'group'},{time:0,voice:'ride',simultaneousGroupID:'group'}]};
  const m = score(p,[{time:10,voice:'ride'},{time:-5,voice:'kick'},{time:0,voice:'snare'}]);
  assert.equal(m.correct,3); assert.equal(m.spread,15);
});
test('native ordered assignment preserves valid hits near adjacent note windows',() => {
  const m = score({notes:[{time:0,voice:'kick'},{time:60,voice:'kick'}]},[{time:40,voice:'kick'},{time:-90,voice:'kick'}]);
  assert.equal(m.correct,2); assert.equal(m.extra,0); assert.equal(m.missed,0);
});
test('Grade kicks and source corrections leave raw input unchanged',() => {
  const p = {notes:[{time:0,voice:'kick'},{time:500,voice:'snare'}]};
  const evidence = [{time:30,voice:'kick',source:'microphone'},{time:520,voice:'snare',source:'midi'}];
  const m = score(p,evidence,{gradeKicks:false,corrections:{midi:20}});
  assert.equal(m.expected,1); assert.equal(m.played,1); assert.equal(m.bias,0);
  assert.equal(evidence[1].time,520);
});
test('sequence snapshots preserve mixed grids and their own repeat counts',() => {
  const d = {name:'Verse and fill',sequenceRepeats:2,sequenceSteps:[{name:'Verse',subdivision:'eighths',hits:[{slot:1,voice:'kick'}],repeats:2},{name:'Fill',subdivision:'triplets',hits:[{slot:1,voice:'snare'}],repeats:1}]};
  const p = makePattern(d,120,16);
  assert.equal(p.measures,6); assert.equal(p.notes.length,6); assert.equal(p.notes[2].time,Math.round((4000+500/3)*1e6)/1e6);
  assert.throws(() => makePattern({...d,sequenceSteps:d.sequenceSteps.map(s => ({...s,repeats:16})),sequenceRepeats:16},120,1),/128/);
});
test('accents and ghosts require local MIDI velocity contrast and cannot grade microphone velocity',() => {
  const p = {notes:[{time:0,voice:'snare'},{time:500,voice:'snare',accent:true},{time:1000,voice:'snare',ghost:true}]};
  const evidence = [80,120,25].map((velocity,i) => ({time:i*500,voice:'snare',velocity}));
  const m = score(p,evidence); assert.ok(m.clean);
  assert.deepEqual(m.results.filter(r => r.dynamics).map(r => r.dynamics),['achieved','achieved']);
  evidence[1].velocity = null;
  assert.equal(score(p,evidence).clean,false);
});
test('interruptions and empty scored patterns never qualify as clean',() => {
  const p = {notes:[{time:0,voice:'kick'}]};
  assert.equal(score(p,[{time:0,voice:'kick'}],{dropped:1}).clean,false);
  assert.equal(score(p,[],{gradeKicks:false}).clean,false);
});
test('transient detector rejects sustained peaks and rearms only after quiet and lockout',() => {
  const d = new TransientDetector(1000,.2,40);
  assert.ok(d.sample(.4,0));
  for (let i=1;i<50;i++) assert.equal(d.sample(.4,i),false);
  for (let i=50;i<65;i++) assert.equal(d.sample(0,i),false);
  assert.ok(d.sample(.4,65));
  for (let i=66;i<90;i++) d.sample(0,i);
  assert.equal(d.sample(.4,90),false);
  for (let i=91;i<120;i++) d.sample(0,i);
  assert.ok(d.sample(.4,120));
});
test('invalid custom notes and imports are rejected before data can be merged',() => {
  assert.throws(() => validateDefinition({name:'bad',subdivision:'sixteenths',hits:[{slot:16,voice:'kick'}]}));
  assert.throws(() => validateDefinition({name:'bad',subdivision:'eighths',hits:[{slot:0,voice:'kick'},{slot:0,voice:'kick'}]}));
  assert.throws(() => importBackup({schemaVersion:12,customExercises:[],sessions:[]}));
  assert.throws(() => importBackup({format:'DrumTrainerWindows',version:1,exercises:[],sessions:[{id:'x',name:'x',bpm:120,metrics:{recall:1,precision:1},evidence:[{time:'NaN',voice:'kick'}]}]}));
});
test('Mac archive remains unchanged and Windows backup round-trips original archives',() => {
  const mac = {schemaVersion:9,customExercises:[{id:'custom',definition:{name:'Mine',subdivision:'sixteenths',hits:[{slot:0,voice:'kick',accent:true}]}}],sessions:[{id:'history',exerciseName:'Kick practice',bpm:120,recall:.99,completedAt:800000000}],importedSongs:[{id:'song'}],instrumentProfiles:[{kind:'drums'}]};
  const original = JSON.stringify(mac), imported = importBackup(mac);
  assert.equal(imported.exercises.length,1); assert.equal(imported.nativeArchives[0],mac); assert.equal(JSON.stringify(mac),original);
  const windows = {format:'DrumTrainerWindows',version:1,exercises:imported.exercises,sessions:[],nativeArchives:imported.nativeArchives};
  assert.equal(JSON.stringify(importBackup(JSON.parse(JSON.stringify(windows))).nativeArchives[0]),original);
});
test('Windows session evidence and matching decisions round-trip and malformed nested archives are rejected',() => {
  const pattern = makePattern(exercises[0],120,1), evidence = pattern.notes.map(n => ({time:n.time,voice:n.voice,source:'midi',velocity:90}));
  const session = {id:'session',name:pattern.name,bpm:120,date:new Date().toISOString(),pattern,evidence,metrics:score(pattern,evidence)};
  const value = {format:'DrumTrainerWindows',version:1,exercises:[],sessions:[session],nativeArchives:[]};
  assert.deepEqual(importBackup(JSON.parse(JSON.stringify(value))).sessions,[session]);
  assert.throws(() => importBackup({...value,nativeArchives:[value]}));
  assert.throws(() => importBackup({...value,sessions:[{...session,metrics:{...session.metrics,perVoice:'invalid'}}]}));
});
