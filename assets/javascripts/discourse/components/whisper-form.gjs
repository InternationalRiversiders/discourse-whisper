import Component from "@glimmer/component";
import { tracked } from "@glimmer/tracking";
import { action } from "@ember/object";
import { on } from "@ember/modifier";
import { fn } from "@ember/helper";
import { eq } from "discourse/truth-helpers";
import { ajax } from "discourse/lib/ajax";
import { extractError } from "discourse/lib/ajax-error";
export default class extends Component {
  @tracked busy = false;
  @tracked error = "";
  @tracked previews = [];
  mediaIds = [];
  key = null;
  fingerprint = null;
  @action async upload(e) {
    this.busy = true;
    this.error = "";
    try {
      const files = Array.from(e.target.files);
      if (files.length + this.mediaIds.length > 9) { throw new Error("最多上传 9 张图片"); }
      this.args.dirty?.();
      for (const file of files) {
        const data = new FormData();
        data.append("file", file);
        const result = await ajax("/whisper/upload", {
          type: "POST",
          data,
          processData: false,
          contentType: false,
        });
        this.mediaIds.push(result.id);
        this.previews = [...this.previews, result.url];
      }
    } catch (error) {
      this.error = extractError(error);
    } finally {
      this.busy = false;
    }
  }
  @action changed() { this.args.dirty?.(); }
  @action remove(index) { this.args.dirty?.(); this.mediaIds.splice(index,1); this.previews = this.previews.filter((_,i)=>i!==index); }
  @action async submit(event) {
    event.preventDefault();
    if (this.busy) {
      return;
    }
    this.busy = true;
    this.error = "";
    const values = Object.fromEntries(new FormData(event.target));
    for (const field of this.args.form.fields) {
      if (field.type === "checkbox") {
        values[field.name] = values[field.name] === "on";
      }
    }
    const data = { ...this.args.form.data, ...values };
    if (this.mediaIds.length) {
      data.media_ids = this.mediaIds;
    }
    const fingerprint = JSON.stringify(data);
    if (fingerprint !== this.fingerprint) {
      this.key = crypto.randomUUID();
      this.fingerprint = fingerprint;
    }
    try {
      await this.args.execute(this.args.form.operation, data, this.key);
      this.key = null;
      this.fingerprint = null;
      event.target.reset();
      this.mediaIds = []; this.previews = [];
    } catch (error) {
      this.error = extractError(error);
    } finally {
      this.busy = false;
    }
  }
  get groups() {
    const fields = this.args.form.fields;
    let definitions = [];
    if (!definitions.length) {
      return [{ title: "", fields }];
    }
    return definitions.map(([title, description, names]) => ({
      title,
      description,
      fields: fields.filter((field) => names.includes(field.name)),
    }));
  }
  get hasRequired() {
    return this.args.form.fields.some((field) => field.required);
  }
  <template>
    <form
      class="river-form"
      aria-busy={{this.busy}}
      {{on "submit" this.submit}}
      {{on "input" this.changed}}
    >
      <div class="river-form-heading">{{#if @form.title}}<h3
          >{{@form.title}}</h3>{{/if}}{{#if this.hasRequired}}<span>* 为必填项</span>{{/if}}</div>
      {{#each this.groups key="title" as |group|}}
        <fieldset
          class="river-fieldset"
          aria-label={{if group.title group.title @form.title}}
        >
          {{#if group.title}}<legend>{{group.title}}</legend><p
              class="river-fieldset-note"
            >{{group.description}}</p>{{/if}}
          <div class="river-fields">{{#each group.fields key="name" as |field|}}
              <label
                class="{{if (eq field.type 'textarea') 'river-field-wide'}}
                  {{if (eq field.type 'checkbox') 'river-checkbox'}}
                  {{if
                    (eq field.type 'upload')
                    'river-field-wide river-upload'
                  }}"
              >
                <span>{{field.label}}{{#if field.required}}<span
                      class="river-required"
                      aria-hidden="true"
                    > *</span>{{/if}}</span>
                {{#if (eq field.type "textarea")}}<textarea
                    name={{field.name}}
                    aria-label={{field.label}}
                    required={{field.required}}
                    rows="4"
                    maxlength={{field.maxlength}}
                  >{{field.value}}</textarea>
                {{else if (eq field.type "select")}}<select
                    name={{field.name}}
                    aria-label={{field.label}}
                    required={{field.required}}
                  >{{#each field.options as |choice|}}<option
                        value={{choice.value}}
                        selected={{eq choice.value field.value}}
                      >{{choice.label}}</option>{{/each}}</select>
                {{else if (eq field.type "checkbox")}}<input
                    type="checkbox"
                    name={{field.name}}
                    aria-label={{field.label}}
                    checked={{field.value}}
                  />
                {{else if (eq field.type "upload")}}<input
                    type="file"
                    accept="image/jpeg,image/png,image/gif,image/webp"
                    multiple
                    disabled={{this.busy}}
                    {{on "change" this.upload}}
                  /><small>支持 JPG、PNG、GIF、WebP，每张最大 10 MB</small>
                {{else}}<input
                    type={{field.type}}
                    name={{field.name}}
                    aria-label={{field.label}}
                    value={{field.value}}
                    required={{field.required}}
                    step="any"
                    maxlength={{field.maxlength}}
                  />{{/if}}
              </label>
            {{/each}}</div>
        </fieldset>
      {{/each}}
      {{#if this.previews}}<div class="river-images">{{#each
            this.previews
            as |url index|
          }}<div class="river-image-preview"><img src={{url}} alt="已上传的图片" /><button class="btn btn-flat" type="button" {{on "click" (fn this.remove index)}}>移除</button></div>{{/each}}</div>{{/if}}
      {{#if this.error}}<p
          role="alert"
          class="river-error"
        >{{this.error}}</p>{{/if}}
      <div class="river-form-footer"><button
          class="btn btn-primary"
          type="submit"
          disabled={{this.busy}}
        >{{if this.busy "正在保存…" @form.button}}</button></div>
    </form>
  </template>
}
