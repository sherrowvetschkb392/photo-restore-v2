const $ = (id) => document.getElementById(id);
const form = $("upload-form"), input = $("photo"), submit = $("submit"), message = $("message");
const videoForm = $("video-upload-form"), videoInput = $("video"), videoSubmit = $("video-submit"), videoMessage = $("video-message");
let pollTimer = null, acceptingUploads = false, acceptingVideoUploads = false;

const MODE_LABELS = {interpolate: "插帧 2×", upscale: "超分 4×", restore: "修复 2×@60"};
const PHASE_LABELS = {decode: "解封装", prepare: "预处理", sr: "超分", resize: "缩放", interpolate: "插帧", mux: "封装"};

function setMessage(el, text, error=false){ el.textContent=text; el.classList.toggle("error",error); }
function dateText(value){ return new Date(value).toLocaleString("zh-CN"); }

async function request(url, options={}){
  const response=await fetch(url,options);
  if(!response.ok){let detail=`HTTP ${response.status}`;try{detail=(await response.json()).detail||detail}catch{}throw new Error(detail)}
  if(response.status===204)return null;
  return response.json();
}

async function loadHealth(){
  try{const health=await request("/api/health"),used=(Number(health.storage_used_bytes||0)/1073741824).toFixed(2),quota=(Number(health.max_storage_bytes||0)/1073741824).toFixed(0);acceptingUploads=Boolean(health.accepting_uploads);acceptingVideoUploads=Boolean(health.accepting_video_uploads);$("health").textContent=health.status==="ok"?`服务正常 · 队列 ${health.queue_size} · 存储 ${used}/${quota} GiB`:(health.alerts?.includes("running_job_stalled")?"处理任务可能卡住，请联系管理员":"服务暂不可接收上传");$("health").classList.toggle("ok",health.status==="ok");submit.disabled=!acceptingUploads;videoSubmit.disabled=!acceptingVideoUploads;}
  catch{acceptingUploads=false;acceptingVideoUploads=false;submit.disabled=true;videoSubmit.disabled=true;$("health").textContent="无法连接服务";$("health").classList.remove("ok")}
}

function showViewer(job){
  if(job.job_type==="video"){showVideoViewer(job);return}
  $("video-viewer-panel").hidden=true;$("result-video").pause();
  $("viewer-panel").hidden=false;$("viewer-title").textContent=job.original_name;
  const ratioWidth=Number(job.width)||4,ratioHeight=Number(job.height)||3;
  $("compare").style.aspectRatio=`${ratioWidth} / ${ratioHeight}`;
  $("compare-range").value="50";setComparePosition(50);
  $("original-image").src=job.input_preview_url;$("result-image").src=job.output_preview_url;
  $("download-output").href=job.output_url;$("download-report").href=job.report_url;
  $("viewer-panel").scrollIntoView({behavior:"smooth",block:"start"});
}

function showVideoViewer(job){
  $("viewer-panel").hidden=true;
  $("video-viewer-panel").hidden=false;$("video-viewer-title").textContent=job.original_name;
  const video=$("result-video");video.src=job.output_url;video.load();
  $("video-download-output").href=job.output_url;$("video-download-report").href=job.report_url;
  const mode=MODE_LABELS[job.video_mode]||job.video_mode||"";
  $("video-result-meta").textContent=`${mode} · ${job.width}×${job.height} → 见播放器 · ${dateText(job.updated_at_utc)}`;
  $("video-viewer-panel").scrollIntoView({behavior:"smooth",block:"start"});
}

function progressText(job){
  const p=job.progress;if(!p)return"";
  const parts=[];
  if(p.phase)parts.push(PHASE_LABELS[p.phase]||p.phase);
  if(p.input_frames&&p.output_frames)parts.push(`${p.output_frames}/${p.input_frames} 帧`);
  else if(p.sr_frames!=null&&p.input_frames)parts.push(`超分 ${p.sr_frames}/${p.input_frames} 帧`);
  if(p.elapsed_seconds)parts.push(`已用时 ${Math.round(p.elapsed_seconds)}s`);
  return parts.length?`<div class="job-meta">进度：${parts.join(" · ")}</div>`:"";
}

