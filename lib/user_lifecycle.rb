# frozen_string_literal: true
module DiscourseWhisper
  module UserLifecycle
    def self.purge(id,erase_content:true)
      return unless Post.table_exists?
      Record.transaction do
        Shared.lock("user:#{id}")
        # A private, non-forum tombstone preserves separate per-thread aliases.
        replacement=-1_000_000_000-id
        local_ids=Legacy.where(source:'User').where("data->>'externalUserId' = ?",id.to_s).pluck(:legacy_id)
        post_ids=Post.where(user_id:id).pluck(:id);comment_ids=Comment.where(user_id:id).pluck(:id)
        old_posts=Legacy.where(source:'Post',target_id:post_ids).pluck(:legacy_id)
        old_comments=Legacy.where(source:'Comment',target_id:comment_ids).pluck(:legacy_id)
        Legacy.where(target_kind:'Post',target_id:post_ids).delete_all
        Legacy.where(target_kind:'Comment',target_id:comment_ids).delete_all
        if local_ids.any?
          Legacy.where("data->>'externalUserId' = :uid OR data->>'authorId' IN (:ids) OR data->>'userId' IN (:ids) OR data->>'reporterId' IN (:ids) OR data->>'moderatorId' IN (:ids) OR data->>'revealedUserId' IN (:ids)",uid:id.to_s,ids:local_ids).delete_all
          Legacy.where(source:'User',legacy_id:local_ids).delete_all
        end
        Legacy.where("data->>'postId' IN (?)",old_posts).delete_all if old_posts.any?
        Legacy.where("data->>'commentId' IN (?)",old_comments).delete_all if old_comments.any?
        [Reaction,Report,Inbox,Event,Command,Ban].each { |klass| klass.where(user_id:id).delete_all }
        Command.where("result->>'identity_user_id' = ?",id.to_s).delete_all
        Audit.where(user_id:id).update_all(user_id:Discourse.system_user.id)
        Audit.where("details->>'revealed_user_id' = ?",id.to_s).update_all(details:{})
        Alias.where(user_id:id).update_all(user_id:replacement)
        attributes={user_id:replacement}
        attributes.merge!(body:'内容已随账号删除',status:'deleted',media_ids:[]) if erase_content
        Post.where(user_id:id).update_all(attributes.merge(erase_content ? {title:nil} : {}))
        Comment.where(user_id:id).update_all(attributes)
        if erase_content
          media_ids=Media.where(user_id:id).pluck(:id)
          Post.where('EXISTS (SELECT 1 FROM jsonb_array_elements_text(media_ids) m(value) WHERE m.value IN (?))',media_ids.map(&:to_s)).find_each { |p| p.update!(media_ids:p.media_ids-media_ids) } if media_ids.any?
          Media.where(user_id:id).delete_all
        else
          Media.where(user_id:id).update_all(user_id:replacement)
        end
        Notification.where(user_id:id,notification_type:Notification.types[:custom]).where("data::jsonb->>'river_app' = 'whisper'").destroy_all
      end
    end
  end
end
DiscourseEvent.on(:user_destroyed) { |user| DiscourseWhisper::UserLifecycle.purge(user.id) }
DiscourseEvent.on(:user_anonymized) { |user:,**_| DiscourseWhisper::UserLifecycle.purge(user.id,erase_content:false) }
DiscourseEvent.on(:merging_users) { |source,target| DiscourseWhisper::UserLifecycle.purge(source.id,erase_content:false) }
