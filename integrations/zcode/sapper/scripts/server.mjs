import readline from 'node:readline';
import http from 'node:http';

const origin = 'http://127.0.0.1:18790';
const idPattern = /^[A-Za-z0-9][A-Za-z0-9_-]{0,47}$/;
const definitions = [
  {name:'list_tasks',description:'List local Sapper tasks and independent session status.',inputSchema:{type:'object',properties:{},additionalProperties:false}},
  {name:'inspect_task',description:'Read a task snapshot and its existing findings.',inputSchema:{type:'object',properties:{id:{type:'string'}},required:['id'],additionalProperties:false}},
  {name:'create_task',description:'Create a task and isolated fact graph without starting Pi or model inference.',inputSchema:{type:'object',properties:{id:{type:'string'},goal:{type:'string'},scope:{type:'string'},excluded:{type:'string'}},required:['id','goal'],additionalProperties:false}},
  {name:'open_terminal',description:'Start or reopen the named task and open its native Pi Commander terminal on the host.',inputSchema:{type:'object',properties:{id:{type:'string'}},required:['id'],additionalProperties:false}},
];
function call(path, data) {
  return new Promise((resolve,reject)=>{
    const raw=data===undefined?null:JSON.stringify(data);
    const request=http.request(origin+path,{method:raw?'POST':'GET',headers:raw?{'Content-Type':'application/json','Origin':origin,'Content-Length':Buffer.byteLength(raw)}:{},timeout:30000},response=>{
      let body='';response.setEncoding('utf8');response.on('data',s=>{body+=s;if(body.length>2_000_000)request.destroy(new Error('Response too large'))});response.on('end',()=>{try{const parsed=JSON.parse(body);if(response.statusCode>=400)reject(new Error(parsed.error||`HTTP ${response.statusCode}`));else resolve(parsed)}catch(e){reject(e)}});
    });
    request.on('timeout',()=>request.destroy(new Error('Sapper service timed out')));request.on('error',reject);if(raw)request.write(raw);request.end();
  });
}
async function invoke(name,a={}){
  if(name==='list_tasks')return call('/tasks');
  if(!idPattern.test(a.id||''))throw Error('Invalid task ID');
  if(name==='inspect_task')return {snapshot:await call('/snapshot?task='+encodeURIComponent(a.id)),findings:await call('/findings?task='+encodeURIComponent(a.id))};
  if(name==='create_task')return call('/tasks',{id:a.id,goal:a.goal||'',scope:a.scope||'',excluded:a.excluded||''});
  if(name==='open_terminal')return call('/tasks/'+encodeURIComponent(a.id)+'/open',{});
  throw Error('Unknown tool');
}
function send(id,result,error){if(id===undefined)return;process.stdout.write(JSON.stringify(error?{jsonrpc:'2.0',id,error}:{jsonrpc:'2.0',id,result})+'\n')}
readline.createInterface({input:process.stdin,crlfDelay:Infinity}).on('line',async line=>{
  let msg;try{msg=JSON.parse(line)}catch{return}
  if(msg.method==='initialize')return send(msg.id,{protocolVersion:msg.params?.protocolVersion||'2024-11-05',capabilities:{tools:{}},serverInfo:{name:'sapper',version:'0.1.0'}});
  if(msg.method==='ping')return send(msg.id,{});
  if(msg.method==='tools/list')return send(msg.id,{tools:definitions});
  if(msg.method==='tools/call'){try{const result=await invoke(msg.params?.name,msg.params?.arguments);return send(msg.id,{content:[{type:'text',text:JSON.stringify(result)}]})}catch(e){return send(msg.id,{isError:true,content:[{type:'text',text:String(e.message||e)}]})}}
  if(msg.id!==undefined)send(msg.id,null,{code:-32601,message:'Method not found'});
});
