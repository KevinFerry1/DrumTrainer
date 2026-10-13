import test from 'node:test';import assert from 'node:assert/strict';import {recordingSlice,pcm16,wavHeader,recordingChannels} from './recording-core.mjs';
test('recording clips count-in and tail at sample boundaries using native ceil-start/floor-end rules',()=>{
 assert.deepEqual(recordingSlice(0,128,48000,1,2),{first:48,end:96,frames:48});assert.equal(recordingSlice(0,128,48000,10,20).frames,0);assert.equal(recordingSlice(960,128,48000,10,20).frames,0);
 assert.deepEqual(recordingSlice(0,128,44100,.1,1),{first:5,end:44,frames:39});
});
test('recording channel choices preserve native input and loopback pairs',()=>assert.deepEqual(recordingChannels,{input1:[0],input2:[1],loopback34:[2,3]}));
test('WAV encoding interleaves channels, clamps sample peaks and writes a correct portable header',()=>{
 const data=pcm16([new Float32Array([1,-1,.5]),new Float32Array([.25,-.25,2])]),view=new DataView(data);assert.equal(view.getInt16(0,true),32767);assert.equal(view.getInt16(2,true),8192);assert.equal(view.getInt16(4,true),-32768);assert.equal(view.getInt16(10,true),32767);
 const header=new DataView(wavHeader(3,2,48000));assert.equal(header.getUint32(4,true),48);assert.equal(header.getUint16(22,true),2);assert.equal(header.getUint32(24,true),48000);assert.equal(header.getUint32(40,true),12);
});
test('invalid WAV dimensions and mismatched PCM channels fail without creating a take',()=>{assert.throws(()=>wavHeader(1e12,2,48000));assert.throws(()=>pcm16([new Float32Array(2),new Float32Array(3)]));});
