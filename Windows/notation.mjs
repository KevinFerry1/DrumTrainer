// Geometry and symbols follow PracticeScoreView / PracticeScoreTimeline.swift.
const cymbals=new Set(['closedHiHat','openHiHat','pedalHiHat','ride','rideBell','crash1','crash2','china','splash']);
const slots={eighths:2,sixteenths:4,triplets:3};
const colors={correct:'#30d158',missed:'#ff9f0a',wrongVoice:'#ff453a',ambiguous:'#bf5af2',extra:'#bf5af2'};
const indexCache=new WeakMap(),resultCache=new WeakMap();
export function notePosition(measure,slot,slotsPerMeasure,measureWidth){return 48+measure*measureWidth+66+(slot+.35)/slotsPerMeasure*(measureWidth-84);}
export function noteY(voice){return voice==='kick'?96:voice==='lowTom'?82:voice==='highTom'?62:cymbals.has(voice)?44:72;}
export function measureTiming(pattern){return pattern.measureStarts?.length===pattern.measures+1?pattern.measureStarts:Array.from({length:pattern.measures+1},(_,i)=>i*pattern.duration/pattern.measures);}
export function scorePosition(pattern,time,measureWidth){
  if(time==null||pattern.duration<=0)return null;
  const starts=measureTiming(pattern),elapsed=Math.min(Math.max(time,0),pattern.duration),measure=Math.min(Math.max(starts.findLastIndex(v=>v<=elapsed),0),pattern.measures-1),signature=pattern.measureSignatures?.[measure]??{numerator:pattern.beatsPerMeasure??4},grid=pattern.measureSubdivisions?.[measure]??pattern.subdivision??'sixteenths',count=(slots[grid]??4)*signature.numerator,span=starts[measure+1]-starts[measure];
  return notePosition(measure,span>0?(elapsed-starts[measure])/span*count:0,count,measureWidth);
}
export function eventPosition(pattern,n,measureWidth){
  const measure=n.measure-1,signature=pattern.measureSignatures?.[measure]??{numerator:pattern.beatsPerMeasure??4},grid=pattern.measureSubdivisions?.[measure]??pattern.subdivision??'sixteenths',perBeat=slots[grid]??4,count=perBeat*signature.numerator;
  let slot=(n.beat-1)*perBeat+n.subdivision;
  if(pattern.measureStarts?.length===pattern.measures+1){const a=pattern.measureStarts[measure],b=pattern.measureStarts[measure+1];if(b>a)slot=Math.min(Math.max((n.time-a)/(b-a),0),.999999)*count;}
  return notePosition(measure,slot,count,measureWidth);
}
function indices(pattern){let value=indexCache.get(pattern);if(!value){value=new Map();for(const n of pattern.notes){const key=`${n.measure}/${n.beat}`,list=value.get(key)??[];list.push(n);value.set(key,list);}indexCache.set(pattern,value);}return value;}
function resultMaps(metrics){if(!metrics)return null;let value=resultCache.get(metrics);if(!value){value={notes:new Map((metrics.results??[]).map(r=>[r.expectedEventID??r.expected?.id,r.status??r.classification])),accent:new Map((metrics.accents?.results??[]).map(r=>[r.expectedEventID,r.classification])),ghost:new Map((metrics.ghosts?.results??[]).map(r=>[r.expectedEventID,r.classification]))};resultCache.set(metrics,value);}return value;}
export function drawNotation(c,width,pattern,{time=null,metrics=null,measure=1,fixedMeasureWidth=null,compact=false,scrollOffset=null,gradeKicks=true}={}){
  const measureWidth=fixedMeasureWidth??Math.max(330,Math.min(460,width*.78)),contentWidth=58+measureWidth*pattern.measures,playhead=scorePosition(pattern,time,measureWidth),offset=scrollOffset!=null?Math.min(Math.max(scrollOffset,0),Math.max(0,contentWidth-width)):playhead==null?Math.min(Math.max((measure-1)*measureWidth,0),Math.max(0,contentWidth-width)):Math.min(Math.max(playhead-width*.3,0),Math.max(0,contentWidth-width)),byBeat=indices(pattern),results=resultMaps(metrics);
  c.font='12px Segoe UI, system-ui';c.textBaseline='middle';
  const line=(x,y,x2,y2,color='#9eabc0',weight=1)=>{c.strokeStyle=color;c.lineWidth=weight;c.beginPath();c.moveTo(x,y);c.lineTo(x2,y2);c.stroke();};
  const label=(value,x,y,color='#94a1b7',align='center',font='12px Segoe UI, system-ui')=>{c.fillStyle=color;c.textAlign=align;c.font=font;c.fillText(value,x,y);};
  const dynamicColor=status=>status==='achieved'?colors.correct:['belowThreshold','aboveThreshold','insufficientContrast'].includes(status)?colors.missed:status==='missed'?colors.wrongVoice:status?'#94a1b7':'#e8edf6';
  for(let m=0;m<pattern.measures;m++){
    const left=48+m*measureWidth-offset,right=left+measureWidth;if(right< -measureWidth||left>width+measureWidth)continue;
    const signature=pattern.measureSignatures?.[m]??{numerator:pattern.beatsPerMeasure??4,denominator:4},grid=pattern.measureSubdivisions?.[m]??pattern.subdivision??'sixteenths',perBeat=slots[grid]??4,total=signature.numerator*perBeat;
    for(let y=52;y<=92;y+=10)line(left,y,right,y,'#9eabc0');line(left,52,left,92,'#c7d3e0',m===0?1.5:1);line(right,52,right,92,'#c7d3e0',m===pattern.measures-1?3:1.5);
    label(`${m+1} · ${(pattern.measureLabels?.[m]??'Measure').slice(0,26)}`,left+8,25,'#94a1b7','left');
    if(m===0){line(left+15,59,left+15,85,'#c7d3e0',2);line(left+20,59,left+20,85,'#c7d3e0',2);}
    label(signature.numerator,left+36,61,'#e8edf6','center','bold 18px Segoe UI');label(signature.denominator,left+36,81,'#e8edf6','center','bold 18px Segoe UI');
    for(let beat=0;beat<signature.numerator;beat++){
      const beatLeft=notePosition(m,beat*perBeat-.35,total,measureWidth)-offset,beatRight=notePosition(m,(beat+1)*perBeat-.35,total,measureWidth)-offset;
      c.fillStyle=beat%2===0?'#0a84ff0b':'#0a84ff05';c.fillRect(beatLeft,17,beatRight-beatLeft,137);line(beatLeft,18,beatLeft,154,'#94a1b733');
      const notes=byBeat.get(`${m+1}/${beat+1}`)??[];
      for(let sub=0;sub<perBeat;sub++){
        const x=notePosition(m,beat*perBeat+sub,total,measureWidth)-offset;
        if(!pattern.measureStarts?.length&&!notes.some(n=>n.subdivision===sub)){c.fillStyle='#94a1b752';c.fillRect(x-3,77,6,6);}
        label(sub===0?`${beat+1}`:grid==='triplets'?['','trip','let'][sub]:grid==='eighths'?'&':['','e','&','a'][sub],x,121,sub===0?'#c7d3e0':'#8794aa','center','11px ui-monospace, monospace');
      }
      const positions=[];
      for(const n of notes){
        const x=eventPosition(pattern,n,measureWidth)-offset,y=noteY(n.voice),color=n.voice==='kick'&&!gradeKicks?'#8e8e93':colors[results?.notes.get(n.id)]??'#e8edf6';positions.push(x);
        if(n.ghost){label('(',x-11,y,dynamicColor(results?.ghost.get(n.id)));label(')',x+11,y,dynamicColor(results?.ghost.get(n.id)));}
        if(cymbals.has(n.voice)){line(x-6,y-5,x+6,y+5,color,2);line(x-6,y+5,x+6,y-5,color,2);}else{c.fillStyle=color;c.beginPath();c.ellipse(x,y,7,4,0,0,2*Math.PI);c.fill();}
        line(x+6,y,x+6,43,color,1.6);if(n.accent)label('>',x,y-12,dynamicColor(results?.accent.get(n.id)));
      }
      const points=positions.sort((a,b)=>a-b).filter((x,i,a)=>i===0||x-a[i-1]>.5),count=grid==='sixteenths'?2:1;
      if(points.length)for(let beam=0;beam<count;beam++)line(points[0]+6,48+beam*5,points.length===1?points[0]+16:points.at(-1)+6,points.length===1?53+beam*5:48+beam*5,'#c7d3e0',points.length===1?2.2:3);
      if(grid==='triplets'&&points.length>1)label('3',(points[0]+points.at(-1))/2,38,'#94a1b7','center','bold 11px Segoe UI');
    }
  }
  if(playhead!=null){const x=playhead-offset;line(x,15,x,153,'#0a84ff',2);c.fillStyle='#0a84ff';c.beginPath();c.moveTo(x-6,14);c.lineTo(x+6,14);c.lineTo(x,23);c.closePath();c.fill();}
  if(!compact)label('Cymbal × · snare center · kick low · green correct · orange missed · red wrong · purple ambiguous',14,186,'#94a1b7','left','11px Segoe UI');c.lineWidth=1;c.textAlign='left';
}
