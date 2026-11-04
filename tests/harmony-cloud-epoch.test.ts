import test from 'node:test'
import assert from 'node:assert/strict'
import {readFileSync,writeFileSync,mkdtempSync,rmSync} from 'node:fs'
import {join} from 'node:path'
import {tmpdir} from 'node:os'
import ts from 'typescript'
function loadGate(epoch:()=>number, files:string) {
 const read=()=>JSON.parse(readFileSync(files,'utf8'))
 const write=(v:any)=>writeFileSync(files,JSON.stringify(v))
 const preferences={async cloudEpochBinding(key:string){return read().bindings[key]??''},async setCloudEpochBinding(key:string,value:string){const data=read();data.bindings[key]=value;write(data)}}
 const store={async loadAll(){return read().rows.map((row:any)=>({...row,capturedAtMs:()=>row.at}))},async updateState(id:string,state:string,_p:number,_error:any,paused:boolean){const data=read();const row=data.rows.find((r:any)=>r.id===id);row.state=state;row.cloudResumeRequired=paused;write(data)}}
 const source=readFileSync(new URL('../harmony/entry/src/main/ets/services/CloudEpoch.ets',import.meta.url),'utf8')
 const output=ts.transpileModule(source,{compilerOptions:{module:ts.ModuleKind.CommonJS,target:ts.ScriptTarget.ES2022}}).outputText
 const exports:any={}
 const require=(name:string)=>{
  if(name==='@kit.NetworkKit')return {http:{RequestMethod:{GET:'GET'},HttpDataType:{STRING:1},createHttp:()=>({destroy(){},request:async(url:string)=>({responseCode:200,result:JSON.stringify(url.endsWith('/auth/me')?{code:0,data:{id:41}}:{cloudAccess:{epoch:epoch()}})})})}}
  if(name==='@kit.ArkTS')return {JSON}
  if(name==='./ApiTypes')return {asRecord:(v:any)=>v}
  if(name==='../model/Envelope')return {ApiError:class extends Error{constructor(_n:number,s:string){super(s)}}}
  if(name==='../design/L10n')return {tr:(s:string)=>s}
  if(name==='../model/TransferState')return {TransferState:{waiting:'waiting',uploading:'uploading',failed:'failed'}}
  return {}
 }
 new Function('require','exports',output)(require,exports)
 exports.configureCloudEpoch(preferences,store)
 return exports
}
test('Harmony offline B reload uses disk account binding, pauses old records, and explicit reconnect does not unpause them',async()=>{
 const dir=mkdtempSync(join(tmpdir(),'harmony-epoch-')),file=join(dir,'storage.json')
 writeFileSync(file,JSON.stringify({bindings:{},rows:[]}))
 let epoch=3
 const a=loadGate(()=>epoch,file)
 assert.equal(await a.cloudEpoch('https://addin.aiworkdeck.com','old-session','en'),'3')
 const saved=JSON.parse(readFileSync(file,'utf8'));saved.rows=[{id:'old',state:'waiting',at:1,original:'/preserved/audio'}];writeFileSync(file,JSON.stringify(saved))
 epoch=7
 const b=loadGate(()=>epoch,file)
 await assert.rejects(b.cloudEpoch('https://addin.aiworkdeck.com','rotated-session','en'))
 const disk=JSON.parse(readFileSync(file,'utf8'))
 assert.equal(disk.bindings['https://addin.aiworkdeck.com:41'],'3')
 assert.equal(disk.rows[0].cloudResumeRequired,true);assert.equal(disk.rows[0].original,'/preserved/audio')
 const c=loadGate(()=>epoch,file)
 await assert.rejects(c.cloudEpoch('https://addin.aiworkdeck.com','rotated-again','en'))
 const oldPreparation=c.cloudGeneration()
 await c.reconnectCloud('https://addin.aiworkdeck.com','rotated-again','en')
 await assert.rejects(c.cloudEpoch('https://addin.aiworkdeck.com','rotated-again','en',false,oldPreparation))
 assert.equal(await c.cloudEpoch('https://addin.aiworkdeck.com','rotated-again','en'),'7')
 assert.equal(JSON.parse(readFileSync(file,'utf8')).rows[0].cloudResumeRequired,true)
 await c.reconnectCloud('https://addin.aiworkdeck.com','rotated-again','en')
 assert.equal(JSON.parse(readFileSync(file,'utf8')).rows[0].cloudResumeRequired,true)
 rmSync(dir,{recursive:true})
})
test('resume and persistent fence messages are present in every generated locale source',()=>{
 const locales=JSON.parse(readFileSync(new URL('../contract/locales.json',import.meta.url),'utf8'))
 for(const locale of locales){const dict=JSON.parse(readFileSync(new URL(`../contract/strings/${locale.code}.json`,import.meta.url),'utf8'));for(const key of ['postpaid.resume','postpaid.resumeNotice','postpaid.uploadPaused','postpaid.refresh'])assert.ok(dict[key],`${locale.code}:${key}`)}
})
test('Harmony selected upload suspended before epoch handshake cannot adopt reconnect permission',async()=>{
 const dir=mkdtempSync(join(tmpdir(),'harmony-pre-auth-')),file=join(dir,'storage.json')
 writeFileSync(file,JSON.stringify({bindings:{},rows:[]}))
 const gate=loadGate(()=>4,file), revision=gate.cloudGeneration()
 let release!:(value:string)=>void
 const session={current:()=>new Promise<string>(resolve=>{release=resolve})}
 let sent=false
 const source=readFileSync(new URL('../harmony/entry/src/main/ets/services/Uploader.ets',import.meta.url),'utf8')
 const output=ts.transpileModule(source,{compilerOptions:{module:ts.ModuleKind.CommonJS,target:ts.ScriptTarget.ES2022}}).outputText
 const exports:any={}
 const require=(name:string)=>{
  if(name==='./CloudEpoch')return gate
  if(name==='../model/AccountRegion')return {baseUrlOf:()=> 'https://addin.aiworkdeck.com',currentAppLanguage:()=> 'en'}
  if(name==='@kit.BasicServicesKit')return {request:{agent:{create(){sent=true;throw Error('must not send')}}}}
  if(name==='../model/Envelope')return {Unauthorized:class extends Error{},ApiError:class extends Error{}}
  return {}
 }
 new Function('require','exports',output)(require,exports)
 const uploader=new exports.Uploader({},()=> 'cn',session,{deviceId:async()=> 'd'})
 const pending=uploader.upload({manifest:{clientMediaId:'old'}},{},'old.jpg',()=>{},revision)
 await gate.reconnectCloud('https://addin.aiworkdeck.com','s','en')
 release('s');await assert.rejects(pending);assert.equal(sent,false)
 rmSync(dir,{recursive:true})
})
