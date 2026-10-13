// Port of EventMatcher.swift and ScoringMetrics.swift. Nanosecond comparisons preserve native ties.
const compare = (a,b) => a < b ? -1:a > b ? 1:0;
const voiceOrder = ['kick','snare','crossStick','highTom','midTom','lowTom','closedHiHat','openHiHat','pedalHiHat','ride','rideBell','crash1','crash2','china','splash','metronome','other','unknown'];
export const median = values => { if (!values.length) return null; const sorted = [...values].sort((a,b) => a-b), m=Math.floor(sorted.length/2); return sorted.length%2 ? sorted[m]:(sorted[m-1]+sorted[m])/2; };
const mean = values => values.length ? values.reduce((a,b) => a+b,0)/values.length:null;
const deviation = values => { const center=mean(values); return center == null ? null:Math.sqrt(values.reduce((sum,v) => sum+(v-center)**2,0)/values.length); };
const timeNS = note => note.sessionTimeNanoseconds ?? note.timeNanoseconds ?? Math.round(note.time*1e6);
const velocity = note => note.velocityNormalized !== undefined ? note.velocityNormalized : note.velocity == null ? null:note.velocity/127;
const accepts = (e,a) => e.voice === a.voice || (e.allowedVoices ?? []).includes(a.voice);
export function normalizeExpected(notes,options={}) {
  return notes.map((note,index) => {
    const n={...note,index:note.index ?? index,id:note.id ?? `expected-${index}`,sessionTimeNanoseconds:timeNS(note),matchingToleranceNanoseconds:note.matchingToleranceNanoseconds ?? Math.round((options.tolerance ?? 100)*1e6)};
    n.time=n.sessionTimeNanoseconds/1e6;
    const authoredAccent = Object.hasOwn(note,'minimumAccentVelocity') || Object.hasOwn(note,'minimumAccentContrast');
    const authoredGhost = Object.hasOwn(note,'maximumGhostVelocity') || Object.hasOwn(note,'minimumGhostContrast');
    if (authoredAccent) { n.minimumAccentVelocity ??= null; n.minimumAccentContrast ??= null; }
    else if (note.accent) { n.minimumAccentVelocity = options.accentFloor === null ? null:(options.accentFloor ?? 100)/127; n.minimumAccentContrast = (options.accentContrast ?? 18)/127; }
    if (authoredGhost) { n.maximumGhostVelocity ??= null; n.minimumGhostContrast ??= null; }
    else if (note.ghost && !note.accent) { n.maximumGhostVelocity = options.ghostCeiling === null ? null:(options.ghostCeiling ?? 50)/127; n.minimumGhostContrast = (options.ghostContrast ?? 18)/127; }
    n.accent = n.minimumAccentVelocity != null || n.minimumAccentContrast != null;
    n.ghost = n.maximumGhostVelocity != null || n.minimumGhostContrast != null;
    return n;
  });
}
export function normalizeActual(notes) {
  return notes.map((note,index) => ({...note,index:note.index ?? index,id:note.id ?? `actual-${String(index).padStart(6,'0')}`,sessionTimeNanoseconds:timeNS(note),time:timeNS(note)/1e6,velocityNormalized:velocity(note),source:note.source ?? 'midi'}));
}
function actualOrder(events) {
  const chronological=[...events].sort((a,b) => a.sessionTimeNanoseconds-b.sessionTimeNanoseconds || compare(a.voice,b.voice) || compare(a.id.toUpperCase(),b.id.toUpperCase()));
  const result=[]; let cluster=[];
  const append=() => result.push(...cluster.sort((a,b) => compare(a.voice,b.voice) || a.sessionTimeNanoseconds-b.sessionTimeNanoseconds || compare(a.id.toUpperCase(),b.id.toUpperCase())));
  for (const event of chronological) {
    if (cluster.length && Math.abs(event.sessionTimeNanoseconds-cluster.at(-1).sessionTimeNanoseconds)>35000000) { append(); cluster=[]; }
    cluster.push(event);
  }
  append(); return result;
}
export function matchEvents(expectedInput,actualInput,options={}) {
  const expected=normalizeExpected(expectedInput,options).sort((a,b) => a.sessionTimeNanoseconds-b.sessionTimeNanoseconds || compare(a.voice,b.voice));
  const actual=actualOrder(normalizeActual(actualInput).filter(a => a.source!=='metronome' && a.voice!=='metronome').map(a => {
    const correction=options.voiceCorrections?.[`${a.source}/${a.voice}`] ?? options.corrections?.[a.source] ?? 0;
    const ns=a.sessionTimeNanoseconds-Math.round(correction*1e6);
    return {...a,rawTime:a.time,sessionTimeNanoseconds:ns,time:ns/1e6};
  }));
  const n=expected.length,m=actual.length,width=m+1;
  if (n>10000 || m>10000) throw new Error('Session exceeds 10,000 events.');
  // Two cost rows and one byte per predecessor avoid the native full Double matrix.
  const predecessor=new Uint8Array((n+1)*width);
  let previous=new Float64Array(width),current=new Float64Array(width);
  for (let j=1;j<=m;j++) { previous[j]=j; predecessor[j]=4; }
  for (let i=1;i<=n;i++) {
    current[0]=i; predecessor[i*width]=3;
    const e=expected[i-1],tolerance=e.matchingToleranceNanoseconds;
    for (let j=1;j<=m;j++) {
      let cost=previous[j]+1,transition=3;
      const extra=current[j-1]+1;
      if (extra<cost-1e-7) { cost=extra; transition=4; }
      const error=Math.abs(e.sessionTimeNanoseconds-actual[j-1].sessionTimeNanoseconds);
      if (error<=tolerance) {
        const compatible=accepts(e,actual[j-1]),normalized=Math.min(error/Math.max(1,tolerance),1);
        const matched=previous[j-1]+(compatible ? normalized*.49:1.1+normalized*.39),rank=compatible ? 1:2;
        if (matched<cost-1e-7 || (Math.abs(matched-cost)<=1e-7 && rank<transition)) { cost=matched; transition=rank; }
      }
      current[j]=cost; predecessor[i*width+j]=transition;
    }
    [previous,current]=[current,previous];
  }
  const results=[]; let i=n,j=m;
  while (i>0 || j>0) {
    const step=predecessor[i*width+j]; let e=null,a=null,status;
    if (step===1 || step===2) {
      e=expected[--i]; a=actual[--j];
      const error=Math.abs(e.sessionTimeNanoseconds-a.sessionTimeNanoseconds);
      status=step===2 ? 'wrongVoice' : actual.some(candidate => candidate.id!==a.id && accepts(e,candidate) && Math.abs(e.sessionTimeNanoseconds-candidate.sessionTimeNanoseconds)===error && error<=e.matchingToleranceNanoseconds) ? 'ambiguous':'correct';
    } else if (step===3) { e=expected[--i]; status='missed'; }
    else if (step===4) { a=actual[--j]; status='extra'; }
    else throw new Error('Invalid match predecessor.');
    const offset=e && a ? (a.sessionTimeNanoseconds-e.sessionTimeNanoseconds)/1e6:null;
    results.push({id:e?.id ?? a?.id,expectedEventID:e?.id ?? null,actualEventID:a?.id ?? null,classification:status,status,expected:e,actual:a,expectedTimeNanoseconds:e?.sessionTimeNanoseconds ?? null,actualTimeNanoseconds:a?.sessionTimeNanoseconds ?? null,signedOffsetMilliseconds:offset,absoluteTimingErrorMilliseconds:offset==null ? null:Math.abs(offset),offset});
  }
  return results.reverse();
}
function sortVoices(a,b) { return voiceOrder.indexOf(a)-voiceOrder.indexOf(b); }
export function calculateMetrics(results,expectedInput,actualInput) {
  const expected=normalizeExpected(expectedInput),actual=normalizeActual(actualInput);
  const expectedByID=new Map(expected.map(e => [e.id,e])),actualByID=new Map(actual.map(a => [a.id,a]));
  const correct=results.filter(r => r.status==='correct'),offsets=correct.map(r => r.offset);
  const totalExpected=results.filter(r => r.expectedEventID!=null).length,totalPlayed=results.filter(r => r.actualEventID!=null).length;
  const classified=status => results.filter(r => r.status===status).length;
  const resultByActual=new Map(results.filter(r => r.actualEventID!=null).map(r => [r.actualEventID,r]));
  const playedCounts=new Map();
  for (const a of actual.filter(a => a.source!=='metronome' && a.voice!=='metronome')) {
    const r=resultByActual.get(a.id),credited=r && ['correct','ambiguous'].includes(r.status) && expectedByID.has(r.expectedEventID) ? expectedByID.get(r.expectedEventID).voice:a.voice;
    playedCounts.set(credited,(playedCounts.get(credited) ?? 0)+1);
  }
  const perVoice=[...new Set([...expected,...actual.filter(a => a.source!=='metronome' && a.voice!=='metronome')].map(e => e.voice))].sort(sortVoices).map(voice => {
    const rs=results.filter(r => expectedByID.get(r.expectedEventID)?.voice===voice),correct=rs.filter(r => r.status==='correct'),offsets=correct.map(r => r.offset);
    const played=playedCounts.get(voice) ?? 0;
    return {voice,totalExpected:rs.length,totalPlayed:played,correctCount:correct.length,missedCount:rs.filter(r => r.status==='missed').length,extraCount:results.filter(r => r.status==='extra' && actualByID.get(r.actualEventID)?.voice===voice).length,wrongVoiceCount:rs.filter(r => r.status==='wrongVoice').length,ambiguousCount:rs.filter(r => r.status==='ambiguous').length,recall:rs.length ? correct.length/rs.length:0,precision:played ? correct.length/played:0,meanSignedOffsetMilliseconds:mean(offsets),medianAbsoluteErrorMilliseconds:median(offsets.map(Math.abs)),timingStandardDeviationMilliseconds:deviation(offsets),expected:rs.length,played,correct:correct.length,error:median(offsets.map(Math.abs))};
  });
  const groups=new Map();
  for (const e of expected) if (e.simultaneousGroupID!=null) { const group=groups.get(e.simultaneousGroupID) ?? []; group.push(e); groups.set(e.simultaneousGroupID,group); }
  const eligible=[...groups.values()].filter(g => g.length>=2),spreads=[],voiceOffsets=new Map();
  const resultByExpected=new Map(results.filter(r => r.expectedEventID!=null).map(r => [r.expectedEventID,r]));
  for (const group of eligible) {
    const matched=group.map(e => ({e,r:resultByExpected.get(e.id)}));
    if (matched.some(x => x.r?.status!=='correct' || !actualByID.has(x.r.actualEventID))) continue;
    const allMIDI=matched.every(x => actualByID.get(x.r.actualEventID).source==='midi');
    const times=matched.map(x => (allMIDI ? actualByID.get(x.r.actualEventID).sessionTimeNanoseconds:x.r.actualTimeNanoseconds)/1e6),center=mean(times);
    spreads.push(Math.max(...times)-Math.min(...times));
    matched.forEach((x,i) => { const values=voiceOffsets.get(x.e.voice) ?? []; values.push(times[i]-center); voiceOffsets.set(x.e.voice,values); });
  }
  const limbSynchronization=eligible.length ? {eligibleGroupCount:eligible.length,completedGroupCount:spreads.length,averageSpreadMilliseconds:mean(spreads),medianSpreadMilliseconds:median(spreads),worstSpreadMilliseconds:spreads.length ? Math.max(...spreads):null,voiceOffsets:[...voiceOffsets].sort((a,b) => sortVoices(a[0],b[0])).map(([voice,values]) => ({voice,sampleCount:values.length,meanOffsetFromGroupCenterMilliseconds:mean(values),medianOffsetFromGroupCenterMilliseconds:median(values)}))}:null;
  let longest=0,streak=0;
  for (const r of [...results].sort((a,b) => (a.expectedTimeNanoseconds ?? a.actualTimeNanoseconds)-(b.expectedTimeNanoseconds ?? b.actualTimeNanoseconds) || compare(a.status,b.status))) { streak=r.status==='correct' ? streak+1:0; longest=Math.max(longest,streak); }
  return {totalExpected,totalPlayed,correctCount:correct.length,missedCount:classified('missed'),extraCount:classified('extra'),wrongVoiceCount:classified('wrongVoice'),ambiguousCount:classified('ambiguous'),recall:totalExpected ? correct.length/totalExpected:0,precision:totalPlayed ? correct.length/totalPlayed:0,meanSignedOffsetMilliseconds:mean(offsets),meanAbsoluteErrorMilliseconds:mean(offsets.map(Math.abs)),medianAbsoluteErrorMilliseconds:median(offsets.map(Math.abs)),timingStandardDeviationMilliseconds:deviation(offsets),earlyCount:offsets.filter(v => v<0).length,lateCount:offsets.filter(v => v>0).length,longestCleanStreak:longest,perVoice,limbSynchronization};
}
export function evaluateDynamics(kind,expectedInput,actualInput,matches) {
  const expected=normalizeExpected(expectedInput),actual=normalizeActual(actualInput),isAccent=kind==='accent';
  const targets=expected.filter(e => isAccent ? e.accent:e.ghost).sort((a,b) => a.sessionTimeNanoseconds-b.sessionTimeNanoseconds || compare(a.voice,b.voice));
  if (!targets.length) return null;
  const matchByID=new Map(matches.filter(r => r.expectedEventID!=null).map(r => [r.expectedEventID,r])),actualByID=new Map(actual.map(a => [a.id,a])),expectedByID=new Map(expected.map(e => [e.id,e]));
  const validVelocities=new Map();
  for (const r of matches) {
    const a=actualByID.get(r.actualEventID),e=expectedByID.get(r.expectedEventID);
    if (r.status==='correct' && a?.source==='midi' && a.voice===e?.voice && a.velocityNormalized!=null && Number.isFinite(a.velocityNormalized) && a.velocityNormalized>=0 && a.velocityNormalized<=1) validVelocities.set(e.id,a.velocityNormalized);
  }
  const results=targets.map(e => {
    const floor=isAccent ? e.minimumAccentVelocity:e.maximumGhostVelocity,contrast=isAccent ? e.minimumAccentContrast:e.minimumGhostContrast,r=matchByID.get(e.id),a=actualByID.get(r?.actualEventID);
    const base={expectedEventID:e.id,actualEventID:r?.actualEventID ?? null,voice:e.voice,baselineVelocity:null,requiredContrast:contrast ?? null,requiredVelocity:floor ?? null,actualVelocity:null,classification:'missed',...(isAccent ? {minimumVelocity:floor ?? null,usedMinimumOnly:false}:{maximumVelocity:floor ?? null,usedMaximumOnly:false})};
    if (r?.status!=='correct' || !a) return base;
    const v=a.velocityNormalized;
    if (v==null || (!isAccent && (a.source!=='midi' || a.voice!==e.voice || !Number.isFinite(v) || v<0 || v>1))) return {...base,classification:'velocityUnavailable'};
    const neighbors=expected.filter(n => !n.accent && !n.ghost && n.voice===e.voice && validVelocities.has(n.id)).map(n => ({distance:Math.abs(n.sessionTimeNanoseconds-e.sessionTimeNanoseconds),velocity:validVelocities.get(n.id)})).sort((a,b) => a.distance-b.distance || a.velocity-b.velocity).slice(0,4);
    const baseline=median(neighbors.map(n => n.velocity)),requiredContrast=baseline!=null && contrast!=null ? Math.max(contrast,baseline*.2):null;
    const contrastTarget=baseline!=null && requiredContrast!=null ? baseline+(isAccent ? requiredContrast:-requiredContrast):null;
    const thresholds=[floor,contrastTarget].filter(v => v!=null),required=thresholds.length ? (isAccent ? Math.max(...thresholds):Math.min(...thresholds)):null;
    const passed=floor==null || (isAccent ? v>=floor:v<=floor+1e-12);
    let classification='achieved',only=false;
    if (contrast!=null && baseline==null) { only=floor!=null; classification=floor==null ? 'baselineUnavailable':passed ? 'achieved':isAccent ? 'belowThreshold':'aboveThreshold'; }
    else if (!passed) classification=isAccent ? 'belowThreshold':'aboveThreshold';
    else if (requiredContrast!=null && baseline!=null && (isAccent ? v-baseline:baseline-v+1e-12)<requiredContrast) classification='insufficientContrast';
    return {...base,baselineVelocity:baseline,requiredContrast:requiredContrast ?? contrast ?? null,requiredVelocity:required,actualVelocity:v,classification,...(isAccent ? {usedMinimumOnly:only}:{usedMaximumOnly:only})};
  });
  const classified=status => results.filter(r => r.classification===status).length;
  return {results,metrics:{expectedCount:results.length,achievedCount:classified('achieved'),...(isAccent ? {belowThresholdCount:classified('belowThreshold')+classified('insufficientContrast')}:{aboveThresholdCount:classified('aboveThreshold')+classified('insufficientContrast')}),missedCount:classified('missed'),velocityUnavailableCount:classified('velocityUnavailable'),baselineUnavailableCount:classified('baselineUnavailable'),accuracy:classified('achieved')/results.length}};
}
export function stableTimingBias(results) {
  const offsets=results.filter(r => r.status==='correct' && Number.isFinite(r.offset)).map(r => r.offset),bias=median(offsets);
  if (offsets.length<8 || Math.abs(bias)<30 || Math.abs(bias)>80) return null;
  if (offsets.filter(v => bias>=0 ? v>=0:v<=0).length/offsets.length<.8) return null;
  const centered=offsets.map(v => Math.abs(v-bias)),mad=median(centered),raw=median(offsets.map(Math.abs));
  if (mad>12 || raw<=25 || mad>25) return null;
  return {sampleCount:offsets.length,biasMilliseconds:bias,medianAbsoluteDeviationMilliseconds:mad,rawMedianAbsoluteErrorMilliseconds:raw,adjustedMedianAbsoluteErrorMilliseconds:mad};
}
export function nativeScore(pattern,evidence,options={}) {
  const expected=normalizeExpected(pattern.notes ?? pattern.expectedEvents,options).filter(e => options.gradeKicks!==false || e.voice!=='kick');
  const actual=normalizeActual(evidence).filter(a => options.gradeKicks!==false || a.voice!=='kick');
  const results=matchEvents(expected,actual,options),metrics=calculateMetrics(results,expected,actual),accents=evaluateDynamics('accent',expected,actual,results),ghosts=evaluateDynamics('ghost',expected,actual,results),stable=stableTimingBias(results);
  const dynamicByID=new Map([...(accents?.results ?? []),...(ghosts?.results ?? [])].map(r => [r.expectedEventID,r]));
  for (const r of results) if (dynamicByID.has(r.expectedEventID)) { r.dynamicResult=dynamicByID.get(r.expectedEventID); r.dynamics=r.dynamicResult.classification; }
  // Native clean qualification does not impose a precision threshold; stable common bias can be centered.
  const clean=!(options.dropped ?? 0) && metrics.totalExpected>0 && metrics.recall>=.95 && (stable?.adjustedMedianAbsoluteErrorMilliseconds ?? metrics.medianAbsoluteErrorMilliseconds ?? Infinity)<=25 && (accents?.metrics.accuracy ?? 1)>=.9 && (ghosts?.metrics.accuracy ?? 1)>=.9;
  return {...metrics,results,expected:metrics.totalExpected,played:metrics.totalPlayed,correct:metrics.correctCount,missed:metrics.missedCount,extra:metrics.extraCount,wrong:metrics.wrongVoiceCount,ambiguous:metrics.ambiguousCount,error:metrics.medianAbsoluteErrorMilliseconds,bias:metrics.meanSignedOffsetMilliseconds,consistency:metrics.timingStandardDeviationMilliseconds,spread:metrics.limbSynchronization?.medianSpreadMilliseconds ?? null,accents,ghosts,stableTiming:stable,clean,scoringVersion:5};
}
