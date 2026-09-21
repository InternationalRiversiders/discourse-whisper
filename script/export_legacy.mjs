import fs from 'node:fs/promises';
import path from 'node:path';
import crypto from 'node:crypto';
import { createRequire } from 'node:module';
const [sourceDir,output,mediaDir]=process.argv.slice(2);
if(!sourceDir || !output || !process.env.LEGACY_DATABASE_URL) { throw new Error('Usage: LEGACY_DATABASE_URL=... node export_legacy.mjs OLD_APP_DIRECTORY OUTPUT.json [MEDIA_DIRECTORY]'); }
const require=createRequire(path.resolve(sourceDir,'package.json'));
const {PrismaClient}=require('@prisma/client');
const db=new PrismaClient({datasources:{db:{url:process.env.LEGACY_DATABASE_URL}}});
const models=["User", "Post", "Comment", "Reaction", "Report", "IdentityRevealAudit", "ModerationEvent", "Notification"];
const payload={format:'riverside-community-v1',project:'whisper',exported_at:new Date().toISOString(),tables:{},media:[]};
try {
  await db.$transaction(async tx=>{
    await tx.$executeRawUnsafe('SET TRANSACTION READ ONLY');
    for(const name of models) { payload.tables[name]=await tx[name[0].toLowerCase()+name.slice(1)].findMany(); }
  },{isolationLevel:'RepeatableRead',timeout:120000,maxWait:10000});
  const names=new Set();
  function collect(value){
    if(typeof value==='string') { value=JSON.parse(value); }
    for(const name of value || []) { if(typeof name!=='string') { throw new Error('Invalid media reference'); } names.add(name); }
  }
  for(const rows of Object.values(payload.tables)) {
    for(const row of rows) {
      if(row.imageUrls) { collect(row.imageUrls); }
      if(row.images) { collect(row.images); }
      for(const key of ['beforeSnapshot','changes']) {
        if(row[key]) { const detail=JSON.parse(row[key]);if(detail.images) { collect(detail.images); } }
      }
    }
  }
  // Reserve output first; never overwrite an existing export.
  const handle=await fs.open(output,'wx',0o600);
  try {
    if(names.size) {
      if(!mediaDir) { throw new Error('Images referenced: provide MEDIA_DIRECTORY'); }
      const sourceRoot=await fs.realpath(mediaDir);
      const sidecar=path.basename(output)+'.media';
      const targetRoot=path.join(path.dirname(output),sidecar);
      await fs.mkdir(targetRoot,{mode:0o700});
      for(const name of names) {
        // Legacy Whisper stores image basenames, never arbitrary filesystem paths.
        if(!name || path.basename(name)!==name || name.includes('\\') || name==='.' || name==='..') { throw new Error('Invalid image name'); }
        let source;
        try { source=await fs.realpath(path.join(sourceRoot,name)); }
        catch(e) {
          if(e.code==='ENOENT' && process.env.WHISPER_EXPORT_ALLOW_MISSING_MEDIA==='1') {
            payload.media.push({name,missing:true});
            continue;
          }
          throw e;
        }
        if(!source.startsWith(sourceRoot+path.sep)) { throw new Error('Invalid image path'); }
        const bytes=await fs.readFile(source);const hash=crypto.createHash('sha256').update(bytes).digest('hex');
        const dest=path.join(targetRoot,hash);
        try { await fs.writeFile(dest,bytes,{flag:'wx',mode:0o600}); } catch(e) { if(e.code!=='EEXIST') { throw e; } }
        payload.media.push({name,file:sidecar+'/'+hash,sha256:hash});
      }
    }
    const raw=JSON.stringify(payload,(_,v)=>typeof v==='bigint' ? v.toString() : v,2);
    await handle.writeFile(raw);
    console.log(JSON.stringify({sha256:crypto.createHash('sha256').update(raw).digest('hex'),counts:Object.fromEntries(Object.entries(payload.tables).map(([k,v])=>[k,v.length])),media:payload.media.length,missing_media:payload.media.filter(m=>m.missing).length},null,2));
  } finally { await handle.close(); }
} finally { await db.$disconnect(); }
