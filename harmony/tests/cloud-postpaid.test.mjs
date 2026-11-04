import test from 'node:test'
import assert from 'node:assert/strict'
import {readFileSync} from 'node:fs'
import ts from 'typescript'
function load(name, mocks) {
 const source=readFileSync(new URL('../entry/src/main/ets/services/'+name+'.ets',import.meta.url),'utf8')
 const code=ts.transpileModule(source,{compilerOptions:{module:ts.ModuleKind.CommonJS,target:ts.ScriptTarget.ES2022}}).outputText
 const exports={};new Function('require','exports',code)(n=>mocks[n]??{},exports);return exports
}
test('Harmony cloud handshake freezes epoch by origin and session; unavailable state fails closed',async()=>{
 let epoch=3,calls=0,available=true
 const gate=load('CloudEpoch',{
  '@kit.NetworkKit':{http:{RequestMethod:{GET:'GET'},HttpDataType:{STRING:'STRING'},createHttp:()=>({request:async(url,opts)=>{if(url.endsWith('/auth/me'))return {responseCode:200,result:JSON.stringify({code:0,data:{id:opts.header['X-Session-Id'].charCodeAt(0)}})};calls++;return {responseCode:200,result:JSON.stringify({cloudAccess:available?{epoch}:{canWrite:false}})}},destroy(){}})}},
  '@kit.ArkTS':{JSON}, './ApiTypes':{asRecord:v=>v&&typeof v==='object'?v:null},'../model/Envelope':{ApiError:Error},'../design/L10n':{tr:k=>k},
 })
 const bindings=new Map();gate.configureCloudEpoch({cloudEpochBinding:async k=>bindings.get(k)??'',setCloudEpochBinding:async(k,v)=>bindings.set(k,v)},{loadAll:async()=>[]})
 assert.equal(await gate.cloudEpoch('https://cn.invalid','a','en'),'3')
 epoch=4;assert.equal(await gate.cloudEpoch('https://cn.invalid','a','en'),'3');assert.equal(calls,1)
 assert.equal(await gate.cloudEpoch('https://cn.invalid','b','en'),'4')
 available=false;await assert.rejects(gate.cloudEpoch('https://cn.invalid','c','en'))
})
test('Harmony queue restores paused jobs only through manual retry, including a new queue instance',async()=>{
 let saved={id:'old',state:'waiting',cloudResumeRequired:false,project:{key:'p'},kind:'photo',localPath:'/retained',capturedAtMs:()=>0}
 let uploads=0
 const store={loadAll:async()=>[{...saved}],updateState:async(id,state,progress,error,paused)=>{if(paused!=null)saved.cloudResumeRequired=paused;saved.state=saved.cloudResumeRequired?'failed':state}}
 const uploader={sweepStale:async()=>{},upload:async()=>{uploads++}}
 const {UploadQueue}=load('UploadQueue',{
  './CloudEpoch':{cloudGeneration:()=>0},
  '../model/TransferState':{TransferState:{waiting:'waiting',uploading:'uploading',failed:'failed',uploaded:'uploaded'},TransferEvent:{retryAuto:'retryAuto'},TransferStateOps:{next:()=> 'waiting',recovered:()=> 'waiting'}},
  '../model/Backoff':{Backoff:class {onSuccess(){}onFailure(){}}},'../model/UploadNaming':{uploadFileName:()=> 'old.jpg'},
  '../model/Envelope':{Unauthorized:class extends Error{}},'@kit.PerformanceAnalysisKit':{hilog:{info(){},warn(){}}},
 })
 await new UploadQueue(store,uploader,{}).pauseCloudUploads()
 const restarted=new UploadQueue(store,uploader,{})
 await restarted.autoKick();await restarted.kick();assert.equal(uploads,0);assert.equal(saved.localPath,'/retained')
 await restarted.retryFailed();assert.equal(uploads,1);assert.equal(saved.cloudResumeRequired,false)
})
