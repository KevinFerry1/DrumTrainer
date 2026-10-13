import {voices} from './core.mjs';
const colors={correct:'#76db9b',missed:'#f6bd72',extra:'#c09bf2',wrongVoice:'#f18b8b',ambiguous:'#92a4fa'};
export function timingTimeline(session){
  const entries=(session.metrics.results??[]).map(r=>{
    const expected=r.expected,actual=r.actual,expectedTime=r.expectedTimeNanoseconds==null?expected?.time:r.expectedTimeNanoseconds/1e6,actualTime=r.actualTimeNanoseconds==null?actual?.time:r.actualTimeNanoseconds/1e6;
    return{...r,expectedTime:expectedTime??null,actualTime:actualTime??null,anchor:expectedTime==null&&actualTime==null?0:Math.min(...[expectedTime,actualTime].filter(v=>v!=null)),isProblem:r.status!=='correct'};
  }).sort((a,b)=>a.anchor-b.anchor||(a.expected?.measure??Infinity)-(b.expected?.measure??Infinity)||(a.expected?.beat??Infinity)-(b.expected?.beat??Infinity)||(a.expected?.subdivision??Infinity)-(b.expected?.subdivision??Infinity)||(a.id??'').localeCompare(b.id??''));
  const times=entries.flatMap(e=>[e.expectedTime,e.actualTime].filter(v=>v!=null));
  const start=Math.min(0,...times),end=Math.max(session.pattern.duration??0,...times,start+.000001);
  return{entries,start,end};
}
export function filterTimeline(timeline,{problems=false,voice='all'}={}){return timeline.entries.filter(e=>(!problems||e.isProblem)&&(voice==='all'||e.expected?.voice===voice||e.actual?.voice===voice));}
export function renderTimingChart(container,session,entries,timeline){
  container.replaceChildren();if(!entries.length){const p=document.createElement('p');p.className='hint';p.textContent='No events match this filter.';container.append(p);return;}
  const used=new Set(entries.flatMap(e=>[e.expected?.voice,e.actual?.voice].filter(Boolean))),ordered=Object.keys(voices).filter(v=>used.has(v)),width=Math.max(720,(session.pattern.measures*(session.pattern.beatsPerMeasure??4))*140),height=30+Math.max(ordered.length,1)*42;
  const labels=document.createElement('div');labels.className='timing-labels';labels.style.paddingTop='30px';for(const voice of ordered){const label=document.createElement('div');label.textContent=voices[voice];labels.append(label);}
  const scroll=document.createElement('div');scroll.className='timing-scroll';
  const ns='http://www.w3.org/2000/svg',svg=document.createElementNS(ns,'svg');svg.setAttribute('width',width);svg.setAttribute('height',height);svg.setAttribute('role','img');svg.setAttribute('aria-label',`Timing timeline: ${entries.length} scored events across ${ordered.length} drum voices. Outlined expected markers connect to filled played hits.`);
  const element=(tag,attrs)=>{const el=document.createElementNS(ns,tag);for(const [k,v]of Object.entries(attrs))el.setAttribute(k,v);svg.append(el);return el;};
  const x=time=>8+Math.min(Math.max((time-timeline.start)/Math.max(timeline.end-timeline.start,.000001),0),1)*(width-16),y=voice=>51+ordered.indexOf(voice)*42;
  ordered.forEach((voice,i)=>{element('rect',{x:0,y:30+i*42,width,height:42,fill:i%2===0?'#94a1b709':'transparent'});element('line',{x1:0,y1:72+i*42,x2:width,y2:72+i*42,stroke:'#94a1b72e'});});
  for(const beat of session.pattern.referenceBeats??[]){element('line',{x1:x(beat.time),y1:26,x2:x(beat.time),y2:height,stroke:beat.isAccent?'#94a1b76b':'#94a1b729','stroke-width':beat.isAccent?1.5:1});const t=element('text',{x:x(beat.time)+4,y:14,fill:'#94a1b7','font-size':11});t.textContent=beat.isAccent?`M${beat.measure}`:`${beat.beat}`;}
  for(const e of entries){const color=colors[e.status]??'#94a1b7',a=e.expectedTime!=null&&e.expected?{x:x(e.expectedTime),y:y(e.expected.voice)}:null,b=e.actualTime!=null&&e.actual?{x:x(e.actualTime),y:y(e.actual.voice)}:null;
    if(a&&b)element('line',{x1:a.x,y1:a.y,x2:b.x,y2:b.y,stroke:color,'stroke-width':2,opacity:.55});
    if(a){element('rect',{x:a.x-5,y:a.y-5,width:10,height:10,rx:2,fill:'none',stroke:color,'stroke-width':2});if(e.status==='missed')element('path',{d:`M${a.x-6} ${a.y-6}L${a.x+6} ${a.y+6}M${a.x+6} ${a.y-6}L${a.x-6} ${a.y+6}`,stroke:color,'stroke-width':2});}
    if(b){const mark=element('circle',{cx:b.x,cy:b.y,r:4,fill:color}),title=document.createElementNS(ns,'title');title.textContent=`${voices[e.actual.voice]} · ${e.status} · ${e.actualTime.toFixed(3)} ms · ${e.offset==null?'unmatched':`${e.offset.toFixed(1)} ms offset`}`;mark.append(title);if(e.status==='extra')element('circle',{cx:b.x,cy:b.y,r:7,fill:'none',stroke:color,opacity:.7});}
  }
  scroll.append(svg);container.append(labels,scroll);
}
