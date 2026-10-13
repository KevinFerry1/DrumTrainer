import {recordingSlice} from './recording-core.mjs';
class RecordingInput extends AudioWorkletProcessor{
  constructor(){super();this.active=null;this.capacity=8192;this.buffers=[];this.count=0;this.reportedUnavailable=false;this.port.onmessage=({data})=>{if(data.type==='arm'){this.active=data;this.buffers=data.indices.map(()=>new Float32Array(this.capacity));this.count=0;}else if(data.type==='abort'){this.active=null;this.buffers=[];this.count=0;}};}
  flush(){if(!this.count)return;const channels=this.buffers.map(b=>b.slice(0,this.count));this.port.postMessage({type:'pcm',channels,frames:this.count},channels.map(c=>c.buffer));this.buffers=this.active.indices.map(()=>new Float32Array(this.capacity));this.count=0;}
  process(inputs){
    const channels=inputs[0];if(!this.active||!channels?.length)return true;
    if(this.active.indices.some(i=>i>=channels.length)){if(!this.reportedUnavailable){this.port.postMessage({type:'error',message:'The selected recording channels are unavailable on this input.'});this.reportedUnavailable=true;}return true;}
    const slice=recordingSlice(currentFrame,channels[0].length,sampleRate,this.active.start,this.active.end);
    for(let frame=slice.first;frame<slice.end;frame++){
      this.active.indices.forEach((index,channel)=>this.buffers[channel][this.count]=channels[index][frame]);this.count++;if(this.count===this.capacity)this.flush();
    }
    if((currentFrame+channels[0].length)/sampleRate*1000>=this.active.end){this.flush();this.port.postMessage({type:'done'});this.active=null;}
    return true;
  }
}
registerProcessor('recording-input',RecordingInput);
