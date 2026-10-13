// ZIP store format: portable audio files without dependencies or whole-file PCM copies.
const table=Uint32Array.from({length:256},(_,index)=>{let c=index;for(let bit=0;bit<8;bit++)c=c&1?0xedb88320^(c>>>1):c>>>1;return c>>>0;});
export function crc32(bytes,state=0xffffffff){let value=state;for(const byte of bytes)value=table[(value^byte)&255]^(value>>>8);return value>>>0;}
export async function blobCRC(blob){let value=0xffffffff;for(let offset=0;offset<blob.size;offset+=1048576)value=crc32(new Uint8Array(await blob.slice(offset,offset+1048576).arrayBuffer()),value);return (value^0xffffffff)>>>0;}
function header(size){const bytes=new Uint8Array(size);return {bytes,view:new DataView(bytes.buffer)};}
const validName=name=>typeof name==='string'&&name.length>0&&name.length<1024&&!name.startsWith('/')&&!name.includes('\\')&&!name.split('/').some(p=>!p||p==='.'||p==='..');
export async function portableZIP(entries,{onProgress=()=>{},maxBytes=2*1024*1024*1024}={}){
  if(!Array.isArray(entries)||entries.length>65535)throw new Error('Too many files for this portable backup.');
  const parts=[],central=[],names=new Set();let offset=0,total=0;
  for(const entry of entries){
    if(!validName(entry.name)||names.has(entry.name)||!(entry.blob instanceof Blob))throw new Error('Invalid or duplicate backup filename.');names.add(entry.name);
    if(entry.blob.size>0xffffffff)throw new Error('An audio file is too large for ZIP format.');
    const name=new TextEncoder().encode(entry.name),size=entry.blob.size,checksum=await blobCRC(entry.blob),local=header(30),directory=header(46);
    local.view.setUint32(0,0x04034b50,true);local.view.setUint16(4,20,true);local.view.setUint16(6,0x0800,true);local.view.setUint16(12,0x21,true);local.view.setUint32(14,checksum,true);local.view.setUint32(18,size,true);local.view.setUint32(22,size,true);local.view.setUint16(26,name.length,true);
    directory.view.setUint32(0,0x02014b50,true);directory.view.setUint16(4,20,true);directory.view.setUint16(6,20,true);directory.view.setUint16(8,0x0800,true);directory.view.setUint16(14,0x21,true);directory.view.setUint32(16,checksum,true);directory.view.setUint32(20,size,true);directory.view.setUint32(24,size,true);directory.view.setUint16(28,name.length,true);directory.view.setUint32(42,offset,true);
    parts.push(local.bytes,name,entry.blob);central.push(directory.bytes,name);offset+=30+name.length+size;total+=size;
    if(offset>Math.min(maxBytes,0xffffffff))throw new Error('This backup exceeds the 2 GB portable bundle limit. Download individual takes or split the recordings.');onProgress({name:entry.name,completed:names.size,total:entries.length,bytes:total});
  }
  const directorySize=central.reduce((sum,b)=>sum+b.byteLength,0),end=header(22);end.view.setUint32(0,0x06054b50,true);end.view.setUint16(8,entries.length,true);end.view.setUint16(10,entries.length,true);end.view.setUint32(12,directorySize,true);end.view.setUint32(16,offset,true);
  if(offset+directorySize+22>Math.min(maxBytes,0xffffffff))throw new Error('This backup exceeds the portable bundle limit.');return new Blob([...parts,...central,end.bytes],{type:'application/zip'});
}
