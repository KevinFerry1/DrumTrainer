import test from 'node:test';import assert from 'node:assert/strict';
import {parseMIDI,songMeasures,songNanoseconds,makeSongPattern,firstSongMeasure} from './midi.mjs';
const u32=n=>[(n>>>24)&255,(n>>>16)&255,(n>>>8)&255,n&255];
const ascii=s=>[...s].map(c=>c.charCodeAt(0));
const vlq=n=>{const v=[n&127];while((n=Math.floor(n/128))>0)v.unshift((n&127)|128);return v;};
const chunk=(name,data)=>[...ascii(name),...u32(data.length),...data];
const file=(tracks,format=1,division=480)=>new Uint8Array([...chunk('MThd',[0,format,0,tracks.length,division>>8,division&255]),...tracks.flatMap(t=>chunk('MTrk',t))]);
const end=[0,255,47,0];
test('MIDI 0 parses running status, velocity-zero release and native file-import tom/cymbal map',()=>{
 const song=parseMIDI(file([[0,0x99,45,100,0,55,80,...vlq(480),45,0,0,55,0,...end]],0),'fixture.mid');
 assert.equal(song.format,0);assert.equal(song.tracks[0].notes[0].durationTicks,480);assert.equal(song.noteMappings.find(n=>n.noteNumber===45).voice,'lowTom');assert.equal(song.noteMappings.find(n=>n.noteNumber===55).voice,'crash2');assert.equal(song.tracks[0].notes.length,2);
});
test('MIDI 1 prefers percussion track and retains tempo, meter, controllers and held-note uncertainty',()=>{
 const conductor=[0,255,81,3,7,161,32,0,255,88,4,4,2,24,8,...vlq(1920),255,81,3,6,26,128,0,255,88,4,3,2,24,8,...end];
 const piano=[0,0x90,60,90,0,64,90,0,67,90,...end];const drums=[0,0x99,36,100,...vlq(1920),0x99,38,90,0,0xb9,64,127,...end];
 const song=parseMIDI(file([conductor,piano,drums]));assert.equal(song.selectedTrackIndex,2);assert.equal(song.tempoChanges.length,2);assert.equal(song.timeSignatureChanges[1].numerator,3);assert.equal(song.tracks[2].notes[0].durationUncertain,true);assert.equal(song.tracks[2].controls[0].controller,64);
 const measures=songMeasures(song);assert.equal(measures[0].endTick,1920);assert.equal(measures[1].endTick,3360);assert.equal(songNanoseconds(song,0,3360),3200000000);
 const pattern=makeSongPattern(song,{startMeasure:1,endMeasure:2,repeats:2,targetBPM:60});assert.equal(pattern.duration,12800);assert.equal(pattern.notes[1].time,4000);assert.equal(pattern.referenceBeats.length,14);assert.equal(pattern.measureSignatures[1].numerator,3);
});
test('tempo changes within a measure retain exact source timing under section tempo scaling',()=>{
 const conductor=[0,255,81,3,7,161,32,...vlq(480),255,81,3,15,66,64,...end];const drums=[0,0x99,36,100,...vlq(480),38,100,...vlq(480),42,100,...end];
 const song=parseMIDI(file([conductor,drums])),pattern=makeSongPattern(song,{startMeasure:1,endMeasure:1,targetBPM:120});assert.equal(pattern.notes[1].time,500);assert.equal(pattern.notes[2].time,1500);assert.equal(pattern.duration,3500);
});
test('rest-only intro selects first playable measure and rejects an empty practice section',()=>{
 const song=parseMIDI(file([[...vlq(1920*10),0x99,36,100,...end]],0));assert.equal(firstSongMeasure(song),11);assert.throws(()=>makeSongPattern(song,{startMeasure:1,endMeasure:4}),/Map at least one/);
});
test('malformed/truncated data, unsupported format/SMPTE and invalid running status fail safely',()=>{
 assert.throws(()=>parseMIDI(new Uint8Array([1,2,3])));assert.throws(()=>parseMIDI(file([[...end]],2)));assert.throws(()=>parseMIDI(file([[0,0x99,36,90,...end]],0,0x8001)),/SMPTE/);assert.throws(()=>parseMIDI(file([[0,36,90,...end]],0)),/running status/);assert.throws(()=>parseMIDI(file([[0,0x99,36,200,...end]],0)),/data byte/);
});
