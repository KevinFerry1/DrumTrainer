import {recordingChannels,pcm16,wavHeader} from './recording-core.mjs';
const key=id=>id.toLowerCase();
const request=req=>new Promise((resolve,reject)=>{req.onsuccess=()=>resolve(req.result);req.onerror=()=>reject(req.error);});
const complete=tx=>new Promise((resolve,reject)=>{tx.oncomplete=resolve;tx.onerror=()=>reject(tx.error);tx.onabort=()=>reject(tx.error);});
export async function getTake(db,id){return request(db.transaction('takes').objectStore('takes').get(key(id)));}
export async function allTakes(db){return request(db.transaction('takes').objectStore('takes').getAll());}
export async function saveTake(db,id,blob,metadata={}){const tx=db.transaction('takes','readwrite');tx.objectStore('takes').put({id:key(id),blob,...metadata},key(id));await complete(tx);}
export async function deleteTake(db,id){const tx=db.transaction('takes','readwrite');tx.objectStore('takes').delete(key(id));await complete(tx);}
async function deleteChunks(db,id){const tx=db.transaction('takeChunks','readwrite'),store=tx.objectStore('takeChunks'),range=IDBKeyRange.bound([id,0],[id,Number.MAX_SAFE_INTEGER]),cursor=store.openCursor(range);cursor.onsuccess=()=>{if(cursor.result){cursor.result.delete();cursor.result.continue();}};await complete(tx);}
export class SessionRecorder{
  constructor(db,context,{onStatus=()=>{}}={}){this.db=db;this.context=context;this.onStatus=onStatus;this.stream=null;this.source=null;this.node=null;this.mute=null;this.pending=Promise.resolve();this.frames=0;this.sequence=0;this.id=null;this.done=false;this.error=null;this.recordedChannels=1;}
  async prepare(deviceID,selection='input1'){
    if(!this.db)throw new Error('Browser storage is unavailable for recordings.');
    const indices=recordingChannels[selection];if(!indices)throw new Error('Choose valid recording channels.');
    this.indices=indices;this.recordedChannels=indices.length;
    this.stream=await navigator.mediaDevices.getUserMedia({audio:{deviceId:deviceID?{exact:deviceID}:undefined,channelCount:{ideal:Math.max(...indices)+1},echoCancellation:false,noiseSuppression:false,autoGainControl:false},video:false});
    try{
      const settings=this.stream.getAudioTracks()[0].getSettings();if(settings.channelCount&&settings.channelCount<=Math.max(...indices))throw new Error(`This recording input exposes ${settings.channelCount} channels. Select another input/channel pair; Loopback 3–4 needs a four-channel input or its own loopback device.`);
      await this.context.audioWorklet.addModule('recording-worklet.mjs');this.source=this.context.createMediaStreamSource(this.stream);this.node=new AudioWorkletNode(this.context,'recording-input');this.mute=this.context.createGain();this.mute.gain.value=0;this.source.connect(this.node);this.node.connect(this.mute);this.mute.connect(this.context.destination);
      this.node.port.onmessage=({data})=>this.receive(data);
      this.stream.getAudioTracks()[0].onended=()=>{this.error=new Error('Recording input disconnected.');this.onStatus(this.error.message);};
      this.inputSettings=settings;this.onStatus('Recording input ready.');
    }catch(error){this.closeInput();throw error;}
  }
  arm(id,start,end){this.id=key(id);this.frames=0;this.sequence=0;this.done=false;this.error=null;this.node.port.postMessage({type:'arm',start,end,indices:this.indices});this.onStatus('Recording the practice window; count-in is excluded.');}
  receive(data){
    if(data.type==='done'){this.done=true;return;}if(data.type==='error'){this.error=new Error(data.message);this.onStatus(data.message);return;}if(data.type!=='pcm'||!this.id)return;
    const id=this.id,index=this.sequence++,buffer=pcm16(data.channels),frames=data.frames;this.frames+=frames;
    const queuedAt=performance.now();this.pending=this.pending.then(async()=>{const tx=this.db.transaction('takeChunks','readwrite');tx.objectStore('takeChunks').put({blob:new Blob([buffer]),frames},[id,index]);await complete(tx);if(performance.now()-queuedAt>5000)throw new Error('Recording storage is falling behind.');}).catch(error=>{this.error=error;this.onStatus(`Recording failed: ${error.message}`);});
  }
  async finish(metadata={}){
    const id=this.id;if(!id)return null;
    for(let i=0;i<20&&!this.done&&!this.error;i++)await new Promise(resolve=>setTimeout(resolve,50));
    this.closeInput();await this.pending;
    try{
      if(this.error)throw this.error;if(!this.done||!this.frames)throw new Error('Recording ended without a complete audio window.');
      const chunks=await request(this.db.transaction('takeChunks').objectStore('takeChunks').getAll(IDBKeyRange.bound([id,0],[id,Number.MAX_SAFE_INTEGER]))),frames=chunks.reduce((sum,c)=>sum+c.frames,0),header=wavHeader(frames,this.recordedChannels,this.context.sampleRate),blob=new Blob([header,...chunks.map(c=>c.blob)],{type:'audio/wav'});
      const info={filename:`${id}.wav`,durationSeconds:frames/this.context.sampleRate,channels:this.recordedChannels,sampleRate:this.context.sampleRate,bytes:blob.size,...metadata};await saveTake(this.db,id,blob,info);this.onStatus('Recording saved with this session.');return info;
    }finally{await deleteChunks(this.db,id);this.id=null;}
  }
  async abort(){const id=this.id;this.id=null;this.node?.port.postMessage({type:'abort'});this.closeInput();await this.pending;if(id)await deleteChunks(this.db,id);this.onStatus('Interrupted recording discarded.');}
  closeInput(){if(this.node){this.node.port.onmessage=null;this.node.disconnect();}this.source?.disconnect();this.mute?.disconnect();for(const track of this.stream?.getTracks()??[])track.stop();this.stream=null;this.node=null;this.source=null;this.mute=null;}
}
