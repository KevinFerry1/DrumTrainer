// Ports of KickSoundClassifier.swift, MicrophoneCalibration.swift and MicrophoneCrosstalkGuard.swift.
import {median} from './native-scoring.mjs';
const clamp=(v,min,max) => Math.min(Math.max(v,min),max);
const frequencies=[60,85,120,170,240,340,480,680,960,1350,1900,2700,3800,5400,7600,10700];
const rms=samples => samples.length ? Math.sqrt(samples.reduce((sum,v) => sum+v*v,0)/samples.length):0;
export function extractFeatures(samples,sampleRate) {
  if (!(sampleRate>0) || samples.length<16) return null;
  const mean=samples.reduce((sum,v) => sum+v,0)/samples.length,centered=Array.from(samples,v => v-mean),available=frequencies.filter(f => f<sampleRate/2*.92);
  if (available.length<3) return null;
  const powers=available.map(f => {
    const coefficient=2*Math.cos(2*Math.PI*f/sampleRate),denominator=Math.max(centered.length-1,1);
    let previous=0,previous2=0;
    for (let i=0;i<centered.length;i++) {
      const window=.5-.5*Math.cos(2*Math.PI*i/denominator),current=centered[i]*window+coefficient*previous-previous2;
      previous2=previous; previous=current;
    }
    return Math.max(previous2*previous2+previous*previous-coefficient*previous*previous2,0);
  });
  const total=Math.max(powers.reduce((sum,v) => sum+v,0),1e-12);
  let centroid=0,low=0,high=0,crossings=0;
  available.forEach((f,i) => { centroid+=f*powers[i]; if(f<=340)low+=powers[i]; if(f>=1900)high+=powers[i]; });
  for(let i=1;i<centered.length;i++)if((centered[i-1]>=0)!==(centered[i]>=0))crossings++;
  const segment=Math.max(Math.floor(centered.length/4),1),attack=rms(centered.slice(0,segment)),tail=rms(centered.slice(-segment));
  return {spectralCentroidHertz:centroid/total,lowFrequencyRatio:clamp(low/total,0,1),highFrequencyRatio:clamp(high/total,0,1),zeroCrossingRate:clamp(crossings/Math.max(centered.length-1,1),0,1),decayRatio:clamp(tail/Math.max(attack,1e-9),0,4)};
}
export function makeSignature(features) {
  if(features.length<8)return null;
  const mappings=[['spectralCentroidHertz','centroidHertz','centroidToleranceHertz',250],['lowFrequencyRatio','lowFrequencyRatio','lowFrequencyTolerance',.06],['highFrequencyRatio','highFrequencyRatio','highFrequencyTolerance',.06],['zeroCrossingRate','zeroCrossingRate','zeroCrossingTolerance',.04],['decayRatio','decayRatio','decayTolerance',.25]];
  const result={sampleCount:features.length};
  for(const [feature,centerKey,toleranceKey,minimum]of mappings){const values=features.map(f=>f[feature]),center=median(values);result[centerKey]=center;result[toleranceKey]=Math.max(median(values.map(v=>Math.abs(v-center)))*3.5,minimum);}
  return result;
}
export function soundSimilarity(features,signature) {
  if(!features||!signature)return null;
  const parts=[['spectralCentroidHertz','centroidHertz','centroidToleranceHertz'],['lowFrequencyRatio','lowFrequencyRatio','lowFrequencyTolerance'],['highFrequencyRatio','highFrequencyRatio','highFrequencyTolerance'],['zeroCrossingRate','zeroCrossingRate','zeroCrossingTolerance'],['decayRatio','decayRatio','decayTolerance']];
  const distance=parts.reduce((sum,[feature,center,tolerance])=>sum+(Math.abs(features[feature]-signature[center])/Math.max(signature[tolerance],1e-9))**2,0)/parts.length;
  return clamp(Math.exp(-.5*distance),0,1);
}
export function percentile(fraction,sorted){if(!sorted.length)return 0;const position=clamp(fraction,0,1)*(sorted.length-1),lower=Math.floor(position),upper=Math.ceil(position),weight=position-lower;return sorted[lower]*(1-weight)+sorted[upper]*weight;}
export function analyzeNoise(samples){if(!samples.length)return null;const bounded=samples.map(v=>clamp(v,0,1)).sort((a,b)=>a-b),p95=percentile(.95,bounded);return{medianLevel:percentile(.5,bounded),percentile95Level:p95,collectionThreshold:clamp(Math.max(p95*2.5,p95+.04),.05,.8),sampleCount:bounded.length};}
export function makeCalibrationProfile({deviceUID,deviceName,noise,hitAmplitudes,hitSoundFeatures=[],retriggerLockoutMilliseconds,id=globalThis.crypto?.randomUUID?.(),createdAt=new Date().toISOString()}){
  if(!hitAmplitudes.length)return null;
  const hits=hitAmplitudes.map(v=>clamp(v,0,1)).sort((a,b)=>a-b),weak=percentile(.1,hits),medianHit=percentile(.5,hits),separation=Math.max(weak-noise.percentile95Level,0),snr=20*Math.log10(Math.max(medianHit,1e-6)/Math.max(noise.percentile95Level,1e-6));
  return{id,deviceUID,deviceName,createdAt,noiseFloor:noise.medianLevel,noisePercentile95:noise.percentile95Level,suggestedThreshold:clamp(Math.max(noise.percentile95Level+separation*.35,noise.percentile95Level+.02,.03),.03,.95),retriggerLockoutMilliseconds,detectedHitCount:hits.length,weakestHitAmplitude:hits[0],medianHitAmplitude:medianHit,signalToNoiseDecibels:snr,quality:snr>=12?'good':snr>=6?'marginal':'poor',kickSoundSignature:makeSignature(hitSoundFeatures)};
}
export class CalibrationHitCollector{
  constructor(lockout=40){this.amplitudes=[];this.soundFeatures=[];this.suppressedTransientCount=0;this.suggestedLockoutMilliseconds=lockout;this.lastAccepted=-Infinity;}
  record(amplitude,features,time){const spacing=time-this.lastAccepted;if(spacing>=0&&spacing<180){this.suppressedTransientCount++;this.suggestedLockoutMilliseconds=Math.max(this.suggestedLockoutMilliseconds,Math.min(60,Math.ceil(spacing+8)));return false;}this.lastAccepted=time;this.amplitudes.push(clamp(amplitude,0,1));if(features)this.soundFeatures.push(features);return true;}
}
export class CrosstalkGuard{
  constructor(){this.times=[];this.enabled=true;this.window=50;}
  observeMIDIHit(voice,time){if(voice==='kick'||voice==='metronome')return;this.times.push(time);if(this.times.length>64)this.times.shift();}
  shouldSuppress({amplitude,threshold,weakestKick=null,similarity=null,minimumSimilarity=.2,time}){
    if(!this.enabled)return false;if(similarity!=null&&similarity>=minimumSimilarity)return false;
    this.times=this.times.filter(t=>time-t<=Math.max(this.window*4,250));
    if(!this.times.some(t=>Math.abs(time-t)<=this.window))return false;
    const strong=weakestKick==null?threshold+.18:Math.max(threshold+.08,weakestKick*.82);
    return amplitude<clamp(strong,threshold,.95);
  }
  reset(){this.times=[];}
}
