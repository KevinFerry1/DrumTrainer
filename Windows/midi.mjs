// Standard MIDI 0/1 parsing and section timelines, following the native Swift implementation.
import {gm,voices} from './core.mjs';
// The native MIDI-file importer has a different GM tom/cymbal map from live pad mapping.
export const importedGM={...gm,45:'lowTom',48:'midTom',55:'crash2',54:'other',56:'other'};
const uid=()=>globalThis.crypto?.randomUUID?.() ?? `midi-${Math.random().toString(36).slice(2)}`;
const requireValid=(ok,message)=>{if(!ok)throw new Error(message);};
const integer=(v,min,max)=>Number.isInteger(v)&&v>=min&&v<=max;
const normalized=(values,defaults)=>{const sorted=[...values].sort((a,b)=>a.tick-b.tick),result=[];for(const v of sorted){if(result.at(-1)?.tick===v.tick)result[result.length-1]=v;else result.push(v);}if(!result.length||result[0].tick>0)result.unshift(defaults);return result;};
class Reader{
  constructor(bytes){this.bytes=bytes;this.offset=0;}
  get end(){return this.offset>=this.bytes.length;}
  byte(){if(this.end)throw new Error('The MIDI file ends unexpectedly.');return this.bytes[this.offset++];}
  u16(){return this.byte()*256+this.byte();}
  u32(){return this.byte()*16777216+this.byte()*65536+this.byte()*256+this.byte();}
  vlq(){let value=0;for(let i=0;i<4;i++){const b=this.byte();value=value*128+(b&127);if(!(b&128))return value;}throw new Error('Invalid MIDI variable-length quantity.');}
  take(count){requireValid(integer(count,0,this.bytes.length-this.offset),'The MIDI file ends unexpectedly.');const data=this.bytes.subarray(this.offset,this.offset+count);this.offset+=count;return data;}
  ascii(n){return String.fromCharCode(...this.take(n));}
}
export function parseMIDI(data,filename='Imported song.mid'){
  const bytes=data instanceof Uint8Array?data:new Uint8Array(data);requireValid(bytes.byteLength<=100000000,'The MIDI file is too large.');
  const reader=new Reader(bytes);requireValid(reader.ascii(4)==='MThd','This is not a valid Standard MIDI file.');
  const header=reader.u32();requireValid(header>=6,'Invalid MIDI header.');const format=reader.u16(),count=reader.u16(),division=reader.u16();
  requireValid(format===0||format===1,'Use Standard MIDI format 0 or 1.');requireValid(count>=1&&count<=256,'Invalid MIDI track count.');requireValid(!(division&0x8000),'SMPTE-timed MIDI is not supported; export with ticks per quarter note.');requireValid(division>0,'Invalid MIDI time division.');reader.take(header-6);
  const tracks=[],tempos=[],signatures=[];let totalNotes=0;
  for(let trackIndex=0;trackIndex<count;trackIndex++){
    requireValid(reader.ascii(4)==='MTrk',`Malformed MIDI track ${trackIndex+1}.`);const r=new Reader(reader.take(reader.u32())),notes=[],controls=[],held=new Map();let tick=0,running=null,name='';
    while(!r.end){
      tick+=r.vlq();requireValid(tick<=100000000&&notes.length<=250000&&controls.length<=250000&&tempos.length<=10000&&signatures.length<=10000,'MIDI event limits exceeded.');
      const first=r.bytes[r.offset];let status;
      if(first&128){status=r.byte();if(status<0xf0)running=status;}else{requireValid(running!=null,`Malformed running status in track ${trackIndex+1}.`);status=running;}
      if(status===0xff){
        running=null;const type=r.byte(),payload=r.take(r.vlq());
        if(type===3){try{name=new TextDecoder('utf-8',{fatal:true}).decode(payload);}catch{if([...payload].every(b=>b<128))name=String.fromCharCode(...payload);}}
        else if(type===0x51&&payload.length===3){const tempo=payload[0]*65536+payload[1]*256+payload[2];if(tempo>0)tempos.push({tick,microsecondsPerQuarterNote:tempo});}
        else if(type===0x58&&payload.length>=2)signatures.push({tick,numerator:Math.max(payload[0],1),denominator:2**Math.min(payload[1],30)});
        else if(type===0x2f)break;
      }else if(status===0xf0||status===0xf7){running=null;r.take(r.vlq());}
      else{
        const command=status&0xf0,channel=status&15;
        if([0x80,0x90,0xa0,0xb0,0xe0].includes(command)){
          const a=r.byte(),b=r.byte();requireValid(a<128&&b<128,'Malformed MIDI data byte.');const key=channel*128+a;
          if(command===0x90&&b>0){const old=held.get(key),note={tick,noteNumber:a,velocity:b,channel};if(old!=null){notes[old].durationUncertain=true;note.durationUncertain=true;}held.set(key,notes.length);notes.push(note);}
          else if(command===0x80||(command===0x90&&b===0)){const old=held.get(key);if(old!=null){notes[old].durationTicks=tick-notes[old].tick;held.delete(key);}}
          else if(command===0xb0||command===0xe0){controls.push({tick,channel,kind:command===0xb0?'controlChange':'pitchBend',...(command===0xb0?{controller:a}:{}),value:command===0xb0?b:a+(b<<7)});if(command===0xb0&&(a===120||a===123))for(const [key,index]of held)if(Math.floor(key/128)===channel)notes[index].durationUncertain=true;}
        }else if(command===0xc0||command===0xd0)r.byte();
        else throw new Error(`Malformed MIDI track ${trackIndex+1}.`);
      }
    }
    for(const index of held.values())notes[index].durationUncertain=true;
    notes.sort((a,b)=>a.tick-b.tick||a.noteNumber-b.noteNumber);tracks.push({index:trackIndex,name,notes,controls});totalNotes+=notes.length;
    requireValid(totalNotes<=250000,'The MIDI file exceeds 250,000 notes.');
  }
  const playable=tracks.filter(t=>t.notes.length);requireValid(playable.length>0,'This MIDI file contains no note events.');
  const selected=playable.find(t=>t.notes.some(n=>n.channel===9))??playable.reduce((best,t)=>t.notes.length>best.notes.length?t:best);
  const now=new Date().toISOString(),base=filename.replace(/^.*[\\/]/,'').replace(/\.[^.]*$/,'');
  return{id:uid(),instrument:'drums',name:base,sourceFilename:filename,format,ticksPerQuarterNote:division,tempoChanges:normalized(tempos,{tick:0,microsecondsPerQuarterNote:500000}),timeSignatureChanges:normalized(signatures,{tick:0,numerator:4,denominator:4}),tracks,selectedTrackIndex:selected.index,noteMappings:[...new Set(selected.notes.map(n=>n.noteNumber))].sort((a,b)=>a-b).map(noteNumber=>({noteNumber,voice:importedGM[noteNumber]??'unknown'})),createdAt:now,updatedAt:now};
}
export function validateSong(song){
  requireValid(song&&typeof song.id==='string'&&typeof song.name==='string'&&song.name.length<=1024&&integer(song.ticksPerQuarterNote,1,32767),'Invalid MIDI song.');
  requireValid(Array.isArray(song.tracks)&&song.tracks.length<=256&&song.tracks.some(t=>t.index===song.selectedTrackIndex),'Invalid song tracks.');
  let total=0;const indexes=new Set();
  for(const t of song.tracks){requireValid(integer(t.index,0,255)&&!indexes.has(t.index)&&Array.isArray(t.notes)&&t.notes.length<=250000,'Invalid MIDI track.');indexes.add(t.index);total+=t.notes.length;for(const n of t.notes)requireValid(integer(n.tick,0,100000000)&&integer(n.noteNumber,0,127)&&integer(n.velocity,1,127)&&integer(n.channel,0,15),'Invalid MIDI note.');}
  requireValid(total<=250000&&Array.isArray(song.tempoChanges)&&song.tempoChanges.length<=10000&&song.tempoChanges.every(t=>integer(t.tick,0,100000000)&&integer(t.microsecondsPerQuarterNote,1,16777215)),'Invalid MIDI tempo map.');
  requireValid(Array.isArray(song.timeSignatureChanges)&&song.timeSignatureChanges.length<=10000&&song.timeSignatureChanges.every(s=>integer(s.tick,0,100000000)&&integer(s.numerator,1,128)&&integer(s.denominator,1,1073741824)),'Invalid MIDI meter map.');
  requireValid(Array.isArray(song.noteMappings)&&song.noteMappings.length<=128&&new Set(song.noteMappings.map(n=>n.noteNumber)).size===song.noteMappings.length&&song.noteMappings.every(n=>integer(n.noteNumber,0,127)&&Object.hasOwn(voices,n.voice)),'Invalid drum note mapping.');return song;
}
export function songMeasures(song){
  let final=0;for(const t of song.tracks)for(const n of t.notes)final=Math.max(final,n.tick);for(const s of song.timeSignatureChanges)final=Math.max(final,s.tick);
  const signatures=normalized(song.timeSignatureChanges.filter(s=>s.tick>=0&&s.numerator>0&&s.denominator>0),{tick:0,numerator:4,denominator:4}),result=[];let tick=0,index=0;
  while((tick<=final||!result.length)&&result.length<10000){
    while(index+1<signatures.length&&signatures[index+1].tick<=tick)index++;
    const s=signatures[index],ticksPerBeat=Math.max(Math.floor(song.ticksPerQuarterNote*4/s.denominator),1);let end=tick+ticksPerBeat*s.numerator;
    if(signatures[index+1]&&signatures[index+1].tick>tick&&signatures[index+1].tick<end)end=signatures[index+1].tick;
    result.push({number:result.length+1,startTick:tick,endTick:end,numerator:s.numerator,denominator:s.denominator});tick=end;
  }return result;
}
export function songNanoseconds(song,start,end){
  if(end<=start)return 0;
  const tempos=normalized(song.tempoChanges.filter(t=>t.microsecondsPerQuarterNote>0),{tick:0,microsecondsPerQuarterNote:500000});let cursor=start,total=0,index=0;
  for(let i=0;i<tempos.length;i++)if(tempos[i].tick<=start)index=i;
  while(cursor<end){const next=index+1<tempos.length?tempos[index+1].tick:end,segment=Math.min(end,Math.max(cursor,next));total+=(segment-cursor)*tempos[index].microsecondsPerQuarterNote/song.ticksPerQuarterNote;cursor=segment;if(index+1<tempos.length&&cursor>=tempos[index+1].tick)index++;else if(cursor<end&&segment===cursor)break;}
  return Math.round(total*1000);
}
export function songBPM(song,tick=0){const tempo=[...song.tempoChanges].sort((a,b)=>a.tick-b.tick).filter(t=>t.tick<=tick).at(-1);return tempo?60000000/tempo.microsecondsPerQuarterNote:120;}
export function firstSongMeasure(song,includeKicks=true){const track=song.tracks.find(t=>t.index===song.selectedTrackIndex),mapping=new Map(song.noteMappings.map(n=>[n.noteNumber,n.voice])),first=track?.notes.filter(n=>mapping.has(n.noteNumber)&&!['unknown','metronome'].includes(mapping.get(n.noteNumber))&&(includeKicks||mapping.get(n.noteNumber)!=='kick')).reduce((v,n)=>Math.min(v,n.tick),Infinity);return songMeasures(song).find(m=>m.startTick<=first&&m.endTick>first)?.number??1;}
export function makeSongPattern(song,{startMeasure=1,endMeasure=startMeasure,repeats=1,targetBPM=120,tolerance=100}={}){
  validateSong(song);const track=song.tracks.find(t=>t.index===song.selectedTrackIndex),all=songMeasures(song);
  requireValid(integer(startMeasure,1,all.length)&&integer(endMeasure,startMeasure,all.length),'Choose a valid start and end measure.');requireValid(integer(repeats,1,16)&&(endMeasure-startMeasure+1)*repeats<=128,'Use at most 128 measures including repeats.');requireValid(Number.isFinite(targetBPM)&&targetBPM>=40&&targetBPM<=240&&Number.isFinite(tolerance)&&tolerance>=0&&tolerance<=500,'Use 40–240 BPM and valid tolerance.');
  const section=all.slice(startMeasure-1,endMeasure),start=section[0].startTick,end=section.at(-1).endTick,scale=songBPM(song,start)/targetBPM,sectionNS=Math.round(songNanoseconds(song,start,end)*scale),mapping=new Map(song.noteMappings.map(n=>[n.noteNumber,n.voice]));
  const source=track.notes.filter(n=>n.tick>=start&&n.tick<end&&mapping.has(n.noteNumber)&&!['unknown','metronome'].includes(mapping.get(n.noteNumber)));
  requireValid(source.length>0,'Map at least one MIDI note to a drum voice before practicing.');requireValid(source.length*repeats<=10000,'Shorten the song section to at most 10,000 notes.');
  const notes=[],signatures=[],measureStarts=[],references=[];
  for(let r=0;r<repeats;r++)for(let i=0;i<section.length;i++){
    const measure=section[i],offset=r*sectionNS,beatTicks=Math.max(Math.floor(song.ticksPerQuarterNote*4/measure.denominator),1),number=r*section.length+i+1;
    signatures.push({numerator:measure.numerator,denominator:measure.denominator});measureStarts.push((offset+Math.round(songNanoseconds(song,start,measure.startTick)*scale))/1e6);
    for(let b=0;b<measure.numerator;b++)references.push({time:(offset+Math.round(songNanoseconds(song,start,measure.startTick+b*beatTicks)*scale))/1e6,measure:number,beat:b+1,isAccent:b===0});
    const grouped=new Map();for(const n of source)if(n.tick>=measure.startTick&&n.tick<measure.endTick){const group=grouped.get(n.tick)??[];group.push(n);grouped.set(n.tick,group);}
    for(const [tick,group]of [...grouped].sort((a,b)=>a[0]-b[0])){
      const position=tick-measure.startTick,beat=Math.min(Math.floor(position/beatTicks),measure.numerator-1),subdivision=Math.min(Math.max(Math.round((position%beatTicks)/beatTicks*4),0),3),ns=offset+Math.round(songNanoseconds(song,start,tick)*scale),groupID=group.length>1?uid():null;
      for(const n of group)notes.push({id:uid(),voice:mapping.get(n.noteNumber),allowedVoices:[],time:ns/1e6,timeNanoseconds:ns,measure:number,beat:beat+1,subdivision,simultaneousGroupID:groupID,expectedVelocity:n.velocity/127,matchingToleranceNanoseconds:Math.round(tolerance*1e6)});
    }
  }
  notes.sort((a,b)=>a.timeNanoseconds-b.timeNanoseconds||(a.voice<b.voice?-1:a.voice>b.voice?1:0));measureStarts.push(sectionNS*repeats/1e6);
  return{id:uid(),name:song.name,bpm:targetBPM,beatMs:60000/targetBPM,beatsPerMeasure:section[0].numerator,subdivision:'sixteenths',measures:section.length*repeats,durationNanoseconds:sectionNS*repeats,duration:sectionNS*repeats/1e6,notes,measureSignatures:signatures,measureStarts,referenceBeats:references,sourceSongID:song.id,section:{startMeasure,endMeasure,repeats},tempoScale:scale};
}
