import test from 'node:test';import assert from 'node:assert/strict';import fs from 'node:fs';import {clickSounds,kickSounds,clickSamples,kickSamples,kickDynamics,OutputLimiter,measurePCM} from './sound-synthesis.mjs';
const nativeFixtures=JSON.parse(fs.readFileSync(new URL('./validation/native-sound-fixtures.json',import.meta.url),'utf8'));
for(const [i,fixture]of nativeFixtures.entries())test(`Native synthesized sound ${i+1}: ${fixture.kind} ${fixture.sound}`,()=>{
 const samples=fixture.kind==='click'?clickSamples(fixture.sampleRate,fixture.sound,fixture.accent,fixture.gainDB):kickSamples(fixture.sampleRate,fixture.sound,fixture.gainDB,fixture.dynamics);
 assert.equal(samples.length,fixture.frameCount);fixture.indexes.forEach((frame,index)=>assert.ok(Math.abs(samples[frame]-fixture.samples[index])<1e-7+Math.abs(fixture.samples[index])*1e-7,`Frame ${frame}: native ${fixture.samples[index]}, Windows ${samples[frame]}`));
});
test('all five native click voices and four kick voices are deterministic finite PCM at common device rates',()=>{
 for(const rate of [44100,48000]){for(const sound of Object.keys(clickSounds)){const a=clickSamples(rate,sound,true);assert.ok(a.length>1000);assert.ok(a.every(Number.isFinite));assert.deepEqual(a,clickSamples(rate,sound,true));assert.notDeepEqual(a,clickSamples(rate,sound,false));}for(const sound of Object.keys(kickSounds)){const a=kickSamples(rate,sound);assert.ok(a.length>=rate*.17);assert.ok(a.every(Number.isFinite));assert.equal(a[0],0);}}
});
test('kick velocity law, gain clamping and quiet levels follow native formulas',()=>{
 assert.equal(kickDynamics(0),.16);assert.equal(kickDynamics(1),1);assert.equal(kickDynamics(.5,false),1);
 const quiet=kickSamples(48000,'studioPunch',-36),loud=kickSamples(48000,'studioPunch',6);assert.ok(measurePCM([loud]).peakDBFS-measurePCM([quiet]).peakDBFS>41.9);
});
test('post-mix limiter preserves quiet signals and bounds boosted overlapping clicks/kicks at selected ceiling',()=>{
 const limiter=new OutputLimiter(48000);limiter.ceilingDBFS=-6;assert.equal(limiter.frame([.01,-.02])[0],.01);
 for(let i=0;i<3000;i++){const output=limiter.frame([4,-3]);assert.ok(Math.max(...output.map(Math.abs))<=10**(-6/20)+1e-12);}
 limiter.enabled=false;assert.deepEqual(limiter.frame([4,-3]),[4,-3]);
});
test('output meter measures signal and returns -80 dBFS for silence',()=>{
 assert.deepEqual(measurePCM([new Float32Array(10)]),{peakDBFS:-80,rmsDBFS:-80});const level=measurePCM([new Float32Array([.5,-.5])]);assert.ok(Math.abs(level.peakDBFS+6.020599913)<1e-8);assert.equal(level.peakDBFS,level.rmsDBFS);
});
