import test from 'node:test';import assert from 'node:assert/strict';
import {emptyProgress,prepareCeiling,recordProgress,exerciseIdentity} from './practice-progress.mjs';
const session=(bpm,clean,id='run')=>({id,name:'Straight 16ths',exerciseKind:'builtIn',bpm,date:'2026-10-13T21:00:00Z',metrics:{clean}});
const identity={id:exerciseIdentity({name:'Straight 16ths'}),name:'Straight 16ths',kind:'builtIn'};
test('native tempo advancement raises the just-played tempo rather than historical suggestions',()=>{
 const p=emptyProgress();recordProgress(p,session(180,true));
 for(let i=0;i<2;i++)assert.equal(recordProgress(p,session(80,true),{advance:true}).nextBPM,80);
 assert.equal(recordProgress(p,session(80,true),{advance:true}).nextBPM,85);
 assert.equal(p.tempoProgressions[0].highestCleanBPM,180);
});
test('failed native progression round resets streak, and replay/rescore does not call progression',()=>{
 const p=emptyProgress();recordProgress(p,session(120,true),{advance:true});recordProgress(p,session(120,false),{advance:true});assert.equal(p.tempoProgressions[0].consecutiveCleanSessions,0);
});
test('ceiling advances once per completed clean round and first failure records previous verified tempo',()=>{
 const p=emptyProgress();assert.equal(prepareCeiling(p,identity,80),80);
 assert.equal(recordProgress(p,session(80,true,'1'),{ceiling:true}).nextBPM,85);
 assert.equal(prepareCeiling(p,identity,80),85);
 assert.equal(recordProgress(p,session(85,false,'2'),{ceiling:true}).found,true);
 assert.equal(p.ceilingRecords[0].highestVerifiedBPM,80);assert.equal(p.ceilingRecords[0].failedBPM,85);assert.equal(p.ceilingRecords[0].roundsCompleted,2);
});
test('interrupted ceiling round resumes same BPM and never fabricates a completed session',()=>{
 const p=emptyProgress();prepareCeiling(p,identity,100);const restored=JSON.parse(JSON.stringify(p));assert.equal(prepareCeiling(restored,identity,120),100);assert.equal(restored.activeCeilingRun.sessionIDs.length,0);
});
test('ceiling below starting point creates no false verified record',()=>{
 const p=emptyProgress();prepareCeiling(p,identity,120);recordProgress(p,session(120,false),{ceiling:true});assert.equal(p.ceilingRecords.length,0);assert.equal(p.activeCeilingRun.phase.highestCleanBPM,null);
});
test('clean maximum completes ceiling search and caps advancement at 240 BPM',()=>{
 const p=emptyProgress();prepareCeiling(p,identity,240);assert.ok(recordProgress(p,session(240,true),{ceiling:true}).found);assert.equal(p.ceilingRecords[0].highestVerifiedBPM,240);
});
test('custom and imported progression identities keep native UUID scoping',()=>{
 assert.equal(exerciseIdentity({kind:'custom',customExerciseID:'ab12',name:'x'}),'custom:AB12');assert.equal(exerciseIdentity({kind:'importedSong',importedSongID:'cd34',name:'x'}),'imported:CD34');
});
