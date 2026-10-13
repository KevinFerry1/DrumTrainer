// Mirrors native tempo-progression and CeilingRun decisions; interrupted attempts never call record.
const clamp=(v,min,max)=>Math.min(Math.max(v,min),max);
const uid=()=>globalThis.crypto?.randomUUID?.()??`ceiling-${Math.random().toString(36).slice(2)}`;
export function exerciseIdentity({name,kind='builtIn',customExerciseID=null,importedSongID=null}){
  return kind==='custom'?customExerciseID?`custom:${customExerciseID.toUpperCase()}`:`custom-name:${name}`:kind==='importedSong'?importedSongID?`imported:${importedSongID.toUpperCase()}`:`imported-name:${name}`:`built-in:${name}`;
}
export function emptyProgress(){return{tempoProgressions:[],ceilingRecords:[],activeCeilingRun:null};}
export function prepareCeiling(progress,identity,bpm,date=new Date().toISOString()){
  let run=progress.activeCeilingRun;
  if(!run||run.exerciseID!==identity.id||run.phase.kind==='found')run={id:uid(),exerciseID:identity.id,exerciseName:identity.name,exerciseKind:identity.kind,customExerciseID:identity.customExerciseID??null,startedAt:date,updatedAt:date,startingBPM:clamp(bpm,40,240),highestCleanBPM:null,attemptedBPMs:[],sessionIDs:[],phase:{kind:'testing',bpm:clamp(bpm,40,240)}};
  else if(run.phase.kind==='readyForNext')run.phase={kind:'testing',bpm:run.phase.bpm};
  run.updatedAt=date;progress.activeCeilingRun=run;return run.phase.bpm;
}
export function recordProgress(progress,session,{advance=false,requiredCleanSessions=3,stepBPM=5,ceiling=false,ceilingStepBPM=5}={}){
  const id=exerciseIdentity({name:session.name,kind:session.exerciseKind,customExerciseID:session.customExerciseID,importedSongID:session.importedSongID});
  let entry=progress.tempoProgressions.find(p=>p.id===id);
  if(!entry){entry={id,exerciseName:session.name,suggestedBPM:session.bpm,consecutiveCleanSessions:0,highestCleanBPM:null,updatedAt:session.date};progress.tempoProgressions.push(entry);}
  entry.updatedAt=session.date;entry.suggestedBPM=session.bpm;
  if(session.metrics.clean)entry.highestCleanBPM=Math.max(entry.highestCleanBPM??session.bpm,session.bpm);
  let nextBPM=session.bpm,message=session.metrics.clean?'Clean run.':'Clean-run streak reset; keep this tempo for another pass.',found=false;
  if(advance&&!ceiling){
    entry.consecutiveCleanSessions=session.metrics.clean?entry.consecutiveCleanSessions+1:0;
    if(entry.consecutiveCleanSessions>=clamp(requiredCleanSessions,1,10)){nextBPM=clamp(session.bpm+clamp(stepBPM,1,20),40,240);entry.suggestedBPM=nextBPM;entry.consecutiveCleanSessions=0;message=`Advanced ${session.name} to ${nextBPM} BPM.`;}
    else if(session.metrics.clean)message=`Clean run ${entry.consecutiveCleanSessions}/${requiredCleanSessions} toward the next tempo.`;
  }
  progress.tempoProgressions.sort((a,b)=>new Date(b.updatedAt)-new Date(a.updatedAt));
  const run=progress.activeCeilingRun;
  if(ceiling&&run?.exerciseID===id){
    run.updatedAt=session.date;run.attemptedBPMs.push(session.bpm);run.sessionIDs.push(session.id);
    if(session.metrics.clean){
      run.highestCleanBPM=Math.max(run.highestCleanBPM??session.bpm,session.bpm);
      if(session.bpm>=240){found=true;run.phase={kind:'found',highestCleanBPM:run.highestCleanBPM,failedBPM:null};message='Ceiling verified at the app maximum: 240 BPM.';}
      else{nextBPM=Math.min(session.bpm+clamp(ceilingStepBPM,1,20),240);run.phase={kind:'readyForNext',bpm:nextBPM};message=`Clean at ${session.bpm} BPM. Next round: ${nextBPM} BPM.`;}
    }else{found=true;run.phase={kind:'found',highestCleanBPM:run.highestCleanBPM,failedBPM:session.bpm};message=run.highestCleanBPM==null?`Your ceiling is below ${session.bpm} BPM. Lower the tempo and start a new search.`:`Ceiling found: ${run.highestCleanBPM} BPM. The ${session.bpm} BPM round did not pass cleanly.`;}
    if(found&&run.highestCleanBPM!=null){
      const candidate={id:run.exerciseID,exerciseName:run.exerciseName,highestVerifiedBPM:run.highestCleanBPM,achievedAt:run.updatedAt,ceilingRunID:run.id,startingBPM:run.startingBPM,failedBPM:run.phase.failedBPM,roundsCompleted:run.sessionIDs.length},index=progress.ceilingRecords.findIndex(c=>c.id===id);
      if(index<0)progress.ceilingRecords.push(candidate);else if(candidate.highestVerifiedBPM>=progress.ceilingRecords[index].highestVerifiedBPM)progress.ceilingRecords[index]=candidate;
      progress.ceilingRecords.sort((a,b)=>new Date(b.achievedAt)-new Date(a.achievedAt));
    }
  }
  return{nextBPM,message,found};
}
export function mergeNativeProgress(progress,archives){
  const date=n=>typeof n==='number'?new Date((n+978307200)*1000).toISOString():n;
  for(const a of archives){
    for(const p of a.tempoProgressions??[])if(!progress.tempoProgressions.some(old=>old.id===p.id))progress.tempoProgressions.push({...p,updatedAt:date(p.updatedAt)});
    for(const c of a.ceilingRecords??[])if(!progress.ceilingRecords.some(old=>old.id===c.id))progress.ceilingRecords.push({...c,achievedAt:date(c.achievedAt)});
    if(!progress.activeCeilingRun&&a.activeCeilingRun){const r=structuredClone(a.activeCeilingRun),kind=Object.keys(r.phase)[0];r.phase={kind,...r.phase[kind]};r.startedAt=date(r.startedAt);r.updatedAt=date(r.updatedAt);progress.activeCeilingRun=r;}
  }return progress;
}
