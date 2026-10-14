import test from 'node:test';import assert from 'node:assert/strict';import fs from 'node:fs';
import {parseMIDI,songMeasures,makeSongPattern} from './midi.mjs';
const fixtures=JSON.parse(fs.readFileSync(new URL('./validation/native-midi-fixtures.json',import.meta.url)));
for(const f of fixtures)test(`Swift MIDI import and section: ${f.name}`,()=>{
 if(f.error){assert.throws(()=>parseMIDI(new Uint8Array(f.bytes),`${f.name}.mid`));return;}
 const song=parseMIDI(new Uint8Array(f.bytes),`${f.name}.mid`),native=f.song;
 for(const key of ['name','sourceFilename','format','ticksPerQuarterNote','tempoChanges','timeSignatureChanges','tracks','selectedTrackIndex','noteMappings'])assert.deepEqual(song[key],native[key],key);
 assert.deepEqual(songMeasures(song),f.measures);
 const pattern=makeSongPattern(song,{startMeasure:1,endMeasure:Math.min(2,f.measures.length),repeats:2,targetBPM:113}),p=f.pattern;
 assert.equal(pattern.durationNanoseconds,p.durationNanoseconds);assert.equal(pattern.measures,p.measures);assert.deepEqual(pattern.measureSignatures,p.measureSignatures);assert.deepEqual(pattern.measureStarts.map(n=>Math.round(n*1e6)),p.measureStartOffsetsNanoseconds);
 assert.deepEqual(pattern.referenceBeats,p.referenceBeats.map(b=>({time:b.offsetNanoseconds/1e6,measure:b.measure,beat:b.beat,isAccent:b.isAccent})));
 assert.deepEqual(pattern.notes.map(n=>[n.voice,n.timeNanoseconds,n.measure,n.beat,n.subdivision,n.expectedVelocity,n.simultaneousGroupID!=null]),p.expectedEvents.map(n=>[n.voice,n.sessionTimeNanoseconds,n.measure,n.beat,n.subdivision,n.expectedVelocity,n.simultaneousGroupID!=null]));
});
