// Sample formulas and deterministic noise seeds from MetronomeEngine.swift.
export const clickSounds={cuttingElectronic:'Cutting electronic',woodblock:'Woodblock',cowbell:'Cowbell',rimshot:'Rimshot',warmPulse:'Warm pulse'};
export const kickSounds={studioPunch:'Studio punch',deepAcoustic:'Deep acoustic',tightTrigger:'Tight trigger',electronicSub:'Electronic sub'};
const clamp=(v,min,max)=>Math.min(Math.max(v,min),max);
export function kickDynamics(velocity,sensitive=true){return sensitive?.16+.84*Math.pow(clamp(velocity,0,1),.72):1;}
export function clickSamples(sampleRate,sound='cuttingElectronic',accent=false,gainDB=-3){
  if(!Object.hasOwn(clickSounds,sound)||!(sampleRate>0))throw new Error('Invalid click sound or sample rate.');
  const duration=sound==='cowbell'?.075:sound==='warmPulse'?.055:.03,data=new Float32Array(Math.floor(sampleRate*duration)),gain=10**(clamp(gainDB,-36,24)/20);let noiseState=accent?0xa341316c:0xc8013ea4;
  for(let frame=0;frame<data.length;frame++){
    const t=frame/sampleRate;let sample;
    if(sound==='cuttingElectronic')sample=.82*Math.sin(2*Math.PI*(accent?2150:1450)*t)*Math.exp(-t*135);
    else if(sound==='woodblock'){const f=accent?1650:1150;sample=.72*(Math.sin(2*Math.PI*f*t)+.42*Math.sin(2*Math.PI*f*1.72*t))*Math.exp(-t*105);}
    else if(sound==='cowbell'){const shift=accent?1.18:1;sample=.48*(Math.sin(2*Math.PI*540*shift*t)+Math.sin(2*Math.PI*845*shift*t))*Math.exp(-t*42);}
    else if(sound==='rimshot'){noiseState=(Math.imul(noiseState,1664525)+1013904223)>>>0;const noise=(noiseState|0)/2147483647,tone=Math.sin(2*Math.PI*(accent?2400:1900)*t);sample=(.52*noise+.38*tone)*Math.exp(-t*150);}
    else{const f=accent?880:660;sample=.68*(Math.sin(2*Math.PI*f*t)+.25*Math.sin(2*Math.PI*f*2*t))*Math.exp(-t*55);}
    data[frame]=sample*gain;
  }return data;
}
export function kickSamples(sampleRate,sound='studioPunch',gainDB=-6,dynamicsGain=1){
  if(!Object.hasOwn(kickSounds,sound)||!(sampleRate>0))throw new Error('Invalid kick sound or sample rate.');
  const durations={studioPunch:.30,deepAcoustic:.42,tightTrigger:.18,electronicSub:.50},parameters={studioPunch:[112,48,12,.26,.16],deepAcoustic:[92,42,8,.13,.20],tightTrigger:[138,57,21,.42,.12],electronicSub:[84,36,6.5,.07,.06]},duration=durations[sound],data=new Float32Array(Math.floor(sampleRate*duration)),gain=10**(clamp(gainDB,-36,6)/20)*clamp(dynamicsGain,0,1),[start,end,decay,click,harmonicAmount]=parameters[sound];
  let phase=0,noiseState=0x6d2b79f5;
  for(let frame=0;frame<data.length;frame++){
    const t=frame/sampleRate,progress=Math.min(t/duration,1),sweep=progress**(sound==='electronicSub'?.28:.18),frequency=start+(end-start)*sweep;
    phase+=2*Math.PI*frequency/sampleRate;noiseState=(Math.imul(noiseState,1664525)+1013904223)>>>0;const noise=(noiseState|0)/2147483647;
    const body=Math.sin(phase)*Math.exp(-t*decay),harmonic=Math.sin(phase*2.03)*Math.exp(-t*decay*1.7)*harmonicAmount,beater=noise*Math.exp(-t*145)*click,attack=Math.min(t/.0015,1),fade=progress>.92?Math.max((1-progress)/.08,0):1;
    data[frame]=(.78*body+harmonic+beater)*attack*fade*gain;
  }return data;
}
export function measurePCM(channels){let peak=0,squares=0,count=0;for(const channel of channels)for(const sample of channel){peak=Math.max(peak,Math.abs(sample));squares+=sample*sample;count++;}const db=value=>value>0?Math.max(20*Math.log10(value),-80):-80;return{peakDBFS:db(peak),rmsDBFS:db(count?Math.sqrt(squares/count):0)};}
export class OutputLimiter{
  constructor(sampleRate){this.sampleRate=sampleRate;this.enabled=true;this.ceilingDBFS=-1;this.gain=1;this.release=Math.exp(-1/(sampleRate*.05));}
  gainForPeak(peak){
    const ceiling=10**(this.ceilingDBFS/20),target=peak>ceiling?ceiling/peak:1;
    this.gain=this.enabled?target<this.gain?target:this.release*this.gain+(1-this.release)*target:1;
    return this.gain;
  }
  frame(values){const gain=this.gainForPeak(Math.max(...values.map(Math.abs)));return values.map(v=>v*gain);}
}
