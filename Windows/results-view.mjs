// Presentation follows PracticeView.results and HistoryView.recentSessions in the Mac app.
// All values come from the existing scoring output; this module does not score hits.
import {voices} from './core.mjs';
import {drawNotation} from './notation.mjs';
export const resultPercent=value=>Number.isFinite(value)?`${(value*100).toFixed(1)}%`:'—';
export const resultMilliseconds=value=>Number.isFinite(value)?`${value.toFixed(1)} ms`:'—';
const signed=value=>Number.isFinite(value)?`${value>=0?'+':''}${resultMilliseconds(value)}`:'—';
const number=value=>Number.isFinite(value)?String(value):'—';
const velocity=value=>Number.isFinite(value)?String(Math.round(Math.min(1,Math.max(0,value))*127)):'—';
function node(document,tag,className='',text=null){const element=document.createElement(tag);element.className=className;if(text!=null)element.textContent=String(text);return element;}
function card(document,title,value,detail,compact=true){
  const element=node(document,'div',compact?'compact-metric':'native-metric');
  const heading=node(document,'div','metric-heading');heading.append(node(document,'span','',title),node(document,'strong','',value));
  element.append(heading,node(document,'span','metric-detail',detail));return element;
}
function table(document,headers,rows){
  const wrap=node(document,'div','native-table-scroll'),element=node(document,'table','native-table'),head=node(document,'thead'),header=node(document,'tr'),body=node(document,'tbody');
  for(const title of headers)header.append(node(document,'th','',title));head.append(header);
  for(const values of rows){const row=node(document,'tr');for(const value of values){const cell=node(document,'td');if(value?.nodeType)cell.append(value);else cell.textContent=value??'—';row.append(cell);}body.append(row);}
  element.append(head,body);wrap.append(element);return wrap;
}
function group(document,title){const element=node(document,'fieldset','result-group');element.append(node(document,'legend','',title));return element;}
export function historySessionClean({s,summaryOnly}){
  if(!summaryOnly)return s.metrics.clean===true;
  const passesDynamics=value=>value==null||(value.expectedCount>0&&value.accuracy>=.9);
  return s.totalExpected>0&&s.recall>=.95&&(s.latencyAdjustedMedianErrorMilliseconds??s.medianAbsoluteErrorMilliseconds??Infinity)<=25&&!s.droppedEventCount&&passesDynamics(s.accentMetrics)&&passesDynamics(s.ghostMetrics);
}
export function historySessionRow(document,entry,{onDetails}={}){
  const {s,date,summaryOnly}=entry,row=node(document,'div','history-row native-history-row'),copy=node(document,'div','history-exercise');
  copy.append(node(document,'strong','',s.name??s.exerciseName),node(document,'small','',date.toLocaleString(undefined,{month:'short',day:'numeric',hour:'numeric',minute:'2-digit'})));
  const recall=summaryOnly?s.recall:s.metrics.recall,error=summaryOnly?s.medianAbsoluteErrorMilliseconds:s.metrics.error;
  row.append(copy,node(document,'span','history-bpm',`${Math.round(s.bpm)} BPM`),node(document,'span','history-recall',resultPercent(recall)),node(document,'span','history-error',resultMilliseconds(error)));
  const status=node(document,'span',historySessionClean(entry)?'session-status clean-status':'session-status needs-work');
  if(historySessionClean(entry)){
    // A filled checkmark seal, matching the native checkmark.seal.fill label.
    status.innerHTML='<svg viewBox="0 0 24 24" aria-hidden="true"><path fill="currentColor" d="m12 1 3 2.2 3.7.1 1.2 3.5 2.9 2.3-1.1 3.5.1 3.7-3.4 1.4-2.1 3.1-3.6-.9-3.6.9L7 19.7l-3.4-1.4.1-3.7-1.1-3.5 2.9-2.3 1.2-3.5 3.7-.1Z"/><path d="m7.5 12 3 3 6-6" fill="none" stroke="#252525" stroke-width="2.2" stroke-linecap="round" stroke-linejoin="round"/></svg>';
    status.append(document.createTextNode('Clean'));
  }else status.textContent='Needs work';
  row.append(status,node(document,'span','history-spacer'));
  if(!summaryOnly){const details=node(document,'button','history-details','Details');details.onclick=()=>onDetails?.(s);row.append(details);}
  return row;
}
export function exerciseProgressTable(document,entries,progress){
  const groups=new Map();
  for(const entry of entries){const name=entry.s.name??entry.s.exerciseName,list=groups.get(name)??[];list.push(entry);groups.set(name,list);}
  if(!groups.size)return node(document,'p','hint','Complete an exercise to start tracking progress.');
  return table(document,['Exercise','Sessions','Best recall','Highest clean tempo','Verified ceiling','Last practiced'],[...groups].sort((a,b)=>Math.max(...b[1].map(e=>+e.date))-Math.max(...a[1].map(e=>+e.date))).map(([name,list])=>{
    const clean=list.filter(historySessionClean),ceilings=(progress.ceilingRecords??[]).filter(r=>r.exerciseName===name),latest=new Date(Math.max(...list.map(e=>+e.date)));
    return[name,list.length,resultPercent(Math.max(...list.map(e=>e.summaryOnly?e.s.recall:e.s.metrics.recall))),clean.length?`${Math.round(Math.max(...clean.map(e=>e.s.bpm)))} BPM`:'—',ceilings.length?`${Math.round(Math.max(...ceilings.map(r=>r.highestVerifiedBPM)))} BPM`:'—',latest.toLocaleDateString(undefined,{month:'short',day:'numeric',year:'numeric'})];
  }));
}
function dynamicsGroup(document,kind,evaluation,pattern){
  const accent=kind==='accent',box=group(document,accent?'Accent dynamics':'Ghost dynamics'),metrics=evaluation.metrics,grid=node(document,'div','dynamics-metrics');
  const notEvaluated=metrics.notEvaluatedCount??(metrics.missedCount??0)+(metrics.velocityUnavailableCount??0)+(metrics.baselineUnavailableCount??0);
  for(const [title,value,detail]of [[accent?'Accent accuracy':'Ghost accuracy',resultPercent(metrics.accuracy),'≥90% required for a clean run'],['Achieved',`${metrics.achievedCount} / ${metrics.expectedCount}`,'Enough same-voice dynamic contrast'],[accent?'Needs contrast':'Too loud',number(accent?metrics.belowThresholdCount:metrics.aboveThresholdCount),accent?'Below the relative target or optional floor':'Above the relative target or optional maximum'],['Not evaluated',number(notEvaluated),'Missed note, missing velocity, or no baseline']])grid.append(card(document,title,value,detail));
  const details=node(document,'details','dynamic-note-details');details.append(node(document,'summary','',`Note details (${evaluation.results.length})`));
  const notes=new Map(pattern.notes.map(n=>[n.id,n]));
  const names={achieved:'Achieved',belowThreshold:'Too soft',aboveThreshold:'Too loud',insufficientContrast:'Needs contrast',missed:'Missed',velocityUnavailable:'No velocity',baselineUnavailable:'No baseline'};
  details.append(table(document,['Position','Voice','Baseline','Target','Played','Result'],evaluation.results.map(result=>{
    const expected=notes.get(result.expectedEventID),only=result.usedMinimumOnly||result.didUseMinimumOnly||result.usedMaximumOnly||result.didUseMaximumOnly;
    const target=result.requiredVelocity==null?'—':`${accent?'≥':'≤'}${velocity(result.requiredVelocity)}${only?(accent?' minimum only':' maximum only'):''}`;
    return[expected?`M${expected.measure} B${expected.beat}.${expected.subdivision+1}`:'—',voices[result.voice]??result.voice,velocity(result.baselineVelocity),target,velocity(result.actualVelocity),node(document,'span',result.classification==='achieved'?'result-green':'result-orange',names[result.classification]??result.classification)];
  })));
  box.append(grid,details);return box;
}
export function renderSessionResult(document,session,coaching){
  const $=id=>document.getElementById(id),m=session.metrics,stable=m.stableTiming,pattern=session.pattern;
  $('resultTitle').textContent='Practice results';
  $('resultSubtitle').textContent=`${pattern.name??session.name} · ${Math.round(session.bpm)} BPM · ${pattern.measures} measures${session.demo?' · Simulated':''}`;
  $('coachingOverview').textContent=coaching.overview;$('coachingNext').textContent=`Next try: ${coaching.nextStep}`;
  $('metrics').replaceChildren(...[
    ['Note recall',resultPercent(m.recall),'Correct expected notes'],['Precision',resultPercent(m.precision),'Correct played notes'],
    [stable?'Groove error':'Median error',resultMilliseconds(stable?.adjustedMedianAbsoluteErrorMilliseconds??m.error),stable?'After stable-bias adjustment':'Absolute timing'],['Timing bias',signed(m.bias),'Negative is early']
  ].map(values=>card(document,...values)));
  $('stableTiming').hidden=!stable;
  if(stable)$('stableTiming').textContent=`Stable ${signed(stable.biasMilliseconds)} offset across ${stable.sampleCount} hits. Groove grading used ${resultMilliseconds(stable.adjustedMedianAbsoluteErrorMilliseconds)}; raw median error was ${resultMilliseconds(stable.rawMedianAbsoluteErrorMilliseconds)}. This can indicate fixed audio/MIDI latency—re-run hit timing alignment for the active drums.`;
  $('ungradedKicks').hidden=session.options?.gradeKicks!==false;
  $('ungradedKickLegend').hidden=session.options?.gradeKicks!==false;
  $('dynamicsResults').replaceChildren(...[['accent',m.accents],['ghost',m.ghosts]].filter(([,value])=>value).map(([kind,value])=>dynamicsGroup(document,kind,value,pattern)));
  $('hitBreakdown').replaceChildren(...[['Correct',m.correct,'green'],['Missed',m.missed,'orange'],['Extra',m.extra,'purple'],['Wrong voice',m.wrong,'red'],['Ambiguous',m.ambiguous??0,'muted']].map(([title,value,color])=>{const item=node(document,'div','hit-count');item.append(node(document,'strong',`result-${color}`,number(value)),node(document,'span','',title));return item;}));
  const timing=[`← Early: ${number(m.earlyCount)}`,`→ Late: ${number(m.lateCount)}`,`Mean absolute error: ${resultMilliseconds(m.meanAbsoluteErrorMilliseconds)}`];
  if(stable)timing.push(`Raw median error: ${resultMilliseconds(m.error)}`);
  timing.push(`Consistency (σ): ${resultMilliseconds(m.consistency)}`,`Longest clean streak: ${number(m.longestCleanStreak)}`);
  $('timingDetails').replaceChildren(...timing.map(text=>node(document,'span','',text)));
  const accuracy=(evaluation,voice)=>{const results=evaluation?.results.filter(r=>r.voice===voice)??[];return results.length?resultPercent(results.filter(r=>r.classification==='achieved').length/results.length):'—';};
  $('voiceResults').hidden=!m.perVoice?.length;
  $('voiceMetrics').replaceChildren(table(document,['Voice','Expected / played','Correct','Missed','Extra','Wrong','Ambiguous','Recall','Precision','Accent accuracy','Ghost accuracy','Bias','Median error','Consistency σ'],(m.perVoice??[]).map(v=>[
    voices[v.voice]??v.voice,`${v.totalExpected??v.expected} / ${v.totalPlayed??v.played}`,node(document,'span','result-green',v.correctCount??v.correct),number(v.missedCount),number(v.extraCount),number(v.wrongVoiceCount),number(v.ambiguousCount),resultPercent(v.recall),resultPercent(v.precision),accuracy(m.accents,v.voice),accuracy(m.ghosts,v.voice),signed(v.meanSignedOffsetMilliseconds),resultMilliseconds(v.medianAbsoluteErrorMilliseconds??v.error),resultMilliseconds(v.timingStandardDeviationMilliseconds)
  ])));
  const synchronization=m.limbSynchronization;$('limbResults').hidden=!synchronization;$('limbMetrics').replaceChildren();$('limbOffsets').replaceChildren();
  if(synchronization){
    $('limbMetrics').append(...[
      ['Complete groups',`${synchronization.completedGroupCount} / ${synchronization.eligibleGroupCount}`,'All intended voices matched'],['Average spread',resultMilliseconds(synchronization.averageSpreadMilliseconds),'Latest minus earliest'],['Median spread',resultMilliseconds(synchronization.medianSpreadMilliseconds),'Typical limb alignment'],['Worst spread',resultMilliseconds(synchronization.worstSpreadMilliseconds),'Largest complete group']
    ].map(values=>card(document,...values,false)));
    const incomplete=synchronization.eligibleGroupCount-synchronization.completedGroupCount;$('incompleteGroups').hidden=!incomplete;$('incompleteGroups').textContent=`${incomplete} simultaneous group(s) were incomplete and excluded from spread statistics.`;
    if(synchronization.voiceOffsets.length)$('limbOffsets').append(node(document,'h4','',"Voice position relative to each group's center"),table(document,['Voice','Mean offset','Median offset','Groups'],synchronization.voiceOffsets.map(v=>[voices[v.voice]??v.voice,signed(v.meanOffsetFromGroupCenterMilliseconds),signed(v.medianOffsetFromGroupCenterMilliseconds),v.sampleCount])));
  }
  $('sequenceResults').hidden=!pattern.measureLabels;$('sequenceReview').replaceChildren();
  if(pattern.measureLabels){for(let measure=1;measure<=pattern.measures;measure++){
    const notes=pattern.notes.filter(n=>n.measure===measure&&(session.options?.gradeKicks!==false||n.voice!=='kick')),ids=new Set(notes.map(n=>n.id)),correct=(m.results??[]).filter(r=>ids.has(r.expectedEventID??r.expected?.id)&&(r.status??r.classification)==='correct').length;
    const row=node(document,'div','sequence-review-row');row.append(node(document,'span','',`${measure}. ${pattern.measureLabels[measure-1]??'Measure'}`));if(measure>1&&pattern.measureLabels[measure-1]!==pattern.measureLabels[measure-2])row.append(node(document,'span','transition-label','→ Transition'));row.append(node(document,'span','sequence-review-count',notes.length?`${correct}/${notes.length} correct`:'Ungraded'));$('sequenceReview').append(row);
  }}
  $('droppedEvidence').hidden=!session.options?.dropped;$('droppedEvidence').textContent=`${session.options?.dropped??0} session events were dropped; treat these results as incomplete.`;
  $('experimentalResult').hidden=!session.experimental;
  $('ceilingMessage').hidden=true;$('progressionMessage').hidden=true;
}
const scoreCache=new WeakMap();
export function drawResultScore(document,session,dpr=1){
  const scroll=document.getElementById('resultScoreScroll'),canvas=document.getElementById('resultScore'),track=document.getElementById('resultScoreTrack'),width=scroll.clientWidth;
  if(!session||document.getElementById('result').hidden||!width)return;
  const key=[session.id,session.metrics, width,scroll.scrollLeft,dpr,session.options?.gradeKicks];const previous=scoreCache.get(canvas);
  if(previous&&key.every((v,i)=>v===previous[i]))return;scoreCache.set(canvas,key);
  track.style.width=`${58+320*session.pattern.measures}px`;canvas.style.width=`${width}px`;canvas.width=Math.round(width*dpr);canvas.height=Math.round(156*dpr);
  const context=canvas.getContext('2d');context.setTransform(dpr,0,0,dpr,0,0);context.clearRect(0,0,width,156);
  drawNotation(context,width,session.pattern,{metrics:session.metrics,fixedMeasureWidth:320,compact:true,scrollOffset:scroll.scrollLeft,gradeKicks:session.options?.gradeKicks!==false});
}
