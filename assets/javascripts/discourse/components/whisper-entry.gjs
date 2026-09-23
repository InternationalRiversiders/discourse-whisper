import Component from "@glimmer/component";
import { on } from "@ember/modifier";
import { fn } from "@ember/helper";
import { eq } from "discourse/truth-helpers";
import dIcon from "discourse/ui-kit/helpers/d-icon";
import DRelativeDate from "./campus-relative-date";

export default class extends Component {
  get anchor() { return this.args.entry.kind === "Post" ? "whisper-first-post" : `whisper-reply-${this.args.entry.id}`; }
  <template>
    <article class="whisper-post {{if @entry.masked 'is-masked'}}" id={{this.anchor}} data-entry-id={{@entry.id}}>
      <div class="topic-avatar"><span class="whisper-avatar {{if (eq @entry.alias '洞主') 'is-op'}}" aria-hidden="true">{{@entry.initial}}</span></div>
      <div class="topic-body">
        <header class="topic-meta-data">
          <div class="names"><strong>{{@entry.alias}}</strong>{{#if @entry.mine}}<span class="whisper-mine">你</span>{{/if}}{{#unless (eq @entry.status "visible")}}<span class="whisper-status">{{if (eq @entry.status "hidden") "已隐藏" "已删除"}}</span>{{/unless}}</div>
          <div class="whisper-post-time"><a href={{@entry.url}} {{on "click" @visit}} aria-label="回复链接">#{{@entry.floor}}</a><DRelativeDate @date={{@entry.created_at}} /></div>
        </header>
        {{#if @entry.parent}}<a class="whisper-quote" href={{@entry.parent.url}} {{on "click" @visit}}><span>{{dIcon "reply"}} 回复 {{@entry.parent.alias}} · #{{@entry.parent.floor}}</span><p>{{@entry.parent.excerpt}}</p></a>{{/if}}
        <div class="cooked whisper-body">{{@entry.body}}</div>
        {{#if @entry.images}}<div class="whisper-images">{{#each @entry.images as |url|}}<a href={{url}} target="_blank" rel="noopener noreferrer"><img src={{url}} alt="树洞配图，点击查看" loading="lazy" /></a>{{/each}}</div>{{/if}}
        <footer class="post-controls whisper-post-controls">
          <div class="actions">
            {{#if @entry.can_interact}}
              <button type="button" class="btn btn-flat {{if (eq @entry.reaction 1) 'is-active'}}" title="赞" aria-label="赞" aria-pressed={{if (eq @entry.reaction 1) "true" "false"}} {{on "click" (fn @action "like" @entry)}}>{{dIcon "thumbs-up"}} {{@entry.likes}}</button>
              <button type="button" class="btn btn-flat {{if (eq @entry.reaction -1) 'is-active'}}" aria-label="踩" aria-pressed={{if (eq @entry.reaction -1) "true" "false"}} {{on "click" (fn @action "dislike" @entry)}}>{{dIcon "thumbs-down"}} {{@entry.dislikes}}</button>
            {{else}}<span class="whisper-passive-count" title="赞">{{dIcon "thumbs-up"}} <span class="sr-only">赞</span>{{@entry.likes}}</span>{{/if}}
            <button type="button" class="btn btn-flat" title="复制链接" aria-label="复制链接" {{on "click" (fn @action "copy" @entry)}}>{{dIcon "link"}}</button>
            {{#if @entry.can_interact}}<button type="button" class="btn btn-flat" title="举报" aria-label="举报" disabled={{@entry.reported}} {{on "click" (fn @action "report" @entry)}}>{{dIcon "flag"}}</button>{{/if}}
            {{#if @entry.can_delete}}<button type="button" class="btn btn-flat" title="删除我的内容" aria-label="删除我的内容" {{on "click" (fn @action "delete" @entry)}}>{{dIcon "trash-can"}}</button>{{/if}}
            {{#if @entry.can_manage}}<button type="button" class="btn btn-flat" title="管理此内容" aria-label="管理此内容" {{on "click" (fn @action "moderate" @entry)}}>{{dIcon "shield-halved"}}</button>{{/if}}
            {{#if @entry.can_reply}}<button type="button" class="btn btn-flat reply" {{on "click" (fn @action "reply" @entry)}}>{{dIcon "reply"}} 回复</button>{{/if}}
          </div>
        </footer>
      </div>
    </article>
  </template>
}
