import Component from "@glimmer/component";
import DUserLink from "discourse/ui-kit/d-user-link";
import dAvatar from "discourse/ui-kit/helpers/d-avatar";

// Only pass an identity authorized by the server. Anonymous content has no user.
export default class extends Component {
  <template>
    {{#if @user.username}}
      <DUserLink @user={{@user}} class="whisper-forum-user">
        {{#unless @hideAvatar}}{{dAvatar @user imageSize="small" loading="lazy"}}{{/unless}}
        {{#unless @avatarOnly}}<span title={{@user.username}}>{{@user.username}}</span>{{/unless}}
      </DUserLink>
    {{else}}
      <span class="whisper-user-label">{{@name}}</span>
    {{/if}}
  </template>
}
