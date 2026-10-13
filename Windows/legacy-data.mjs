// Convert native drum evidence for the Windows UI without discarding the original archive.
import {normalizeExpected,normalizeActual,nativeScore,stableTimingBias} from './native-scoring.mjs';
import {validateSong} from './midi.mjs';
const isoDate=value=>typeof value==='number'?new Date((value+978307200)*1000).toISOString():new Date(value).toISOString();
const finite=(n,min,max)=>typeof n==='number'&&Number.isFinite(n)&&n>=min&&n<=max;
const requireValid=(ok,message)=>{if(!ok)throw new Error(message);};
export function nativePattern(pattern){
  requireValid(pattern&&typeof pattern.name==='string'&&finite(pattern.bpm,40,240)&&Array.isArray(pattern.expectedEvents)&&pattern.expectedEvents.length<=10000,'Invalid native practice pattern.');
  const start=pattern.startSessionTimeNanoseconds??Math.min(...pattern.expectedEvents.map(e=>e.sessionTimeNanoseconds)),duration=pattern.durationNanoseconds??Math.round(pattern.measures*pattern.beatsPerMeasure*60000000000/pattern.bpm);
  requireValid(finite(start,-Number.MAX_SAFE_INTEGER,Number.MAX_SAFE_INTEGER)&&finite(duration,0,3600000000000),'Native pattern timing is outside supported bounds.');
  const notes=normalizeExpected(pattern.expectedEvents.map(e=>{
    requireValid(e&&typeof e.id==='string'&&finite(e.sessionTimeNanoseconds,-Number.MAX_SAFE_INTEGER,Number.MAX_SAFE_INTEGER)&&typeof e.voice==='string','Invalid native expected event.');
    const ns=e.sessionTimeNanoseconds-start;
    return{...e,sessionTimeNanoseconds:ns,timeNanoseconds:ns,time:ns/1e6};
  }));
  const refs=(pattern.referenceBeats??Array.from({length:pattern.measures*pattern.beatsPerMeasure},(_,i)=>({offsetNanoseconds:Math.round(i*60000000000/pattern.bpm),measure:Math.floor(i/pattern.beatsPerMeasure)+1,beat:i%pattern.beatsPerMeasure+1,isAccent:i%pattern.beatsPerMeasure===0}))).map(b=>({time:b.offsetNanoseconds/1e6,measure:b.measure,beat:b.beat,isAccent:b.isAccent}));
  return{id:pattern.id,name:pattern.name,bpm:pattern.bpm,beatMs:60000/pattern.bpm,beatsPerMeasure:pattern.beatsPerMeasure,subdivision:pattern.subdivision,measures:pattern.measures,durationNanoseconds:duration,duration:duration/1e6,notes,referenceBeats:refs,measureStarts:pattern.measureStartOffsetsNanoseconds?.map(n=>n/1e6),measureSignatures:pattern.measureSignatures,measureSubdivisions:pattern.measureSubdivisions,measureLabels:pattern.measureLabels};
}
function nativeRecord(record){
  const summary=record.summary,pattern=nativePattern(record.pattern),start=record.pattern.startSessionTimeNanoseconds??Math.min(...record.pattern.expectedEvents.map(n=>n.sessionTimeNanoseconds));
  requireValid(summary&&typeof summary.id==='string'&&Array.isArray(record.actualEvents)&&record.actualEvents.length<=10000&&Array.isArray(record.matchResults)&&record.matchResults.length<=20000&&record.metrics,'Invalid native session evidence.');
  const evidence=record.actualEvents.map(a=>{
    requireValid(a&&typeof a.id==='string'&&finite(a.sessionTimeNanoseconds,-Number.MAX_SAFE_INTEGER,Number.MAX_SAFE_INTEGER),'Invalid native played event.');
    const ns=a.sessionTimeNanoseconds-start;
    return{...a,sessionTimeNanoseconds:ns,timeNanoseconds:ns,time:ns/1e6,velocityNormalized:a.velocity??null,velocity:a.velocity==null?null:a.velocity*127,rawTimestamp:a.hostTime};
  });
  const expectedByID=new Map(pattern.notes.map(e=>[e.id,e])),actualByID=new Map(normalizeActual(evidence).map(a=>[a.id,a]));
  const results=record.matchResults.map(r=>{
    const expected=expectedByID.get(r.expectedEventID)??null,originalActual=actualByID.get(r.actualEventID)??null,correctedNS=r.actualTimeNanoseconds==null?null:r.actualTimeNanoseconds-start;
    const actual=originalActual?{...originalActual,rawTime:originalActual.time,time:correctedNS==null?originalActual.time:correctedNS/1e6}:null;
    return{...r,status:r.classification,expected,actual,expectedTimeNanoseconds:r.expectedTimeNanoseconds==null?null:r.expectedTimeNanoseconds-start,actualTimeNanoseconds:correctedNS,offset:r.signedOffsetMilliseconds??null};
  });
  const native=record.metrics,perVoice=(native.perVoice??[]).map(v=>({...v,expected:v.totalExpected,played:v.totalPlayed,correct:v.correctCount,error:v.medianAbsoluteErrorMilliseconds??null}));
  const options={gradeKicks:record.scoringConfiguration?.gradeKicks??true,dropped:summary.droppedEventCount??0,corrections:{midi:record.deviceContext?.midiTimingCompensationMilliseconds??0,microphone:record.deviceContext?.microphoneTimingCompensationMilliseconds??0}};
  const stable=stableTimingBias(results),clean=!(options.dropped)&&native.totalExpected>0&&native.recall>=.95&&(summary.latencyAdjustedMedianErrorMilliseconds??native.medianAbsoluteErrorMilliseconds??Infinity)<=25&&(summary.accentMetrics?.accuracy??1)>=.9&&(summary.ghostMetrics?.accuracy??1)>=.9;
  const metrics={...native,perVoice,results,expected:native.totalExpected,played:native.totalPlayed,correct:native.correctCount,missed:native.missedCount,extra:native.extraCount,wrong:native.wrongVoiceCount,ambiguous:native.ambiguousCount,error:native.medianAbsoluteErrorMilliseconds??null,bias:native.meanSignedOffsetMilliseconds??null,consistency:native.timingStandardDeviationMilliseconds??null,spread:native.limbSynchronization?.medianSpreadMilliseconds??null,stableTiming:stable,clean,scoringVersion:summary.scoringVersion,archived:true};
  return{id:summary.id,name:summary.exerciseName,bpm:summary.bpm,date:isoDate(summary.completedAt),pattern,evidence,metrics,options,notes:record.notes??'',tags:record.tags??[],source:'mac',exerciseKind:summary.exerciseKind,customExerciseID:summary.customExerciseID,importedSongID:summary.importedSongID,deviceContext:record.deviceContext,devices:{midi:record.deviceContext?.midiDeviceName,microphone:record.deviceContext?.audioInputName,output:record.deviceContext?.audioOutputName}};
}
export function convertNativeArchives(archives){
  const sessions=new Map(),songs=new Map();
  for(const a of archives){
    requireValid(Array.isArray(a.sessionRecords??[])&&(a.sessionRecords?.length??0)<=2000&&(a.importedSongs?.length??0)<=500,'Native archive exceeds collection limits.');
    for(const record of a.sessionRecords??[])if(!record.summary?.instrument||record.summary.instrument==='drums'){const session=nativeRecord(record);if(!sessions.has(session.id))sessions.set(session.id,session);}
    for(const song of a.importedSongs??[])if(!song.instrument||song.instrument==='drums'){validateSong(song);if(!songs.has(song.id))songs.set(song.id,structuredClone(song));}
  }
  return{sessions:[...sessions.values()],songs:[...songs.values()]};
}
export function rescoreSession(session){
  const metrics=nativeScore(session.pattern,session.evidence,session.options);
  return{...session,metrics,rescoredAt:new Date().toISOString()};
}
export function compactSession(session){
  const results=(session.metrics.results??[]).map(r=>{
    if(r.expectedEventID===undefined)return r; // Keep older preview row evidence compatible.
    const {expected,actual,...decision}=r;return decision;
  });
  return{...session,metrics:{...session.metrics,results}};
}
export function hydrateSession(session){
  const expected=new Map(normalizeExpected(session.pattern.notes).map(e=>[e.id,e])),actual=new Map(normalizeActual(session.evidence).map(a=>[a.id,a]));
  const results=(session.metrics.results??[]).map(r=>{
    if(r.expectedEventID===undefined)return r;
    const e=expected.get(r.expectedEventID)??null,a=actual.get(r.actualEventID)??null,corrected=r.actualTimeNanoseconds==null?a?.time:r.actualTimeNanoseconds/1e6;
    return{...r,expected:e,actual:a?{...a,rawTime:a.time,time:corrected}:null};
  });
  return{...session,metrics:{...session.metrics,results}};
}
