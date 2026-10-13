import test from 'node:test';import assert from 'node:assert/strict';
const processors=new Map();globalThis.sampleRate=48000;globalThis.currentFrame=0;
globalThis.AudioWorkletProcessor=class{constructor(){this.messages=[];this.port={postMessage:(data)=>this.messages.push(data),onmessage:null};}};
globalThis.registerProcessor=(name,ctor)=>processors.set(name,ctor);
await import('./recording-worklet.mjs');await import('./output-worklet.mjs');await import('./kick-worklet.mjs');
test('actual recording worklet captures selected input, excludes count-in/tail and flushes final partial block',()=>{
 const Recorder=processors.get('recording-input'),node=new Recorder();node.port.onmessage({data:{type:'arm',start:1,end:2,indices:[1]}});
 const left=new Float32Array(128).fill(.1),right=Float32Array.from({length:128},(_,i)=>i/128);globalThis.currentFrame=0;node.process([[left,right]]);
 const pcm=node.messages.find(m=>m.type==='pcm');assert.equal(pcm.frames,48);assert.equal(pcm.channels.length,1);assert.equal(pcm.channels[0][0],right[48]);assert.equal(pcm.channels[0].at(-1),right[95]);assert.equal(node.messages.at(-1).type,'done');
});
test('recording worklet reports missing loopback channels instead of saving a silent false take',()=>{
 const Recorder=processors.get('recording-input'),node=new Recorder();node.port.onmessage({data:{type:'arm',start:0,end:10,indices:[2,3]}});node.process([[new Float32Array(128),new Float32Array(128)]]);assert.equal(node.messages[0].type,'error');assert.equal(node.messages.some(m=>m.type==='pcm'),false);
});
test('actual output worklet limits stereo mix and reports post-limiter peak/RMS',()=>{
 const Processor=processors.get('drum-output'),node=new Processor();node.port.onmessage({data:{enabled:true,ceilingDBFS:-6}});
 for(let block=0;block<40;block++){const output=[new Float32Array(128),new Float32Array(128)];node.process([[new Float32Array(128).fill(4),new Float32Array(128).fill(-3)]],[output]);assert.ok(output[0].every(v=>Math.abs(v)<=10**(-6/20)+1e-7));}
 const level=node.messages.at(-1);assert.ok(Math.abs(level.peakDBFS+6)<1e-5);assert.ok(level.limiterReductionDB>17);assert.ok(level.rmsDBFS<=-6);
});
test('actual kick worklet preserves onset frame while waiting for native spectral/decay window',()=>{
 const Processor=processors.get('kick-input'),node=new Processor();node.port.onmessage({data:{threshold:.2,lockout:40}});
 for(let block=0;block<10;block++){globalThis.currentFrame=block*128;const input=new Float32Array(128);if(block===0)input[10]=.5;node.process([[input]]);}
 const hit=node.messages.find(m=>m.type==='hit');assert.ok(hit);assert.ok(Math.abs(hit.time-10/48000*1000)<1e-12);assert.ok(hit.features);assert.equal(node.messages.filter(m=>m.type==='hit').length,1);
});
