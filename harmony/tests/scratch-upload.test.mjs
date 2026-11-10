import test from 'node:test'
import assert from 'node:assert/strict'
import {readFileSync} from 'node:fs'
import ts from 'typescript'
function load(name, mocks) {
 const source=readFileSync(new URL('../entry/src/main/ets/services/'+name+'.ets',import.meta.url),'utf8')
 const code=ts.transpileModule(source,{compilerOptions:{module:ts.ModuleKind.CommonJS,target:ts.ScriptTarget.ES2022}}).outputText
 const exports={};new Function('require','exports',code)(n=>mocks[n]??{},exports);return exports
}
const mocks={
 './CloudEpoch':{cloudGeneration:()=>0},
 '../model/TransferState':{TransferState:{waiting:'waiting',uploading:'uploading',failed:'failed',uploaded:'uploaded'},TransferEvent:{retryAuto:'retryAuto'},TransferStateOps:{next:()=> 'waiting',recovered:()=> 'waiting'}},
 '../model/Backoff':{Backoff:class {onSuccess(){}onFailure(){}reset(){}}},'../model/UploadNaming':{uploadFileName:()=> 'x.jpg'},
 '../model/Envelope':{Unauthorized:class extends Error{}},'@kit.PerformanceAnalysisKit':{hilog:{info(){},warn(){}}},
}
const scratch={deviceId:'cloud',key:'41',name:'临时项目',isDefault:true,projectType:'SCRATCH'}
function fixture(items){
 const store={loadAll:async()=>items.map(i=>({...i,capturedAtMs:()=>0})),
  updateState:async(id,state,progress,error)=>{const i=items.find(x=>x.id===id);i.state=state;i.lastError=error??undefined},
  unassignScratch:async()=>{let n=0;for(const i of items)if(i.project&&(i.project.isDefault||i.project.projectType==='SCRATCH')&&(i.state==='waiting'||i.state==='failed')){i.project=null;i.state='waiting';i.lastError=undefined;n++}return n}}
 const uploads=[];const uploader={sweepStale:async()=>{},upload:async(item)=>{uploads.push(item.id)}}
 return {store,uploader,uploads}
}
test('Harmony 临时项目 without persistent cloud storage stays on the phone; desktop uploads continue',async()=>{
 const items=[{id:'s',state:'failed',lastError:'storageLimit',project:scratch,cloudResumeRequired:false,kind:'photo'},
  {id:'d',state:'waiting',project:{deviceId:'mac',key:'7'},cloudResumeRequired:false,kind:'audio'}]
 const {store,uploader,uploads}=fixture(items)
 const {UploadQueue}=load('UploadQueue',mocks)
 await new UploadQueue(store,uploader,{persistentCloudWritable:async()=>false}).kick()
 assert.deepEqual(uploads,['d'])
 assert.equal(items[0].project,null);assert.equal(items[0].state,'waiting');assert.equal(items[0].lastError,undefined)
})
test('Harmony subscribers keep uploading to 临时项目',async()=>{
 const items=[{id:'s',state:'waiting',project:scratch,cloudResumeRequired:false,kind:'photo'}]
 const {store,uploader,uploads}=fixture(items)
 const {UploadQueue}=load('UploadQueue',mocks)
 await new UploadQueue(store,uploader,{persistentCloudWritable:async()=>true}).kick()
 assert.deepEqual(uploads,['s'])
})
test('Harmony writable needs a known free quota',()=>{
 const {persistentCloudWritable}=load('ApiTypes',{})
 assert.equal(persistentCloudWritable({usedBytes:0,quotaBytes:1,persistentUsedBytes:9000,persistentQuotaBytes:0}),false)
 assert.equal(persistentCloudWritable({usedBytes:0,quotaBytes:1}),false)
 assert.equal(persistentCloudWritable({usedBytes:0,quotaBytes:1,persistentQuotaBytes:3000,persistentQuotaAvailable:false}),false)
 assert.equal(persistentCloudWritable({usedBytes:0,quotaBytes:1,persistentUsedBytes:9000,persistentQuotaBytes:3221225472}),true)
})
