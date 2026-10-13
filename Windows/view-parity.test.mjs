import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import {nativeScore} from './native-scoring.mjs';
import {timingTimeline,filterTimeline} from './timing-timeline.mjs';
import {notePosition,eventPosition,scorePosition} from './notation.mjs';
const fixtures=JSON.parse(fs.readFileSync(new URL('./validation/native-fixtures.json',import.meta.url)));
for(const g of fixtures.geometry??[])test(`Swift staff geometry: ${g.slotsPerMeasure} slots, ${g.measureWidth} width, slot ${g.slot}`,()=>assert.equal(notePosition(g.measure,g.slot,g.slotsPerMeasure,g.measureWidth),g.position));
for(const f of fixtures.scoring)test(`Swift timing timeline: ${f.name}`,()=>{
  const base=f.expected.length?Math.min(...f.expected.map(e=>e.sessionTimeNanoseconds)):0;
  const pattern={duration:8000,notes:f.expected.map(e=>({...e,sessionTimeNanoseconds:e.sessionTimeNanoseconds-base}))};
  const evidence=f.actual.map(e=>({...e,sessionTimeNanoseconds:e.sessionTimeNanoseconds-base,velocityNormalized:e.velocity??null}));
  const metrics=nativeScore(pattern,evidence,{gradeKicks:f.gradeKicks,corrections:f.corrections,voiceCorrections:f.voiceCorrections}),timeline=timingTimeline({pattern,metrics});
  assert.equal(timeline.start,(f.timeline.start-base)/1e6);assert.equal(timeline.end,(f.timeline.end-base)/1e6);
  const project=e=>({id:e.id,expectedEventID:e.expectedEventID??null,actualEventID:e.actualEventID??null,measure:e.expected?.measure??null,beat:e.expected?.beat??null,subdivision:e.expected?.subdivision??null,expectedVoice:e.expected?.voice??null,playedVoice:e.actual?.voice??null,expectedTime:e.expectedTime,actualTime:e.actualTime,status:e.status,offset:e.offset,source:e.actual?.source??null,isProblem:e.isProblem,anchor:e.anchor});
  assert.deepEqual(timeline.entries.map(project),f.timeline.entries.map(e=>({id:e.id,expectedEventID:e.expectedEventID??null,actualEventID:e.actualEventID??null,measure:e.measure??null,beat:e.beat??null,subdivision:e.subdivision??null,expectedVoice:e.expectedVoice??null,playedVoice:e.playedVoice??null,expectedTime:e.expectedTimeNanoseconds==null?null:(e.expectedTimeNanoseconds-base)/1e6,actualTime:e.actualTimeNanoseconds==null?null:(e.actualTimeNanoseconds-base)/1e6,status:e.classification,offset:e.signedOffsetMilliseconds??null,source:e.source??null,isProblem:e.isProblem,anchor:(e.anchorTimeNanoseconds-base)/1e6})));
  assert.ok(filterTimeline(timeline,{problems:true}).every(e=>e.isProblem));
});
test('staff playhead and notes follow variable measure duration and clamp at session bounds',()=>{
  const p={duration:3000,measures:2,measureStarts:[0,1000,3000],measureSignatures:[{numerator:3,denominator:4},{numerator:5,denominator:8}],subdivision:'sixteenths'};
  assert.equal(scorePosition(p,-50,330),notePosition(0,0,12,330));assert.equal(scorePosition(p,2000,330),notePosition(1,10,20,330));assert.equal(scorePosition(p,3100,330),notePosition(1,20,20,330));
  assert.equal(eventPosition(p,{measure:2,beat:1,subdivision:0,time:2000},330),notePosition(1,10,20,330));
});
