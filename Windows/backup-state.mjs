// Validate optional Windows backup state before it touches device profiles or progress.
const requireValid=(ok,message)=>{if(!ok)throw new Error(message);};
const finite=(v,min,max)=>typeof v==='number'&&Number.isFinite(v)&&v>=min&&v<=max;
const object=v=>v&&typeof v==='object'&&!Array.isArray(v)&&!Object.keys(v).some(k=>['__proto__','prototype','constructor'].includes(k));
const text=v=>typeof v==='string'&&v.length<=1024;
const list=(v,limit)=>Array.isArray(v)&&v.length<=limit;
export function validateSettings(settings,voices){
  if(settings==null)return null;requireValid(object(settings),'Invalid saved settings.');
  const numeric={bpm:[40,240],repeats:[1,16],volume:[0,.5],threshold:[.001,1],lockout:[10,200],match:[.01,1],autoDelay:[1,30],cleanRuns:[1,10],advanceStep:[1,20],ceilingStep:[1,20],sectionStart:[1,10000],sectionEnd:[1,10000],tolerance:[0,500],accentFloor:[1,127],accentContrast:[1,127],ghostCeiling:[1,127],ghostContrast:[1,127]};
  for(const [key,[min,max]]of Object.entries(numeric))if(settings[key]!=null)requireValid(finite(Number(settings[key]),min,max),`Invalid ${key} setting.`);
  for(const key of ['auto','advance','ceiling','gradeKicks','soundFilter','guard','accentFloorEnabled','ghostCeilingEnabled'])if(settings[key]!=null)requireValid(typeof settings[key]==='boolean',`Invalid ${key} flag.`);
  if(settings.practiceMode!=null)requireValid(['exercise','song'].includes(settings.practiceMode),'Invalid practice mode.');if(settings.kickSource!=null)requireValid(['midi','microphone','both'].includes(settings.kickSource),'Invalid kick source.');
  for(const key of ['corrections','maps','detectors','microphoneProfiles','songSections'])if(settings[key]!=null)requireValid(object(settings[key])&&Object.keys(settings[key]).length<=2000,`Invalid ${key} collection.`);
  for(const [key,v]of Object.entries(settings.corrections??{}))requireValid(text(key)&&finite(v,-500,500),'Invalid saved timing correction.');
  for(const mapping of Object.values(settings.maps??{}))requireValid(object(mapping)&&Object.keys(mapping).length<=128&&Object.entries(mapping).every(([k,v])=>/^\d+$/.test(k)&&finite(Number(k),0,127)&&Object.hasOwn(voices,v)),'Invalid saved MIDI pad map.');
  for(const config of Object.values(settings.detectors??{}))requireValid(object(config)&&finite(config.threshold,.001,1)&&finite(config.lockout,10,200),'Invalid detector profile.');
  for(const profile of Object.values(settings.microphoneProfiles??{})){
    requireValid(object(profile)&&text(profile.deviceUID)&&text(profile.deviceName)&&finite(profile.suggestedThreshold,.001,1)&&finite(profile.retriggerLockoutMilliseconds,10,200)&&finite(profile.weakestHitAmplitude,0,1)&&finite(profile.signalToNoiseDecibels,-200,200)&&['good','marginal','poor'].includes(profile.quality),'Invalid microphone calibration.');
    const signature=profile.kickSoundSignature;if(signature!=null)requireValid(object(signature)&&Object.values(signature).every(v=>typeof v==='number'&&Number.isFinite(v)&&v>=0)&&['centroidToleranceHertz','lowFrequencyTolerance','highFrequencyTolerance','zeroCrossingTolerance','decayTolerance'].every(k=>signature[k]>0),'Invalid learned kick signature.');
  }
  return settings;
}
export function validateProgress(progress){
  if(progress==null)return null;requireValid(object(progress)&&list(progress.tempoProgressions,2000)&&list(progress.ceilingRecords,2000),'Invalid progression state.');
  for(const p of progress.tempoProgressions)requireValid(object(p)&&text(p.id)&&text(p.exerciseName)&&finite(p.suggestedBPM,40,240)&&Number.isInteger(p.consecutiveCleanSessions)&&finite(p.consecutiveCleanSessions,0,10)&&(p.highestCleanBPM==null||finite(p.highestCleanBPM,40,240)),'Invalid clean-tempo record.');
  for(const c of progress.ceilingRecords)requireValid(object(c)&&text(c.id)&&text(c.exerciseName)&&finite(c.highestVerifiedBPM,40,240)&&finite(c.startingBPM,40,240)&&(c.failedBPM==null||finite(c.failedBPM,40,240)),'Invalid ceiling record.');
  const r=progress.activeCeilingRun;if(r!=null)requireValid(object(r)&&text(r.id)&&text(r.exerciseID)&&finite(r.startingBPM,40,240)&&list(r.sessionIDs,2000)&&list(r.attemptedBPMs,2000)&&r.attemptedBPMs.every(v=>finite(v,40,240))&&object(r.phase)&&['testing','readyForNext','found'].includes(r.phase.kind)&&(['testing','readyForNext'].includes(r.phase.kind)?finite(r.phase.bpm,40,240):r.phase.highestCleanBPM==null||finite(r.phase.highestCleanBPM,40,240)),'Invalid active ceiling run.');
  return progress;
}
