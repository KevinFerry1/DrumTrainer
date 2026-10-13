// PracticeResultCoach from the native Swift drum implementation.
import {voices} from './core.mjs';
const names={...voices,crossStick:'Cross-stick / rim',metronome:'Reference beat'};
const roundEven=v=>{const floor=Math.floor(v),fraction=v-floor;return fraction===.5?(floor%2===0?floor:floor+1):Math.round(v);};
const milliseconds=v=>`${(roundEven(v*10)/10).toFixed(1)} ms`;
const signed=v=>`${v>0?'+':''}${milliseconds(v)}`;
const accuracy=v=>Math.min(v.recall,v.precision);
const isHat=v=>['closedHiHat','openHiHat','pedalHiHat'].includes(v);
function dynamic(evaluation,voice){const results=evaluation?.results.filter(r=>r.voice===voice)??[];return results.length?{results,accuracy:results.filter(r=>r.classification==='achieved').length/results.length}:null;}
function dynamicObservation(kind,d){
  const failed=d.results.filter(r=>r.classification===(kind==='accent'?'belowThreshold':'aboveThreshold')).length,contrast=d.results.filter(r=>r.classification==='insufficientContrast').length,quality=d.accuracy<.4?'very low':'inconsistent';
  const prefix=kind==='accent'?'accent':'ghost-note';
  if(failed>contrast&&failed>0)return `${prefix} accuracy was ${quality} because ${kind==='accent'?'accents were often too soft':'ghost notes were often too loud'}`;
  if(contrast>0)return `${prefix} accuracy was ${quality} because ${kind==='accent'?'accents did not stand out enough':'ghost notes were not quiet enough relative to normal hits'}`;
  return `${prefix} accuracy was ${quality}`;
}
export function summarizePractice(pattern,metrics){
  const stable=metrics.stableTiming,observations=[];
  if(stable)observations.push(`Your groove was steady despite a shared ${signed(stable.biasMilliseconds)} raw offset, so grading used the ${milliseconds(stable.adjustedMedianAbsoluteErrorMilliseconds)} groove error.`);
  const perVoice=metrics.perVoice??[],order=Object.keys(names);
  for(const v of perVoice.filter(v=>v.totalExpected>0).sort((a,b)=>b.totalExpected-a.totalExpected||order.indexOf(a.voice)-order.indexOf(b.voice)).slice(0,3)){
    const a=accuracy(v),clauses=[`${names[v.voice]??v.voice} ${a>=.95?'was very accurate':a>=.85?'was mostly accurate':a>=.7?'was uneven':'accuracy needs work'} (${roundEven(v.recall*100)}% recall)`];
    if(v.precision<.85&&v.extraCount>0)clauses.push(`${v.extraCount} extra ${v.extraCount===1?'hit':'hits'}`);
    const error=v.medianAbsoluteErrorMilliseconds;
    if(!stable&&error!=null)clauses.push(error<=20?'timing was on target':error<=40?'timing was mostly on target':error<=70?'timing was loose':'timing was well off the click');
    for(const [kind,evaluation]of [['accent',metrics.accents],['ghost',metrics.ghosts]]){const d=dynamic(evaluation,v.voice);if(d&&d.accuracy<.9)clauses.push(dynamicObservation(kind,d));}
    observations.push(clauses.join('; ')+'.');
  }
  let nextStep=null;
  const sync=metrics.limbSynchronization,groups=new Map();
  for(const n of pattern.notes??[]){const id=n.simultaneousGroupID??n.group;if(id){const group=groups.get(id)??new Set();group.add(n.voice);groups.set(id,group);}}
  if(sync?.completedGroupCount>0&&[...groups.values()].some(g=>g.has('snare')&&[...g].some(isHat))){
    const snare=sync.voiceOffsets.find(v=>v.voice==='snare'),hat=sync.voiceOffsets.filter(v=>isHat(v.voice)).reduce((best,v)=>!best||v.sampleCount>=best.sampleCount?v:best,null);
    if(snare&&hat){const separation=snare.medianOffsetFromGroupCenterMilliseconds-hat.medianOffsetFromGroupCenterMilliseconds;if(Math.abs(separation)>=15)nextStep=`Try to land the snare and ${names[hat.voice].toLowerCase()} together; the snare averaged about ${milliseconds(Math.abs(separation))} ${separation>0?'behind':'ahead of'} the hat on completed unison hits.`;}
  }
  if(!nextStep&&stable)nextStep=`Re-run hit timing alignment for the active drums; the shared ${signed(stable.biasMilliseconds)} offset looks more like fixed latency than random timing.`;
  if(!nextStep){
    let issue=null;
    for(const v of perVoice){const accent=dynamic(metrics.accents,v.voice),ghost=dynamic(metrics.ghosts,v.voice),candidate=accent&&accent.accuracy<.7?{accuracy:accent.accuracy,text:`Exaggerate the ${names[v.voice].toLowerCase()} accents for one slow run, making each one clearly louder than the nearby normal hits.`}:ghost&&ghost.accuracy<.7?{accuracy:ghost.accuracy,text:`Play the ${names[v.voice].toLowerCase()} ghost notes noticeably softer for one slow run while keeping their placement unchanged.`}:null;if(candidate&&(!issue||candidate.accuracy<issue.accuracy))issue=candidate;}
    if(issue)nextStep=issue.text;
  }
  if(!nextStep){const weakest=perVoice.filter(v=>v.totalExpected>0).reduce((best,v)=>!best||accuracy(v)<accuracy(best)?v:best,null);if(weakest&&accuracy(weakest)<.85)nextStep=`Slow the exercise down and focus on the ${names[weakest.voice].toLowerCase()} part alone until the misses and extra hits disappear.`;}
  if(!nextStep){const loosest=perVoice.filter(v=>v.medianAbsoluteErrorMilliseconds!=null).reduce((best,v)=>!best||v.medianAbsoluteErrorMilliseconds>=best.medianAbsoluteErrorMilliseconds?v:best,null);if(loosest?.medianAbsoluteErrorMilliseconds>40)nextStep=`Loop the ${names[loosest.voice].toLowerCase()} part slowly and aim for the center of each click before raising the tempo.`;}
  return {overview:observations.length?observations.join(' '):'There were not enough graded notes to produce a useful summary.',nextStep:nextStep??'Repeat once at the same tempo and try to preserve the same relaxed spacing.'};
}
