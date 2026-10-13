export const recordingChannels={input1:[0],input2:[1],loopback34:[2,3]};
export function pcm16(channels){
  if(!channels.length||!channels.every(c=>c.length===channels[0].length))throw new Error('Invalid PCM channels.');
  const frames=channels[0].length,buffer=new ArrayBuffer(frames*channels.length*2),view=new DataView(buffer);
  for(let frame=0;frame<frames;frame++)for(let channel=0;channel<channels.length;channel++){
    const value=Math.min(Math.max(channels[channel][frame],-1),1);view.setInt16((frame*channels.length+channel)*2,value<0?Math.round(value*32768):Math.round(value*32767),true);
  }return buffer;
}
export function wavHeader(frames,channels,sampleRate){
  const length=frames*channels*2;if(!Number.isInteger(frames)||frames<0||length>0xffffffff-36||![1,2].includes(channels)||!Number.isFinite(sampleRate)||sampleRate<8000||sampleRate>192000)throw new Error('Recording exceeds supported WAV limits.');
  const buffer=new ArrayBuffer(44),view=new DataView(buffer),ascii=(offset,text)=>{for(let i=0;i<text.length;i++)view.setUint8(offset+i,text.charCodeAt(i));};
  ascii(0,'RIFF');view.setUint32(4,36+length,true);ascii(8,'WAVE');ascii(12,'fmt ');view.setUint32(16,16,true);view.setUint16(20,1,true);view.setUint16(22,channels,true);view.setUint32(24,sampleRate,true);view.setUint32(28,sampleRate*channels*2,true);view.setUint16(32,channels*2,true);view.setUint16(34,16,true);ascii(36,'data');view.setUint32(40,length,true);return buffer;
}
export function recordingSlice(bufferStartFrame,frameCount,sampleRate,startMilliseconds,endMilliseconds){
  const first=Math.min(Math.max(Math.ceil(startMilliseconds/1000*sampleRate-bufferStartFrame),0),frameCount),end=Math.min(Math.max(Math.floor(endMilliseconds/1000*sampleRate-bufferStartFrame),0),frameCount);
  return{first,end,frames:Math.max(end-first,0)};
}
