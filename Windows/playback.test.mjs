import test from 'node:test';import assert from 'node:assert/strict';import fs from 'node:fs';
import {PlaybackOnsetDetector,playbackStart} from './playback-onset.mjs';
const fixtures=JSON.parse(fs.readFileSync(new URL('./validation/native-playback-fixtures.json',import.meta.url)));
for(const f of fixtures)test(`Swift playback onset: ${f.name}`,()=>{
  const detector=new PlaybackOnsetDetector(f.threshold??NaN),results=f.steps.map(step=>{let onset=null;if(step.type==='silent')detector.observeSilentCaptureInterval();else onset=detector.consume(step.level??NaN,step.time??NaN,step.duration??NaN);return{ready:detector.isReady,triggered:detector.hasTriggered,onset};});
  assert.deepEqual(results,f.results.map(r=>({...r,onset:r.onset??null})));
});
test('playback offset and age bounds retain pre-roll only inside a valid practice window',()=>{
  const base={onset:10000,now:10030,armedAt:9000,duration:2000,tolerance:100};assert.equal(playbackStart({...base,offset: -500}),9500);assert.equal(playbackStart({...base,offset:7000}),15000);assert.equal(playbackStart({...base,offset:NaN}),10000);
  for(const opts of [{now:12201},{now:9749},{armedAt:10001},{offset:-5000},{latestDropped:9900}])assert.throws(()=>playbackStart({...base,...opts}));
  assert.equal(playbackStart({...base,latestDropped:9899}),10000);
});