function jobMarkup(job){
  const badge=job.job_type==="video"?`<span class="badge">${MODE_LABELS[job.video_mode]||"视频"}</span>`:`<span class="badge image">图片</span>`;
  const error=job.state==="FAILED"?`<div class="job-meta">${escapeHtml(job.error||"处理失败，请检查文件格式后重试")}</div>`:"";
  const progress=(job.state==="QUEUED"||job.state==="RUNNING")?progressText(job):"";
  const actions=job.state==="COMPLETE"?`<button class="secondary view" data-id="${job.id}">查看</button><a class="button ghost" href="${job.output_url}" download>下载</a>`:"";
  const deleteDisabled=job.state==="QUEUED"||job.state==="RUNNING";
  return `<article class="job"><div><div class="job-name">${badge}${escapeHtml(job.original_name)} <span class="status ${job.state}">${job.state}</span></div><div class="job-meta">${job.width}×${job.height} · ${dateText(job.created_at_utc)}</div>${error}${progress}</div><div class="job-actions">${actions}<button class="ghost delete" data-id="${job.id}" ${deleteDisabled?"disabled":""}>删除</button></div></article>`;
}
function escapeHtml(value){const div=document.createElement("div");div.textContent=value??"";return div.innerHTML}
function setComparePosition(value){const percent=Math.max(0,Math.min(100,Number(value)));$("original-layer").style.clipPath=`inset(0 ${100-percent}% 0 0)`;$("divider").style.left=`${percent}%`}

async function loadJobs(){
  try{const jobs=await request("/api/jobs");$("empty").hidden=jobs.length>0;$("jobs").innerHTML=jobs.map(jobMarkup).join("");
    $("jobs").querySelectorAll(".view").forEach(button=>button.addEventListener("click",async()=>showViewer(await request(`/api/jobs/${button.dataset.id}`))));
    $("jobs").querySelectorAll(".delete").forEach(button=>button.addEventListener("click",()=>deleteJob(button.dataset.id)));
    const active=jobs.some(job=>job.state==="QUEUED"||job.state==="RUNNING");clearTimeout(pollTimer);if(active)pollTimer=setTimeout(loadJobs,2500);loadHealth();
  }catch(error){setMessage(message,`读取任务失败：${error.message}`,true)}
}

async function deleteJob(id){
  if(!confirm("删除这项任务以及原文件、结果和报告？"))return;
  try{await request(`/api/jobs/${id}`,{method:"DELETE"});$("viewer-panel").hidden=true;$("video-viewer-panel").hidden=true;$("result-video").pause();await loadJobs()}catch(error){setMessage(message,`删除失败：${error.message}`,true)}
}

function bindDrop(drop,inputEl,nameEl){
  inputEl.addEventListener("change",()=>{nameEl.textContent=inputEl.files[0]?.name||""});
  ["dragenter","dragover"].forEach(name=>drop.addEventListener(name,event=>{event.preventDefault();drop.classList.add("drag")}));
  ["dragleave","drop"].forEach(name=>drop.addEventListener(name,event=>{event.preventDefault();drop.classList.remove("drag")}));
  drop.addEventListener("drop",event=>{if(event.dataTransfer.files.length){inputEl.files=event.dataTransfer.files;nameEl.textContent=inputEl.files[0].name}});
}
bindDrop($("drop-zone"),input,$("file-name"));
bindDrop($("video-drop-zone"),videoInput,$("video-file-name"));

form.addEventListener("submit",async event=>{
  event.preventDefault();if(!input.files.length)return;submit.disabled=true;setMessage(message,"正在上传并创建任务…");
  try{const data=new FormData();data.append("file",input.files[0]);const job=await request("/api/jobs",{method:"POST",body:data});setMessage(message,`任务已创建：${job.original_name}`);form.reset();$("file-name").textContent="";await loadJobs()}
  catch(error){setMessage(message,`上传失败：${error.message}`,true)}finally{submit.disabled=!acceptingUploads}
});

videoForm.addEventListener("submit",async event=>{
  event.preventDefault();if(!videoInput.files.length)return;videoSubmit.disabled=true;setMessage(videoMessage,"正在上传并创建任务…");
  try{const data=new FormData();data.append("file",videoInput.files[0]);data.append("mode",videoForm.querySelector("input[name=video-mode]:checked").value);const job=await request("/api/video-jobs",{method:"POST",body:data});setMessage(videoMessage,`任务已创建：${job.original_name}（${MODE_LABELS[job.video_mode]||""}）`);videoForm.reset();$("video-file-name").textContent="";await loadJobs()}
  catch(error){setMessage(videoMessage,`上传失败：${error.message}`,true)}finally{videoSubmit.disabled=!acceptingVideoUploads}
});

$("refresh").addEventListener("click",loadJobs);$("compare-range").addEventListener("input",event=>setComparePosition(event.target.value));
loadHealth();loadJobs();
