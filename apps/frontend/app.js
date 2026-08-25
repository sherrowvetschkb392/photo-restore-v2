const $ = (id) => document.getElementById(id);
const form = $("upload-form"), input = $("photo"), submit = $("submit"), message = $("message");
let pollTimer = null;

function setMessage(text, error=false){ message.textContent=text; message.classList.toggle("error",error); }
function dateText(value){ return new Date(value).toLocaleString("zh-CN"); }

async function request(url, options={}){
  const response=await fetch(url,options);
  if(!response.ok){let detail=`HTTP ${response.status}`;try{detail=(await response.json()).detail||detail}catch{}throw new Error(detail)}
  if(response.status===204)return null;
  return response.json();
}

async function loadHealth(){
  try{const health=await request("/api/health");$("health").textContent=health.status==="ok"?`服务正常 · 队列 ${health.queue_size}`:"服务未就绪";$("health").classList.toggle("ok",health.status==="ok");}
  catch{$("health").textContent="无法连接服务";$("health").classList.remove("ok")}
}

function showViewer(job){
  $("viewer-panel").hidden=false;$("viewer-title").textContent=job.original_name;
  const ratioWidth=Number(job.width)||4,ratioHeight=Number(job.height)||3;
  $("compare").style.aspectRatio=`${ratioWidth} / ${ratioHeight}`;
  $("compare-range").value="50";setComparePosition(50);
  $("original-image").src=job.input_url;$("result-image").src=job.output_url;
  $("download-output").href=job.output_url;$("download-report").href=job.report_url;
  $("viewer-panel").scrollIntoView({behavior:"smooth",block:"start"});
}

function jobMarkup(job){
  const error=job.state==="FAILED"?`<div class="job-meta">图片处理失败，请检查文件格式后重试</div>`:"";
  const actions=job.state==="COMPLETE"?`<button class="secondary view" data-id="${job.id}">查看</button><a class="button ghost" href="${job.output_url}" download>下载</a>`:"";
  return `<article class="job"><div><div class="job-name">${escapeHtml(job.original_name)} <span class="status ${job.state}">${job.state}</span></div><div class="job-meta">${job.width}×${job.height} · ${dateText(job.created_at_utc)}</div>${error}</div><div class="job-actions">${actions}<button class="ghost delete" data-id="${job.id}" ${job.state==="RUNNING"?"disabled":""}>删除</button></div></article>`;
}
function escapeHtml(value){const div=document.createElement("div");div.textContent=value??"";return div.innerHTML}
function setComparePosition(value){const percent=Math.max(0,Math.min(100,Number(value)));$("original-layer").style.clipPath=`inset(0 ${100-percent}% 0 0)`;$("divider").style.left=`${percent}%`}

async function loadJobs(){
  try{const jobs=await request("/api/jobs");$("empty").hidden=jobs.length>0;$("jobs").innerHTML=jobs.map(jobMarkup).join("");
    $("jobs").querySelectorAll(".view").forEach(button=>button.addEventListener("click",async()=>showViewer(await request(`/api/jobs/${button.dataset.id}`))));
    $("jobs").querySelectorAll(".delete").forEach(button=>button.addEventListener("click",()=>deleteJob(button.dataset.id)));
    const active=jobs.some(job=>job.state==="QUEUED"||job.state==="RUNNING");clearTimeout(pollTimer);if(active)pollTimer=setTimeout(loadJobs,2500);loadHealth();
  }catch(error){setMessage(`读取任务失败：${error.message}`,true)}
}

async function deleteJob(id){
  if(!confirm("删除这项任务以及原图、修复图和报告？"))return;
  try{await request(`/api/jobs/${id}`,{method:"DELETE"});$("viewer-panel").hidden=true;await loadJobs()}catch(error){setMessage(`删除失败：${error.message}`,true)}
}

input.addEventListener("change",()=>{$("file-name").textContent=input.files[0]?.name||""});
const drop=$("drop-zone");["dragenter","dragover"].forEach(name=>drop.addEventListener(name,event=>{event.preventDefault();drop.classList.add("drag")}));["dragleave","drop"].forEach(name=>drop.addEventListener(name,event=>{event.preventDefault();drop.classList.remove("drag")}));drop.addEventListener("drop",event=>{if(event.dataTransfer.files.length){input.files=event.dataTransfer.files;$("file-name").textContent=input.files[0].name}});

form.addEventListener("submit",async event=>{
  event.preventDefault();if(!input.files.length)return;submit.disabled=true;setMessage("正在上传并创建任务…");
  try{const data=new FormData();data.append("file",input.files[0]);const job=await request("/api/jobs",{method:"POST",body:data});setMessage(`任务已创建：${job.original_name}`);form.reset();$("file-name").textContent="";await loadJobs()}
  catch(error){setMessage(`上传失败：${error.message}`,true)}finally{submit.disabled=false}
});

$("refresh").addEventListener("click",loadJobs);$("compare-range").addEventListener("input",event=>setComparePosition(event.target.value));
loadHealth();loadJobs();
