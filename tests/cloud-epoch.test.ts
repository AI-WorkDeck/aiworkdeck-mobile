import test from 'node:test'
import assert from 'node:assert/strict'
import {mkdtempSync,readFileSync,writeFileSync,rmSync} from 'node:fs'
import {tmpdir} from 'node:os'
import {join} from 'node:path'
import {cloudWriteHeaders,invalidateCloudEpoch,reconnectCloud,setSession} from '../miniprogram/utils/api.ts'
test('offline device reload preserves account epoch across session rotation and requires explicit reconnect', async () => {
 const dir=mkdtempSync(join(tmpdir(),'epoch-b-')), file=join(dir,'storage.json')
 let epoch=3, session='device-b-before', user=41
 const load=()=>JSON.parse(readFileSync(file,'utf8'))
 writeFileSync(file,'{}')
 ;(globalThis as any).wx={getStorageSync:(key:string)=>key==='awd.session'?session:load()[key],setStorageSync:(key:string,v:any)=>writeFileSync(file,JSON.stringify({...load(),[key]:v})),
 request:(o:any)=>o.success({statusCode:200,data:o.url.endsWith('/auth/me')?{code:0,data:{id:user}}:{cloudAccess:{epoch}}})}
 invalidateCloudEpoch()
 assert.equal((await cloudWriteHeaders('/api/mobile/media'))['X-Cloud-Epoch'],'3')
 const old={clientMediaId:'old',createdAt:1,state:'waiting',filePath:'/preserved/original',saved:true}
 ;(globalThis as any).wx.setStorageSync('awd.queue',[old])
 epoch=7;session='device-b-new-session';invalidateCloudEpoch()
 await assert.rejects(cloudWriteHeaders('/api/mobile/media'))
 assert.equal(load()['awd.queue'][0].cloudResumeRequired,true)
 assert.equal(load()['awd.queue'][0].filePath,old.filePath)
 assert.equal(load()['awd.cloudEpoch.v1.https://addin.aiworkdeck.com:41'],'3')
 invalidateCloudEpoch();await assert.rejects(cloudWriteHeaders('/api/mobile/media'))
 await reconnectCloud()
 assert.equal((await cloudWriteHeaders('/api/mobile/media'))['X-Cloud-Epoch'],'7')
 assert.equal(load()['awd.queue'][0].cloudResumeRequired,true)
 user=42;session='another-account';invalidateCloudEpoch()
 await assert.rejects(cloudWriteHeaders('/api/mobile/media'),'unbound legacy queue must not bootstrap')
 rmSync(dir,{recursive:true})
})
test('reconnect invalidates a pending old handshake rather than authorizing its body', async () => {
 const data=new Map<string,unknown>();let pending:any;let delay=true
 ;(globalThis as any).wx={getStorageSync:(key:string)=>key==='awd.session'?'pending-account':data.get(key),setStorageSync:(k:string,v:unknown)=>data.set(k,v),request:(o:any)=>{
  if(o.url.endsWith('/auth/me'))o.success({statusCode:200,data:{code:0,data:{id:55}}})
  else if(delay){pending=o;delay=false}else o.success({statusCode:200,data:{cloudAccess:{epoch:9}}})
 }}
 invalidateCloudEpoch();const old=cloudWriteHeaders('/api/mobile/media')
 await reconnectCloud();pending.success({statusCode:200,data:{cloudAccess:{epoch:9}}})
 await assert.rejects(old)
})

test('same-process account switch pauses newly captured tasks before any new-account write',async()=>{
 const data=new Map<string,any>([['awd.session','account-a'],['awd.queue',[{clientMediaId:'new',createdAt:Date.now()+1000,state:'waiting',filePath:'/kept/new'}]]])
 ;(globalThis as any).wx={getStorageSync:(k:string)=>data.get(k),setStorageSync:(k:string,v:any)=>data.set(k,v),removeStorageSync:(k:string)=>data.delete(k)}
 setSession('account-b')
 assert.equal(data.get('awd.queue')[0].cloudResumeRequired,true)
 assert.equal(data.get('awd.queue')[0].filePath,'/kept/new')
})
