import ForumUser from "./whisper-user";
import Component from "@glimmer/component";
import { tracked } from "@glimmer/tracking";
import { action } from "@ember/object";
import { modifier } from "ember-modifier";
import { on } from "@ember/modifier";
import { fn } from "@ember/helper";
import { eq } from "discourse/truth-helpers";
import { ajax } from "discourse/lib/ajax";
import { extractError } from "discourse/lib/ajax-error";
import dIcon from "discourse/ui-kit/helpers/d-icon";
import DRelativeDate from "./campus-relative-date";
import AppForm from "./whisper-form";
import Entry from "./whisper-entry";

const statusText = (status) => ({visible:"可见",hidden:"已隐藏",deleted:"已删除"}[status] || status);
const link = (q) => "/whisper?" + new URLSearchParams(q).toString();
const field = (name, label, type = "text", required = true, extra = {}) => ({name,label,type,required,...extra});
export default class extends Component {
  @tracked snapshot;
  @tracked busy = false;
  @tracked loadingMore = false;
  @tracked error = "";
  @tracked notice = "";
  @tracked dialogForm = null;
  dirty = false;
  requestVersion = 0;
  cache = new Map();
  mount = modifier(() => {
    const pop = () => this.navigate(Object.fromEntries(new URLSearchParams(location.search)), null, true);
    const leave = (e) => { if (this.dirty) { e.preventDefault(); e.returnValue = ""; } };
    addEventListener("popstate",pop); addEventListener("beforeunload",leave);
    return () => { removeEventListener("popstate",pop); removeEventListener("beforeunload",leave); };
  });
  sentinel = modifier((element) => {
    const observer = new IntersectionObserver((entries) => { if (entries.some(e=>e.isIntersecting)) { this.more(); } }, {rootMargin:"250px"});
    observer.observe(element); return () => observer.disconnect();
  });
  get data() { return this.snapshot || this.args.model; }
  get query() { return Object.fromEntries(new URLSearchParams(location.search)); }
  get isList() { return ["feed","mine"].includes(this.data.view); }
  get canPost() { return !this.data.readonly && !this.data.banned; }
  get canMore() { return this.isList && this.data.pagination?.next; }
  get hasRows() { return this.data.rows?.length > 0; }
  get previousQuery() { return {...this.query,page:this.data.pagination.previous}; }
  get nextQuery() { return {...this.query,page:this.data.pagination.next}; }
  @action dirtyChanged() { this.dirty = true; }
  @action async visit(e) {
    if (e.metaKey || e.ctrlKey || e.shiftKey || e.altKey || e.button > 0) { return; }
    e.preventDefault();
    const url = new URL(e.currentTarget.href);
    await this.navigate(Object.fromEntries(url.searchParams));
  }
  @action async navigate(query, event, fromHistory = false) {
    event?.preventDefault();
    if (this.dirty && !confirm("尚未发布的内容会丢失，确定离开吗？")) { return; }
    if (!fromHistory) { this.cache.set(location.search,{data:this.data,scroll:scrollY}); }
    this.dirty = false; this.dialogForm = null; this.notice = ""; this.error = "";
    const version = ++this.requestVersion;
    this.busy = true;
    const encoded = new URLSearchParams(query).toString();
    const search = encoded ? "?"+encoded : "";
    try {
      const cached = fromHistory && this.cache.get(search);
      const data = cached ? cached.data : await ajax("/whisper/state.json"+search);
      if (version !== this.requestVersion) { return; }
      this.snapshot = data;
      if (!fromHistory && location.search!==search) { history.pushState({},"", "/whisper"+search); }
      requestAnimationFrame(()=>{
        if (query.reply) { document.getElementById(`whisper-reply-${query.reply}`)?.scrollIntoView({block:"center"}); }
        else { scrollTo({top:cached?.scroll || 0,behavior:"instant"}); }
      });
    } catch (e) { if (version===this.requestVersion) { this.error=extractError(e); } }
    finally { if (version===this.requestVersion) { this.busy=false; } }
  }
  @action tab(view) { return this.navigate({view}); }
  @action part(part) { return this.navigate({view:this.data.view,part}); }
  @action sort(sort) { return this.navigate({view:"feed",sort,q:this.data.q || ""}); }
  @action search(e) { e.preventDefault(); return this.navigate({view:"feed",q:new FormData(e.target).get("q") || "",sort:this.data.sort}); }
  @action status(e) { return this.navigate({view:"admin",part:"posts",status:e.target.value}); }
  @action async more() {
    if (!this.canMore || this.loadingMore || this.busy) { return; }
    const version=this.requestVersion;
    this.loadingMore=true;
    try {
      const next=await ajax("/whisper/state.json?"+new URLSearchParams({...this.query,page:this.data.pagination.next}));
      if (version!==this.requestVersion) { return; }
      const ids=new Set(this.data.rows.map(r=>r.id));
      this.snapshot={...next,rows:[...this.data.rows,...next.rows.filter(r=>!ids.has(r.id))]};
    } catch(e) { this.error=extractError(e); }
    finally { this.loadingMore=false; }
  }
  @action async execute(operation,data,key) {
    this.error="";
    const result=await ajax("/whisper/action",{type:"POST",contentType:"application/json",data:JSON.stringify({operation,data,request_id:key})});
    this.dirty=false; this.dialogForm=null; this.cache.clear();
    if (result.query) { await this.navigate(result.query); }
    else { this.snapshot=await ajax("/whisper/state.json?"+new URLSearchParams(this.query)); }
    this.notice=result.message || "";
    return result;
  }
  async run(operation,data) {
    if (this.busy) { return; }
    this.busy=true;
    try { await this.execute(operation,data,crypto.randomUUID()); }
    catch(e) { this.error=extractError(e); }
    finally { this.busy=false; }
  }
  @action async entryAction(kind,entry) {
    if (kind==="copy") {
      try { await navigator.clipboard.writeText(location.origin+entry.url); this.notice="链接已复制"; }
      catch { this.notice=location.origin+entry.url; }
      return;
    }
    if (kind==="like" || kind==="dislike") {
      const value=kind==="like" ? 1 : -1;
      return this.run("react",{kind:entry.kind,id:entry.id,value:entry.reaction===value ? 0 : value});
    }
    if (kind==="delete") {
      if (confirm("确定删除这条内容吗？")) { return this.run("delete_own",{kind:entry.kind,id:entry.id}); }
      return;
    }
    if (this.dirty && !confirm("放弃尚未发布的内容吗？")) { return; }
    this.dirty=false;
    const common={kind:entry.kind,id:entry.id};
    if (kind==="reply") { this.dialogForm={title:entry.kind==="Post" ? "回复树洞" : "回复 "+entry.alias,operation:"reply",data:{id:this.data.post.id,parent_id:entry.kind==="Comment" ? entry.id : null},fields:[field("body","回复内容","textarea",true,{maxlength:1200})],button:"匿名回复"}; }
    if (kind==="report") { this.dialogForm={title:"举报内容",operation:"report",data:common,fields:[field("reason","举报理由","textarea",true,{maxlength:240})],button:"提交举报"}; }
    if (kind==="moderate") { this.dialogForm={title:"管理内容",operation:"moderate",data:common,fields:[field("status","处理方式","select",true,{value:"hidden",options:[{value:"hidden",label:"隐藏"},{value:"visible",label:"恢复"},{value:"deleted",label:"删除"}]}),field("reason","处理理由","textarea",true,{maxlength:240})],button:"确认处理"}; }
    if (kind==="reveal") { this.dialogForm={title:"查看洞主身份 · 将留下公开审计",operation:"reveal",data:{id:entry.id},fields:[field("reason","查看理由","textarea",true,{maxlength:240})],button:"记录审计并查看"}; }
    requestAnimationFrame(()=>document.querySelector(".whisper-composer")?.scrollIntoView({block:"center"}));
  }
  @action cancel() { if (!this.dirty || confirm("放弃尚未发布的内容吗？")) { this.dialogForm=null;this.dirty=false; } }
  @action markRead() { return this.run("mark_read",{}); }
  @action resolve(row) { return this.run("resolve_report",{id:row.id}); }
  @action deleteComment(row) { return this.entryAction("delete",{kind:"Comment",id:row.id}); }
  <template>
    <section class="whisper-native" data-view={{this.data.view}} aria-busy={{if this.busy "true" "false"}} {{this.mount}}>
      <h1 class="sr-only">树洞</h1>
      <nav class="navigation-container whisper-navigation" aria-label="树洞导航"><ul class="nav nav-pills">{{#each this.data.tabs as |tab|}}<li><button type="button" class={{if (eq this.data.view tab.id) "active"}} {{on "click" (fn this.tab tab.id)}}>{{tab.label}}{{#if (eq tab.id "notifications")}}{{#if this.data.unread}}<span class="badge-notification">{{this.data.unread}}</span>{{/if}}{{/if}}</button></li>{{/each}}</ul>{{#if this.canPost}}<button type="button" class="btn btn-primary create" {{on "click" (fn this.tab "new")}}>{{dIcon "plus"}} 新树洞</button>{{/if}}</nav>
      {{#if this.data.readonly}}<p class="alert alert-info whisper-note">{{dIcon "lock"}} 真实数据只读预览，发布、互动和通知投递已暂停。</p>{{else if this.data.banned}}<p class="alert alert-info whisper-note">已限制树洞发言：{{this.data.ban_reason}}。你仍可浏览和删除自己的内容。</p>{{/if}}
      {{#if this.error}}<p role="alert" class="alert alert-error">{{this.error}}</p>{{/if}}{{#if this.notice}}<p role="status" class="alert alert-info">{{this.notice}}</p>{{/if}}
      {{#if (eq this.data.view "feed")}}
        <div class="whisper-list-controls"><div class="whisper-sort"><button type="button" class="btn btn-flat {{if (eq this.data.sort 'new') 'is-selected'}}" {{on "click" (fn this.sort "new")}}>最新发表</button><button type="button" class="btn btn-flat {{if (eq this.data.sort 'active') 'is-selected'}}" {{on "click" (fn this.sort "active")}}>最新回复</button></div><form class="whisper-search" {{on "submit" this.search}}><input type="search" name="q" value={{this.data.q}} aria-label="搜索树洞" placeholder="搜索树洞内容" maxlength="200" /><button class="btn btn-flat" type="submit" aria-label="搜索">{{dIcon "magnifying-glass"}}</button></form></div>
        <p class="whisper-anonymity-note">仅认证成员可见 · 帖内固定别名 · 查看身份须公开审计</p>
      {{/if}}
      {{#if (eq this.data.view "mine")}}<div class="whisper-subnav"><button class="btn btn-flat {{if (eq this.data.part 'posts') 'is-selected'}}" type="button" {{on "click" (fn this.part "posts")}}>我的树洞</button><button class="btn btn-flat {{if (eq this.data.part 'replies') 'is-selected'}}" type="button" {{on "click" (fn this.part "replies")}}>我的回复</button></div>{{/if}}
      {{#if this.isList}}
        <div class="whisper-feed">{{#each this.data.rows key="id" as |row|}}
          <article class="whisper-feed-card" data-row-id={{row.id}}>
            <header class="whisper-topic-title"><h2>{{#if row.url}}<a class="title" href={{row.url}} {{on "click" this.visit}}>{{row.title}}</a>{{else}}{{row.title}}{{/if}}</h2>{{#if row.mine}}<span class="whisper-mine">你的树洞</span>{{/if}}{{#if (eq row.status "hidden")}}<span class="whisper-status">已隐藏</span>{{/if}}</header>
            <p class="whisper-excerpt">{{row.excerpt}}</p>
            {{#if row.images}}<div class="whisper-feed-images">{{#each row.images as |url|}}<img src={{url}} alt="树洞配图" loading="lazy" />{{/each}}</div>{{/if}}
            <footer class="whisper-feed-card__footer">
              <span class="whisper-feed-card__identity">{{dIcon "leaf"}}{{if row.comment "你的回复" "匿名树洞"}}</span>
              {{#if row.missing_media_count}}<span>旧版有缺失配图</span>{{/if}}
              <div class="whisper-feed-card__stats">{{#unless row.comment}}<span title="回复数">{{dIcon "reply"}}<span class="sr-only">回复</span>{{row.replies}}</span><span title="赞">{{dIcon "thumbs-up"}}<span class="sr-only">赞</span>{{row.likes}}</span>{{/unless}}<span title={{if (eq this.data.sort "active") "最近活动" "发表时间"}}><DRelativeDate @date={{if (eq this.data.sort "active") row.activity_at row.created_at}} /></span>{{#if row.comment}}{{#if row.can_delete}}<button class="btn btn-flat" type="button" aria-label="删除我的回复" {{on "click" (fn this.deleteComment row)}}>{{dIcon "trash-can"}}</button>{{/if}}{{/if}}</div>
            </footer>
          </article>
        {{/each}}</div>
        {{#unless this.hasRows}}<div class="whisper-empty"><h2>这里还很安静</h2><p>{{if this.data.q "没有找到相关内容，换个关键词试试。" "愿你想说的话，都能被认真听见。"}}</p></div>{{/unless}}
        {{#if this.canMore}}<div class="whisper-load-more" {{this.sentinel this.data.pagination.next}}><button type="button" class="btn" disabled={{this.loadingMore}} {{on "click" this.more}}>{{if this.loadingMore "正在加载…" "加载更多"}}</button></div>{{else if this.hasRows}}<p class="whisper-end">共 {{this.data.pagination.total}} 条，已到达列表末尾</p>{{/if}}
      {{else if (eq this.data.view "post")}}
        <div class="whisper-topic-heading"><a href="/whisper" {{on "click" this.visit}}>{{dIcon "chevron-left"}} 返回树洞广场</a><h2>{{this.data.post.title}}</h2><div class="whisper-topic-meta"><span>{{this.data.post.replies}} 条回复</span></div></div>
        <div class="whisper-thread"><Entry @entry={{this.data.post}} @action={{this.entryAction}} @visit={{this.visit}} />{{#if this.data.post.missing_media_count}}<p class="whisper-missing-image">有 {{this.data.post.missing_media_count}} 张旧版配图文件已缺失。</p>{{/if}}{{#each this.data.replies key="id" as |entry|}}<Entry @entry={{entry}} @action={{this.entryAction}} @visit={{this.visit}} />{{/each}}</div>
        {{#if this.data.post.can_reply}}<button type="button" class="btn btn-primary whisper-bottom-reply" {{on "click" (fn this.entryAction "reply" this.data.post)}}>{{dIcon "reply"}} 回复树洞</button>{{/if}}
        {{#if this.data.audits}}<section class="whisper-audits"><h3>{{dIcon "eye"}} 身份查看记录</h3>{{#each this.data.audits key="id" as |audit|}}<p><ForumUser @user={{audit.moderator_user}} @name={{audit.moderator}} /> · <DRelativeDate @date={{audit.created_at}} /></p><p>{{audit.reason}}</p>{{/each}}</section>{{/if}}
        {{#if this.data.post.can_manage}}<button class="btn btn-flat" type="button" {{on "click" (fn this.entryAction "reveal" this.data.post)}}>{{dIcon "eye"}} 查看洞主身份（公开审计）</button>{{/if}}
      {{else if (eq this.data.view "notifications")}}
        <div class="whisper-subnav"><h2>树洞消息</h2>{{#unless this.data.readonly}}<button type="button" class="btn btn-flat" {{on "click" this.markRead}}>全部标为已读</button>{{/unless}}</div>
        <div class="whisper-notification-list">{{#each this.data.rows key="id" as |row|}}<article class="whisper-notification {{unless row.read 'is-unread'}}"><span class="whisper-notification-icon">{{dIcon "bell"}}</span><div>{{#if row.url}}<a href={{row.url}} {{on "click" this.visit}}>{{row.title}}</a>{{else}}<strong>{{row.title}}</strong>{{/if}}<p>{{row.post_label}}</p>{{#if row.message}}<p class="whisper-excerpt">{{row.message}}</p>{{/if}}<small><DRelativeDate @date={{row.created_at}} />{{#if row.historical}} · 旧版消息{{/if}}</small></div></article>{{else}}<p class="whisper-empty">暂时没有消息</p>{{/each}}</div>
      {{else if (eq this.data.view "admin")}}
        <div class="whisper-subnav"><button class="btn btn-flat {{if (eq this.data.part 'posts') 'is-selected'}}" type="button" {{on "click" (fn this.part "posts")}}>内容</button><button class="btn btn-flat {{if (eq this.data.part 'reports') 'is-selected'}}" type="button" {{on "click" (fn this.part "reports")}}>举报</button><button class="btn btn-flat {{if (eq this.data.part 'audits') 'is-selected'}}" type="button" {{on "click" (fn this.part "audits")}}>审计</button><button class="btn btn-flat {{if (eq this.data.part 'bans') 'is-selected'}}" type="button" {{on "click" (fn this.part "bans")}}>发言限制</button></div>
        {{#if (eq this.data.part "posts")}}<label class="whisper-status-select">内容状态 <select {{on "change" this.status}}><option value="all" selected={{eq this.data.status "all"}}>全部</option><option value="visible" selected={{eq this.data.status "visible"}}>可见</option><option value="hidden" selected={{eq this.data.status "hidden"}}>隐藏</option><option value="deleted" selected={{eq this.data.status "deleted"}}>删除</option></select></label>{{/if}}
        <div class="whisper-admin-list">{{#each this.data.rows key="id" as |row|}}<article class="whisper-admin-row">{{#if row.url}}<a href={{row.url}} {{on "click" this.visit}}>{{if row.title row.title "打开对应内容"}}</a>{{/if}}<p>{{row.excerpt}}{{row.body}}</p>{{#if row.status}}<small>{{statusText row.status}}</small>{{/if}}{{#if row.reason}}<p>{{row.reason}}</p>{{/if}}{{#if row.moderator}}<span><ForumUser @user={{row.moderator_user}} @name={{row.moderator}} /> · {{row.action}}</span>{{/if}}{{#if row.username}}<ForumUser @user={{row.forum_user}} @name={{row.username}} />{{/if}}<DRelativeDate @date={{row.created_at}} />{{#if (eq this.data.part "reports")}}{{#unless this.data.readonly}}<button type="button" class="btn" {{on "click" (fn this.resolve row)}}>标记已处理</button>{{/unless}}{{/if}}</article>{{else}}<p class="whisper-empty">没有相关记录</p>{{/each}}</div>
      {{/if}}
      {{#each this.data.forms as |form|}}<div class="whisper-composer"><AppForm @form={{form}} @execute={{this.execute}} @dirty={{this.dirtyChanged}} /></div>{{/each}}
      {{#if this.dialogForm}}<section class="whisper-composer"><button type="button" class="btn btn-flat whisper-cancel" {{on "click" this.cancel}}>取消</button><AppForm @form={{this.dialogForm}} @execute={{this.execute}} @dirty={{this.dirtyChanged}} /></section>{{/if}}
      {{#unless this.isList}}{{#if this.data.pagination}}<nav class="whisper-pagination" aria-label="分页">{{#if this.data.pagination.previous}}<a class="btn" href={{link this.previousQuery}} {{on "click" this.visit}}>上一页</a>{{/if}}<span>第 {{this.data.pagination.page}} / {{this.data.pagination.pages}} 页</span>{{#if this.data.pagination.next}}<a class="btn" href={{link this.nextQuery}} {{on "click" this.visit}}>下一页</a>{{/if}}</nav>{{/if}}{{/unless}}
    </section>
  </template>
}
